import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/config/user_setting_service.dart';
import 'tts_engine.dart';

/// DeepSeek 官方 TTS：`POST /v1/tools/tts`。
///
/// 不使用系统 TTS / 内置离线 TTS；音频由 DeepSeek 合成，原生 MediaPlayer 播放。
/// 官方参数：text、voice_id、format、filter_markdown。
class DeepSeekTtsEngine implements TtsEngine {
  static const String endpoint = 'https://api.deepseek.com/v1/tools/tts';
  static const String defaultVoiceId = 'stella';

  static const MethodChannel _channel = MethodChannel(
    'deepseek_app/deepseek_tts',
  );
  static const EventChannel _events = EventChannel(
    'deepseek_app/deepseek_tts/events',
  );

  static const List<TtsEngineOption> voiceOptions = [
    TtsEngineOption(id: 'stella', label: '海星 · DeepSeek 女声'),
    TtsEngineOption(id: 'tide', label: '暗潮 · DeepSeek 男声'),
  ];

  final Dio _dio;
  String _voiceId = defaultVoiceId;
  String? _apiKey;
  bool _available = false;
  bool _speaking = false;
  String _error = '';
  int _seq = 0;
  double _playbackRate = 1.0;
  Completer<void>? _playbackDone;
  File? _tempFile;
  VoidCallback? _onDone;
  void Function(String message)? _onError;
  StreamSubscription<dynamic>? _eventSub;

  DeepSeekTtsEngine({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 5),
            ),
          ) {
    _eventSub = _events.receiveBroadcastStream().listen(_handleNativeEvent);
  }

  void _handleNativeEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = raw['event'];
    if (event == 'done') {
      final done = _playbackDone;
      if (done != null && !done.isCompleted) done.complete();
    } else if (event == 'error') {
      final message = raw['message']?.toString() ?? '原生播放失败';
      _error = message;
      final done = _playbackDone;
      if (done != null && !done.isCompleted) done.completeError(message);
      _speaking = false;
      _onError?.call(message);
    }
  }

  @override
  bool get isAvailable => _available;

  @override
  bool get isSpeaking => _speaking;

  @override
  String get errorMessage => _error;

  @override
  String get selectedEngineId => _voiceId;

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    _onDone = onDone;
    _onError = onError;
  }

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    try {
      final setting = await UserSettingService.getSettings();
      _apiKey = setting.apiKey.trim();
      _available = _apiKey!.isNotEmpty;
      _error = _available ? '' : '请先在设置中填写 DeepSeek API Key，再使用 DeepSeek 语音';
      return _available;
    } catch (e) {
      _available = false;
      _error = '读取 DeepSeek API Key 失败：$e';
      return false;
    }
  }

  @override
  Future<bool> speak(TtsSpeechRequest request) async {
    if (request.text.trim().isEmpty) return false;
    if (!_available) {
      final ok = await init(language: request.language);
      if (!ok) return false;
    }
    await _stopPlayback(notifyDone: false);
    final seq = ++_seq;
    final voice = (request.voiceId ?? _voiceId).trim();
    _playbackRate = request.rate.clamp(0.75, 4.0);
    _speaking = true;
    _error = '';
    unawaited(_playText(seq, request.text.trim(), voice));
    return true;
  }

  Future<void> _playText(int seq, String text, String voice) async {
    try {
      final chunks = _splitText(text);
      // DeepSeek 的 WAV 是未压缩音频：一次合成 3000+ 字可能返回几十 MB，
      // 往往要等 2-3 分钟才开始播，用户会以为「点了没反应」。
      // 这里按句切成小段，并提前合成下一段：第一段先播，下一段在播放期间
      // 并行请求，既缩短首次出声等待，也避免段与段之间长时间静音。
      Future<Uint8List>? current = _synthesize(chunks.first, voice);
      for (var i = 0; i < chunks.length; i++) {
        if (seq != _seq) return;
        final bytes = await current!;
        if (seq != _seq) return;
        final next = i + 1 < chunks.length
            ? _guardedSynthesize(chunks[i + 1], voice)
            : null;

        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/deepseek_tts_${DateTime.now().microsecondsSinceEpoch}.wav',
        );
        await file.writeAsBytes(bytes, flush: true);
        _tempFile = file;
        final done = Completer<void>();
        _playbackDone = done;
        await _channel.invokeMethod<void>('play', {
          'path': file.path,
          'speed': _playbackRate,
        });
        await done.future;
        try {
          await file.delete();
        } catch (_) {}
        _tempFile = null;
        current = next;
      }
      if (seq != _seq) return;
      _speaking = false;
      _onDone?.call();
    } catch (e) {
      if (seq != _seq) return;
      _speaking = false;
      _error = _friendlyError(e);
      _onError?.call(_error);
    }
  }

  /// 预取下一段。提前挂一个错误监听，避免下一段在上一段播放期间失败时
  /// 变成未处理的 Future 异常；真正的异常仍会在 await 时抛给调用方。
  Future<Uint8List> _guardedSynthesize(String text, String voice) {
    final completer = Completer<Uint8List>();
    _synthesize(text, voice).then(
      completer.complete,
      onError: (Object e, StackTrace st) => completer.completeError(e, st),
    );
    // 监听错误但不改变 completer 的结果；否则播放中的预取失败可能被
    // Flutter 当成未捕获异步异常。
    completer.future.catchError((_) => Uint8List(0));
    return completer.future;
  }

  Future<Uint8List> _synthesize(String text, String voice) async {
    final response = await _dio.post<List<int>>(
      endpoint,
      data: {
        'text': text,
        'voice_id': voice,
        'format': 'wav',
        // 官方 API 端再去一次 Markdown；这里仍会做客户端兜底。
        'filter_markdown': true,
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer ${_apiKey ?? ''}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.bytes,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw Exception('DeepSeek TTS 返回了空音频');
    }
    return Uint8List.fromList(data);
  }

  List<String> _splitText(String text) {
    // 单次最多 10000 个计费字符；但整段合成会返回几十 MB WAV，且要等
    // 几十秒到几分钟。按句切成短段后，第一段约 6-9 秒就能开始播放。
    const maxChars = 160;
    if (text.length <= maxChars) return [text];
    final out = <String>[];
    var rest = text;
    while (rest.length > maxChars) {
      var cut = maxChars;
      final candidates = ['。', '！', '？', '；', '\n', '.', '!', '?', ';'];
      for (final p in candidates) {
        final i = rest.lastIndexOf(p, maxChars);
        if (i > maxChars ~/ 2) {
          cut = i + 1;
          break;
        }
      }
      out.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  Future<void> _stopPlayback({required bool notifyDone}) async {
    _seq++;
    _speaking = false;
    final done = _playbackDone;
    if (done != null && !done.isCompleted) done.complete();
    _playbackDone = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    final file = _tempFile;
    _tempFile = null;
    if (file != null) {
      try {
        await file.delete();
      } catch (_) {}
    }
    if (notifyDone) _onDone?.call();
  }

  @override
  Future<void> stop() async {
    await _stopPlayback(notifyDone: false);
  }

  @override
  Future<void> setBackgroundPlayback(bool enabled) async {
    // 原生 MediaPlayer 由系统音频焦点管理，退到后台仍继续播放。
  }

  @override
  Future<TtsEngineStatus> diagnose() async {
    if (!_available) await init();
    return TtsEngineStatus(
      engines: _available ? voiceOptions.map((e) => e.id).toList() : const [],
      defaultEngine: _available ? _voiceId : null,
      zhState: _available ? 'ok' : 'no_engine',
    );
  }

  @override
  Future<void> reset() async {
    await stop();
  }

  @override
  Future<bool> openTtsSettings() async => false;

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) async => false;

  @override
  Future<List<TtsEngineOption>> availableEngines() async =>
      _available ? voiceOptions : const [];

  @override
  Future<void> selectEngine(String engineId) async {
    if (voiceOptions.any((o) => o.id == engineId)) {
      _voiceId = engineId;
    }
  }

  @override
  Future<void> dispose() async {
    await _stopPlayback(notifyDone: false);
    await _eventSub?.cancel();
  }

  String _friendlyError(Object error) {
    if (error is PlatformException) {
      return error.message ?? 'DeepSeek TTS 播放失败';
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401) return 'DeepSeek API Key 无效，请检查设置';
      if (status == 400) return 'DeepSeek TTS 拒绝了这段文本（请检查内容或长度）';
      if (status == 429) return 'DeepSeek TTS 请求过于频繁，请稍后再试';
      if (status == 503) return 'DeepSeek TTS 服务繁忙，请稍后再试';
      if (status == 504) return 'DeepSeek TTS 合成超时，请稍后再试';
      return 'DeepSeek TTS 请求失败（HTTP ${status ?? '未知'}）';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }
}
