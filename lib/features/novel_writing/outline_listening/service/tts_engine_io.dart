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

  @override
  bool get isAvailable => _available;

  @override
  bool get isSpeaking => _speaking;

  @override
  String get errorMessage => _error;

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    if (_available) return true;
    _listenEvents();
    try {
      final ok = await _methods.invokeMethod<bool>('init', {
        'language': language,
      });
      _available = ok ?? false;
      if (!_available) {
        _error = '系统语音引擎初始化失败，请在系统设置里安装 / 启用「文字转语音」引擎';
      }
    } on PlatformException catch (e) {
      _available = false;
      _error = '系统语音引擎初始化失败：${e.message ?? e.code}';
    } on MissingPluginException {
      _available = false;
      _error = '当前设备没有接入朗读通道（请重新安装 App）';
    }
    return _available;
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
      _error = '朗读失败：${e.message ?? e.code}';
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
