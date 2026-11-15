import 'package:flutter/foundation.dart';

import 'deepseek_tts_engine.dart';
import 'tts_engine.dart';
import 'tts_engine_fallback.dart';

/// TTS 引擎组合：DeepSeek 官方语音 + 本机系统/离线语音。
///
/// 之前只保留 DeepSeek 引擎，导致设置里的「朗读引擎」和系统 TTS 选项被删掉。
/// 现在恢复引擎选择：既可以用系统 TTS（含 App 内置离线兜底），也可以选
/// DeepSeek 的 stella / tide 音色。语速由设置页统一下发，DeepSeek 音频
/// 由原生 MediaPlayer 的 PlaybackParams 提速。
class HybridTtsEngine implements TtsEngine {
  HybridTtsEngine({DeepSeekTtsEngine? deepSeek, FallbackTtsEngine? system})
    : _deepSeek = deepSeek ?? DeepSeekTtsEngine(),
      _system = system ?? FallbackTtsEngine();

  final DeepSeekTtsEngine _deepSeek;
  final FallbackTtsEngine _system;

  String _selected = 'deepseek:stella';
  bool _deepSeekReady = false;
  bool _systemReady = false;
  bool _disposed = false;
  String _error = '';

  static const String deepSeekPrefix = 'deepseek:';

  bool get _useDeepSeek => _selected.startsWith(deepSeekPrefix);
  String get _deepSeekVoice => _selected.substring(deepSeekPrefix.length);

  TtsEngine get _activeEngine => _useDeepSeek ? _deepSeek : _system;

  bool get usingBuiltinVoice =>
      !_useDeepSeek && _system.usingLocal;

  @override
  bool get isAvailable =>
      _useDeepSeek ? _deepSeekReady && _deepSeek.isAvailable : _system.isAvailable;

  @override
  bool get isSpeaking => _activeEngine.isSpeaking;

  @override
  String get errorMessage =>
      _error.isNotEmpty ? _error : _activeEngine.errorMessage;

  @override
  String get selectedEngineId => _selected;

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    _deepSeek.setCallbacks(
      onDone: onDone,
      onError: (message) {
        _error = message;
        onError?.call(message);
      },
    );
    _system.setCallbacks(
      onDone: onDone,
      onError: (message) {
        _error = message;
        onError?.call(message);
      },
    );
  }

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    _systemReady = await _system.init(language: language);
    _deepSeekReady = await _deepSeek.init(language: language);
    if (_useDeepSeek) {
      final ok = _deepSeekReady;
      _error = ok ? '' : _deepSeek.errorMessage;
      return ok;
    }
    final ok = _system.isAvailable;
    _error = ok ? '' : _system.errorMessage;
    return ok;
  }

  @override
  Future<bool> speak(TtsSpeechRequest request) async {
    _error = '';
    if (_useDeepSeek) {
      if (!_deepSeekReady) {
        _deepSeekReady = await _deepSeek.init(language: request.language);
        if (!_deepSeekReady) {
          _error = _deepSeek.errorMessage;
          return false;
        }
      }
      return _deepSeek.speak(
        TtsSpeechRequest(
          text: request.text,
          language: request.language,
          rate: request.rate,
          pitch: request.pitch,
          voiceId: _deepSeekVoice,
        ),
      );
    }
    if (!_system.isAvailable) {
      _systemReady = await _system.init(language: request.language);
      if (!_systemReady) {
        _error = _system.errorMessage;
        return false;
      }
    }
    return _system.speak(request);
  }

  @override
  Future<void> stop() async {
    await _system.stop();
    await _deepSeek.stop();
  }

  @override
  Future<void> setBackgroundPlayback(bool enabled) async {
    await _system.setBackgroundPlayback(enabled);
    await _deepSeek.setBackgroundPlayback(enabled);
  }

  @override
  Future<TtsEngineStatus> diagnose() async {
    if (_useDeepSeek) {
      if (!_deepSeekReady) _deepSeekReady = await _deepSeek.init();
      return TtsEngineStatus(
        engines: DeepSeekTtsEngine.voiceOptions.map((e) => e.id).toList(),
        defaultEngine: _deepSeekVoice,
        zhState: _deepSeekReady ? 'ok' : 'no_engine',
      );
    }
    return _system.diagnose();
  }

  @override
  Future<void> reset() async {
    await _system.reset();
    await _deepSeek.reset();
    _systemReady = false;
    _deepSeekReady = false;
  }

  @override
  Future<bool> openTtsSettings() => _system.openTtsSettings();

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) =>
      _system.openVoiceEngineStore(query: query);

  @override
  Future<List<TtsEngineOption>> availableEngines() async {
    final systemOptions = await _system.availableEngines();
    return [
      for (final voice in DeepSeekTtsEngine.voiceOptions)
        TtsEngineOption(
          id: '$deepSeekPrefix${voice.id}',
          label: 'DeepSeek · ${voice.label}',
        ),
      ...systemOptions,
    ];
  }

  @override
  Future<void> selectEngine(String engineId) async {
    if (engineId.startsWith(deepSeekPrefix)) {
      final voice = engineId.substring(deepSeekPrefix.length);
      if (!DeepSeekTtsEngine.voiceOptions.any((e) => e.id == voice)) return;
      await _deepSeek.selectEngine(voice);
      _selected = engineId;
      return;
    }
    if (engineId == TtsEngineOption.autoId ||
        engineId == TtsEngineOption.builtinId) {
      // auto / builtin 是稳定语义，即使未安装本地模型也允许选中；
      // 真正朗读时再由 init 返回原因，避免设置项看起来「点了没反应」。
      await _system.selectEngine(engineId);
      _selected = engineId;
      return;
    }
    final systemOptions = await _system.availableEngines();
    if (!systemOptions.any((o) => o.id == engineId)) return;
    await _system.selectEngine(engineId);
    _selected = engineId;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _system.dispose();
    await _deepSeek.dispose();
  }
}
