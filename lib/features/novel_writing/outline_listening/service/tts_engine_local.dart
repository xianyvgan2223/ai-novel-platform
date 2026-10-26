import 'dart:async';

import 'package:flutter/services.dart';

import 'tts_engine.dart';

/// 内置离线朗读引擎（sherpa-onnx，模型随 App 一起装好）。
///
/// 为什么需要它：有些手机（魅族 18 / Flyme 这类精简 ROM）系统里**没有任何可用的
/// 「文字转语音」引擎**，系统 TTS 初始化必然失败——再清楚的提示也读不出声音。
/// 这条通道不依赖系统引擎：原生侧用 sherpa-onnx 本地合成，再用 AudioTrack 播出来。
///
/// 通道：方法 `deepseek_app/local_tts`；「读完了」走系统通道同一条事件通道
/// （原生侧转发），因此这里不需要自己订阅事件。
class _LocalTtsEngine implements TtsEngine {
  static const MethodChannel _methods = MethodChannel('deepseek_app/local_tts');

  bool _available = false;
  bool _speaking = false;
  String _error = '';

  @override
  bool get isAvailable => _available;

  @override
  bool get isSpeaking => _speaking;

  @override
  String get errorMessage => _error;

  /// 本机是不是带了内置模型（没带就没这条兜底路）
  static Future<bool> hasModel() async {
    try {
      return await _methods.invokeMethod<bool>('hasModel') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    if (_available) return true;
    try {
      final ok = await _methods.invokeMethod<bool>('init') ?? false;
      _available = ok;
      _error = ok ? '' : '内置语音初始化失败';
    } on MissingPluginException {
      _available = false;
      _error = '当前安装包没有内置语音通道';
    } on PlatformException catch (e) {
      _available = false;
      _error = '内置语音初始化失败：${e.message ?? e.code}';
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
        // 内置引擎只有语速这一个维度（音调由模型定），语速直接用设置的 rate；
        // 原生侧上限同样是 3.0，与设置面板的档位对齐
        'speed': request.rate,
      });
      _speaking = started ?? false;
      if (!_speaking) _error = '内置语音没能开始朗读';
      return _speaking;
    } catch (e) {
      _speaking = false;
      _error = '内置语音朗读失败：$e';
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _speaking = false;
    try {
      await _methods.invokeMethod<bool>('stop');
    } catch (_) {
      // 停止失败不该打断界面
    }
  }

  /// 内置离线语音用 AudioTrack 直接播放，本身不受 Activity 生命周期影响，
  /// 无需额外处理。
  @override
  Future<void> setBackgroundPlayback(bool enabled) async {}

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    // 「读完了」由原生侧经系统同一条事件通道回给包装层，这里不需要订阅
  }

  @override
  Future<TtsEngineStatus> diagnose() async {
    final has = await hasModel();
    return TtsEngineStatus(
      engines: has ? const ['builtin-sherpa-onnx'] : const [],
      defaultEngine: has ? 'builtin-sherpa-onnx' : null,
      zhState: has ? 'ok' : 'no_engine',
    );
  }

  @override
  Future<void> reset() async {
    await stop();
    _available = false;
    _error = '';
  }

  /// 内置引擎没有系统设置页可跳：装引擎 / 换引擎这套对它不适用
  @override
  Future<bool> openTtsSettings() async => false;

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) async => false;

  /// 内置语音自己不提供「选引擎」：能做到选择的是外面那层双路实现
  @override
  Future<List<TtsEngineOption>> availableEngines() async =>
      const [TtsEngineOption.builtinOption];

  @override
  Future<void> selectEngine(String engineId) async {}

  @override
  String get selectedEngineId => TtsEngineOption.builtinId;

  @override
  Future<void> dispose() async {
    await stop();
  }
}

/// 当前平台的内置朗读引擎。
///
/// 只有 Android 有（模型与原生库都只打进 Android 包）；其它平台给一个「没有内置语音」
/// 的空实现。
TtsEngine createLocalTtsEngine() => _LocalTtsEngine();

/// 本机是不是带了内置模型（原生侧查 assets；不需要先初始化引擎）。
Future<bool> localTtsHasModel() => _LocalTtsEngine.hasModel();
