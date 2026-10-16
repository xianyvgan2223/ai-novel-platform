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
