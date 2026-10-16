import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'tts_engine.dart';

/// 非 Web 平台（目前项目只有 Android）的朗读引擎：走 MainActivity 里的
/// `deepseek_app/tts` 通道，用系统自带的 TextToSpeech，**离线可用、无需联网、
/// 不引入任何第三方依赖**。
TtsEngine createPlatformTtsEngine() =>
    Platform.isAndroid ? _AndroidTtsEngine() : UnsupportedTtsEngine();

/// 没有内置朗读能力的平台（桌面 / iOS 未适配等）：如实报「不支持」，
/// 让页面给出可执行的建议，而不是静默什么都不做。
class UnsupportedTtsEngine implements TtsEngine {
  final String reason;

  const UnsupportedTtsEngine({
    this.reason = '当前平台没有内置朗读引擎，请在 Android 设备上使用「听大纲改名」',
  });

  @override
  bool get isAvailable => false;

  @override
  bool get isSpeaking => false;

  @override
  String get errorMessage => reason;

  /// 本机没有朗读能力：如实地报「没有引擎」，让页面提示去系统设置装一个
  @override
  Future<TtsEngineStatus> diagnose() async =>
      const TtsEngineStatus(zhState: 'no_engine');

  @override
  Future<void> reset() async {}

  @override
  Future<bool> openTtsSettings() async => false;

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) async => false;

  /// 没有系统引擎可挑：只有一个「跟随系统」的选项
  @override
  Future<List<TtsEngineOption>> availableEngines() async =>
      const [TtsEngineOption.autoOption];

  @override
  Future<void> selectEngine(String engineId) async {}

  @override
  String get selectedEngineId => TtsEngineOption.autoId;

  @override
  Future<bool> init({String language = 'zh-CN'}) async => false;

  @override
  Future<bool> speak(TtsSpeechRequest request) async => false;

  @override
  Future<void> stop() async {}

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {}

  @override
  Future<void> dispose() async {}
}

/// Android 系统 TTS 引擎（方法通道 `deepseek_app/tts` + 事件通道 `.../events`）
class _AndroidTtsEngine implements TtsEngine {
  static const MethodChannel _methods = MethodChannel('deepseek_app/tts');
  static const EventChannel _events = EventChannel('deepseek_app/tts/events');

  StreamSubscription<dynamic>? _eventSub;
  VoidCallback? _onDone;
  void Function(String message)? _onError;

  bool _available = false;
  bool _speaking = false;
  String _error = '';

  /// 用户选的引擎：`auto` = 跟随系统默认，其余是系统 TTS 引擎的包名
  String _selected = TtsEngineOption.autoId;

  @override
  bool get isAvailable => _available;

  @override
  bool get isSpeaking => _speaking;

  @override
  String get errorMessage => _error;

  @override
  String get selectedEngineId => _selected;

  @override
  Future<List<TtsEngineOption>> availableEngines() async {
    final out = <TtsEngineOption>[TtsEngineOption.autoOption];
    try {
      final raw = await _methods.invokeMethod<List<dynamic>>('listEngines');
      final defaultEngine = await _methods.invokeMethod<String>('defaultEngine');
      for (final item in raw ?? const []) {
        final pkg = item?.toString() ?? '';
        if (pkg.isEmpty) continue;
        out.add(
          TtsEngineOption(
            id: pkg,
            label: pkg == defaultEngine ? '$pkg（系统默认）' : pkg,
          ),
        );
      }
    } catch (_) {
      // 列不出来就只给「跟随系统」这一项，功能不因此不可用
    }
    return out;
  }

  @override
  Future<void> selectEngine(String engineId) async {
    if (_selected == engineId) return;
    _selected = engineId;
    // 换引擎必须把旧实例丢掉重建，否则原生还抱着上一个引擎
    await reset();
  }

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    if (_available) return true;
    _listenEvents();
    try {
      final ok = await _methods.invokeMethod<bool>('init', {
        'language': language,
        // 'auto' 表示跟随系统默认；其余按包名指定引擎（设置面板里选的）
        if (_selected != TtsEngineOption.autoId) 'engine': _selected,
      });
      _available = ok ?? false;
      if (_available) {
        _error = '';
      } else {
        // init 只说「没成功」，说不出为什么；再问一次诊断，把原因落到可执行的文案上。
        // 诊断失败不影响主流程，退回原来那句通用提示。
        _error = await _failureMessage();
      }
    } on PlatformException catch (e) {
      _available = false;
      _error = _messageForCode(e.code, e.message);
    } on MissingPluginException {
      _available = false;
      _error = '当前设备没有接入朗读通道（请重新安装 App）';
    }
    return _available;
  }

  /// 初始化 / 朗读失败时的可执行文案。
  ///
  /// 分因的理由（真机复现过）：只缺中文语音包时引擎其实是好的，让用户去
  /// 「安装语音引擎」白折腾；反过来引擎被停用时，让他去下语音包也没用。
  Future<String> _failureMessage() async {
    final status = await diagnose();
    if (!status.hasEngine) {
      return '系统语音引擎初始化失败：本机没有可用的「文字转语音」引擎，'
          '请点下面的「去系统设置」装一个（讯飞语音引擎 / Google 语音服务等）并设为默认';
    }
    final zh = status.zhStateLabel;
    if (zh.isNotEmpty) {
      return '系统语音引擎初始化失败：$zh，请点下面的「去系统设置」处理后再回来重试';
    }
    return '系统语音引擎初始化失败：本机语音引擎没起来'
        '（可能被系统停用或冻结），请点下面的「去系统设置」检查，再回来重试';
  }

  /// PlatformException 的 code → 文案（code 由 MainActivity 侧给出）
  String _messageForCode(String code, String? message) => switch (code) {
    'TTS_NOT_INIT' => '语音引擎未就绪：请点下面的「去系统设置」检查本机的「文字转语音」引擎',
    'TTS_LANG_MISSING_DATA' =>
      '本机语音引擎缺少中文语音数据：请到「设置 → 文字转语音 → 引擎设置」里下载中文语音包',
    'TTS_LANG_NOT_SUPPORTED' => '本机语音引擎不支持中文：请到「设置 → 文字转语音」换一个支持中文的引擎',
    'TTS_SYNTH_FAILED' => '语音引擎拒绝了这次朗读，请重试或换一个引擎',
    _ => message ?? code,
  };

  @override
  Future<TtsEngineStatus> diagnose() async {
    try {
      final raw = await _methods.invokeMethod<Map<dynamic, dynamic>>('diagnose');
      if (raw == null) return const TtsEngineStatus();
      final engines = (raw['engines'] as List?)?.whereType<String>().toList() ?? const <String>[];
      return TtsEngineStatus(
        engines: engines,
        defaultEngine: raw['default'] as String?,
        zhState: (raw['zhState'] as String?) ?? 'unknown',
      );
    } catch (_) {
      // 诊断只是「把话说清楚」的加分项，失败不该盖掉原本的失败信息
      return const TtsEngineStatus();
    }
  }

  @override
  Future<void> reset() async {
    try {
      await _methods.invokeMethod<bool>('reset');
    } catch (_) {
      // 重置失败也要把本地状态放开，让下一次 init 至少重新走一遍
    }
    _available = false;
    _speaking = false;
    _error = '';
  }

  @override
  Future<bool> openTtsSettings() async {
    try {
      return await _methods.invokeMethod<bool>('openTtsSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) async {
    try {
      return await _methods.invokeMethod<bool>('openVoiceEngineStore', {
            'query': query,
          }) ??
          false;
    } catch (_) {
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
    try {
      final started = await _methods.invokeMethod<bool>('speak', {
        'text': request.text,
        'language': request.language,
        'rate': request.rate,
        'pitch': request.pitch,
      });
      _speaking = started ?? false;
      if (!_speaking) _error = '这段内容没能开始朗读，请重试';
      return _speaking;
    } on PlatformException catch (e) {
      _speaking = false;
      _error = _messageForCode(e.code, e.message);
      return false;
    } on MissingPluginException {
      _speaking = false;
      _error = '当前设备没有接入朗读通道（请重新安装 App）';
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _speaking = false;
    try {
      await _methods.invokeMethod<bool>('stop');
    } catch (_) {
      // 停止失败不该打断界面（本来就只是「别再读了」）
    }
  }

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    _onDone = onDone;
    _onError = onError;
    _listenEvents();
  }

  /// 原生侧读完 / 出错都从这里回来。
  ///
  /// 订阅只在第一次用到时建立：它必须在**朗读之前**就位，否则第一段读完的
  /// done 事件会丢，播放会停在第一条不动。
  void _listenEvents() {
    _eventSub ??= _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      switch (event['event']) {
        case 'done':
          _speaking = false;
          _error = '';
          _onDone?.call();
          break;
        case 'error':
          _speaking = false;
          _error = (event['message'] as String?) ?? '朗读失败';
          _onError?.call(_error);
          break;
      }
    }, onError: (Object e) {
      _error = '朗读通道异常：$e';
    });
  }

  @override
  Future<void> dispose() async {
    _onDone = null;
    _onError = null;
    await _eventSub?.cancel();
    _eventSub = null;
    await stop();
  }
}
