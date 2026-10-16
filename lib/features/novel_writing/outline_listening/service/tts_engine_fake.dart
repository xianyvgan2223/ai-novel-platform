import 'package:flutter/foundation.dart';

import 'tts_engine.dart';

/// 测试用的朗读引擎：不发出任何声音，把「读了什么」记下来，
/// 由测试自己决定什么时候算读完（[finishCurrent]）。
///
/// 为什么需要它：真机上的自动连读依赖原生朗读完成回调，widget 测试里既没有
/// 原生通道也没有异步音频；用一个假引擎就能把「读完自动读下一条」这条链路
/// 完整测出来（否则这条逻辑只能靠真机手测）。
class FakeTtsEngine implements TtsEngine {
  /// 是否可用（构造时可设为 false，模拟「设备没有语音引擎」）
  bool available;

  /// 每次 [speak] 的文本，按调用顺序记录
  final List<String> spoken = [];

  /// 每次 [speak] 的完整请求（语速 / 语言等设置也在这里验）
  final List<TtsSpeechRequest> requests = [];

  /// [stop] 的调用次数
  int stopCount = 0;

  /// [reset] 的调用次数（「重试」是否真的把引擎丢掉重建，靠它验）
  int resetCount = 0;

  /// 下一次 [speak] 是否返回失败（模拟引擎报错）
  bool failNextSpeak = false;

  /// 最近一次失败原因
  @override
  String errorMessage = '';

  VoidCallback? _onDone;
  void Function(String message)? _onError;
  bool _speaking = false;

  FakeTtsEngine({this.available = true});

  @override
  bool get isAvailable => available;

  @override
  bool get isSpeaking => _speaking;

  @override
  Future<bool> init({String language = 'zh-CN'}) async => available;

  /// 「重试」要把引擎丢掉重建：假引擎只需记下次数并清掉上次的失败文案，
  /// 这样测试能区分「真重试了」和「只把错误条关了」。
  @override
  Future<void> reset() async {
    resetCount++;
    errorMessage = '';
    _speaking = false;
  }

  /// 测试可注入：本机有没有 TTS 引擎、中文支持情况。
  ///
  /// 默认是「一切正常」：绝大多数测试关心的是朗读流程，不该被引擎体检提示条干扰；
  /// 要验「本机没有引擎 / 缺中文语音包」的测试自己注入对应状态。
  TtsEngineStatus status = const TtsEngineStatus(
    engines: ['com.iflytek.speechsuite'],
    defaultEngine: 'com.iflytek.speechsuite',
    zhState: 'ok',
  );

  @override
  Future<TtsEngineStatus> diagnose() async => status;

  /// [openTtsSettings] 的调用次数：页面上的「去系统设置」按钮是否真的接了通道
  int openSettingsCount = 0;

  @override
  Future<bool> openTtsSettings() async {
    openSettingsCount++;
    return true;
  }

  /// [openVoiceEngineStore] 的调用次数：没有引擎时页面是否给出了「去商店装」这条路
  int openStoreCount = 0;
  String? lastStoreQuery;

  @override
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) async {
    openStoreCount++;
    lastStoreQuery = query;
    return true;
  }

  /// 测试可注入的「可选引擎」清单
  List<TtsEngineOption> engineOptions = [
    TtsEngineOption.autoOption,
    TtsEngineOption.builtinOption,
    const TtsEngineOption(id: 'com.reecedunn.espeak', label: 'com.reecedunn.espeak'),
  ];

  String _selectedEngineId = TtsEngineOption.autoId;

  @override
  Future<List<TtsEngineOption>> availableEngines() async => engineOptions;

  @override
  Future<void> selectEngine(String engineId) async {
    _selectedEngineId = engineId;
  }

  @override
  String get selectedEngineId => _selectedEngineId;

  @override
  Future<bool> speak(TtsSpeechRequest request) async {
    requests.add(request);
    if (!available) {
      errorMessage = '设备没有可用的语音引擎';
      return false;
    }
    if (failNextSpeak) {
      failNextSpeak = false;
      _speaking = false;
      errorMessage = '朗读失败（测试）';
      return false;
    }
    spoken.add(request.text);
    _speaking = true;
    errorMessage = '';
    return true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _speaking = false;
  }

  @override
  void setCallbacks({
    required VoidCallback onDone,
    void Function(String message)? onError,
  }) {
    _onDone = onDone;
    _onError = onError;
  }

  /// 测试主动触发「这一段读完了」
  void finishCurrent() {
    _speaking = false;
    _onDone?.call();
  }

  /// 测试主动触发「朗读出错」
  void failCurrent(String message) {
    _speaking = false;
    errorMessage = message;
    _onError?.call(message);
  }

  @override
  Future<void> dispose() async {
    _onDone = null;
    _onError = null;
    _speaking = false;
  }
}
