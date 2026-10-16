import 'package:flutter/foundation.dart';

import 'tts_engine.dart';
import 'tts_engine_local.dart';

/// 朗读引擎的**双路**实现：按设置里选的引擎朗读，系统用不了就回落到内置离线语音。
///
/// 三条路（设置面板里可选）：
/// - [TtsEngineOption.autoId]：**默认**。系统引擎优先，系统没有才用 App 自带语音；
/// - [TtsEngineOption.builtinId]：强制用 App 自带的离线语音（不挑手机，永远能读）；
/// - 某个系统引擎包名（如 `com.reecedunn.espeak`）：只用那一个系统引擎。
///
/// 为什么要有这一层（真机教训）：
/// - 有些手机（魅族 18 / Flyme 这类精简 ROM）系统里**一个「文字转语音」引擎都没有**，
///   系统 `TextToSpeech` 必然初始化失败——那时页面上给再多提示也读不出声音；
/// - 内置语音（sherpa-onnx，模型随包安装）不依赖系统引擎，装上就能读；
/// - 但系统引擎可用时**仍然优先用系统**：音色跟随用户手机设置、不额外吃 CPU。
///
/// 对外它就是 [TtsEngine]，页面与控制器不需要知道声音是从哪条路出来的。
class FallbackTtsEngine implements TtsEngine {
  FallbackTtsEngine({TtsEngine? system, TtsEngine? local})
    : _system = system ?? createTtsEngine(),
      _local = local ?? createLocalTtsEngine();

  final TtsEngine _system;
  final TtsEngine _local;

  /// 当前实际在用的引擎：null = 还没定（[init] 里决定）
  TtsEngine? _active;

  /// 用户选定的引擎（[TtsEngineOption.autoId] = 跟随系统）
  String _preference = TtsEngineOption.autoId;

  /// 本机装了内置模型吗（原生侧查 assets）
  bool localModelAvailable = false;

  String _error = '';

  /// 系统引擎不可用、正在用内置语音（页面据此提示用户）
  bool get usingLocal => _active == _local;

  @override
  bool get isAvailable => _active?.isAvailable ?? false;

  @override
  bool get isSpeaking => _active?.isSpeaking ?? false;

  @override
  String get errorMessage => _error.isNotEmpty ? _error : (_active?.errorMessage ?? '');

  @override
  String get selectedEngineId => _preference;

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    // 两条路都挂上：事件通道是共用的，谁在播谁回调
    _system.setCallbacks(onDone: onDone, onError: onError);
    _local.setCallbacks(
      onDone: onDone,
      onError: (message) {
        _error = message;
        onError?.call(message);
      },
    );
  }

  @override
  Future<bool> init({String language = 'zh-CN'}) async {
    localModelAvailable = await localTtsHasModel();

    // 1) 设置里指定了「只用内置语音」：不碰系统引擎
    if (_preference == TtsEngineOption.builtinId) {
      return _initLocal(language);
    }

    // 2) 设置里指定了某个系统引擎：把选择透传给系统那条路
    if (_preference != TtsEngineOption.autoId) {
      await _system.selectEngine(_preference);
    }

    // 3) 先试系统引擎（手机里装了引擎时这条路音色最好、最省资源）
    final systemOk = await _system.init(language: language);
    if (systemOk) {
      _active = _system;
      _error = '';
      return true;
    }

    // 4) 系统不行、而且是「跟随系统」模式 → 回落到内置语音
    if (_preference == TtsEngineOption.autoId && localModelAvailable) {
      return _initLocal(language);
    }

    // 5) 都不行：把系统那条的原因说给用户（它更能指导装引擎）
    _active = null;
    _error = _system.errorMessage.isNotEmpty
        ? _system.errorMessage
        : '本机既没有可用的系统语音引擎，内置语音也没能起来';
    return false;
  }

  Future<bool> _initLocal(String language) async {
    if (!localModelAvailable) {
      _active = null;
      _error = '本机没有内置语音（安装包里没带模型）';
      return false;
    }
    final ok = await _local.init(language: language);
    if (ok) {
      _active = _local;
      _error = '';
      return true;
    }
    _active = null;
    _error = _local.errorMessage.isNotEmpty ? _local.errorMessage : '内置语音没能启动';
    return false;
  }

  @override
  Future<bool> speak(TtsSpeechRequest request) async {
    var engine = _active;
    if (engine == null) {
      final ok = await init(language: request.language);
      if (!ok) return false;
      engine = _active;
      if (engine == null) return false;
    }
    final started = await engine.speak(request);
    if (started) {
      _error = '';
    } else {
      _error = engine.errorMessage.isNotEmpty ? engine.errorMessage : '朗读失败，请重试';
    }
    return started;
  }

  @override
  Future<void> stop() async {
    // 两条都停：切换过路径后，上一条可能还在播
    await _system.stop();
    await _local.stop();
  }

  @override
  Future<TtsEngineStatus> diagnose() async {
    localModelAvailable = await localTtsHasModel();
    final system = await _system.diagnose();
    // 指定只用内置语音时，系统有没有引擎与本次朗读无关
    if (_preference == TtsEngineOption.builtinId) {
      return localModelAvailable
          ? const TtsEngineStatus(
              engines: ['builtin-sherpa-onnx'],
              defaultEngine: 'builtin-sherpa-onnx',
              zhState: 'ok',
            )
          : system;
    }
    // 系统引擎存在且中文可用 → 照实报系统的情况
    if (system.hasEngine && system.zhState != 'no_engine') return system;
    // 系统不可用但内置可用 → 报「内置可用」，页面不该再吓唬用户去装引擎
    if (_preference == TtsEngineOption.autoId && localModelAvailable) {
      return const TtsEngineStatus(
        engines: ['builtin-sherpa-onnx'],
        defaultEngine: 'builtin-sherpa-onnx',
        zhState: 'ok',
      );
    }
    return system;
  }

  @override
  Future<List<TtsEngineOption>> availableEngines() async {
    localModelAvailable = await localTtsHasModel();
    final out = <TtsEngineOption>[TtsEngineOption.autoOption];
    if (localModelAvailable) out.add(TtsEngineOption.builtinOption);
    final system = await _system.availableEngines();
    for (final option in system) {
      if (option.id == TtsEngineOption.autoId) continue; // 已经在第一项
      out.add(option);
    }
    return out;
  }

  /// 选引擎：记住选择，并把两条路都重置——下次 [init] 才按新引擎重新绑定。
  ///
  /// 不在这里直接 init：页面拿到结果后会走统一的「重试 / 重新准备」流程，
  /// 免得这里 init 一次、页面又 init 一次。
  @override
  Future<void> selectEngine(String engineId) async {
    if (_preference == engineId) return;
    _preference = engineId;
    await reset();
  }

  @override
  Future<void> reset() async {
    await _system.reset();
    await _local.reset();
    _active = null;
    _error = '';
  }

  @override
  Future<bool> openTtsSettings() => _system.openTtsSettings();

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) =>
      _system.openVoiceEngineStore(query: query);

  @override
  Future<void> dispose() async {
    await _system.dispose();
    await _local.dispose();
  }
}
