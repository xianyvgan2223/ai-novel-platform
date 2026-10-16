import 'package:flutter/foundation.dart';

import 'tts_engine_io.dart'
    if (dart.library.js_interop) 'tts_engine_web.dart'
    if (dart.library.html) 'tts_engine_web.dart'
    as impl;

/// 一次朗读请求。
///
/// 刻意把「读什么」与「怎么读」放在一起传：语音引擎每次朗读都要重新设
/// 语速 / 音调 / 语言，分开传容易出现「上一个事件的语速漏到这一个」。
@immutable
class TtsSpeechRequest {
  final String text;

  /// BCP-47 语言标签（如 `zh-CN`）。设备缺该语言的语音包时由实现方退回默认语言，
  /// 而不是干脆不读。
  final String language;

  /// 语速，1.0 为正常
  final double rate;

  /// 音调，1.0 为正常
  final double pitch;

  const TtsSpeechRequest({
    required this.text,
    this.language = 'zh-CN',
    this.rate = 1.0,
    this.pitch = 1.0,
  });
}

/// 朗读引擎的抽象接口。
///
/// 为什么要有这层抽象：
/// - 平台差异（Android 走原生 TextToSpeech，Web 走浏览器 SpeechSynthesis，
///   其余平台没有内置引擎）由各实现自己吞掉，页面只认这一套方法；
/// - widget 测试里注入 [FakeTtsEngine]，无需真实引擎就能验「读完自动读下一条」
///   这类流程。
abstract class TtsEngine {
  /// 设备上是否有可用的朗读引擎（Android 上等于「系统 TTS 初始化成功」）
  bool get isAvailable;

  /// 是否正在朗读
  bool get isSpeaking;

  /// 初始化。返回是否可用；不可用时 [errorMessage] 给出原因。
  Future<bool> init({String language = 'zh-CN'});

  /// 朗读一段文本（打断当前正在读的内容）。
  ///
  /// 返回是否成功**开始**朗读；假值时 [errorMessage] 有原因。
  Future<bool> speak(TtsSpeechRequest request);

  /// 立刻停止朗读
  Future<void> stop();

  /// 一段读完后回调；[onError] 仅在异常中断时回调
  void setCallbacks({required VoidCallback onDone, void Function(String message)? onError});

  /// 最近一次失败的原因（无失败时为空串）。UI 直接展示它，不再自己造文案。
  String get errorMessage;

  /// 释放引擎
  Future<void> dispose();
}

/// 创建当前平台的朗读引擎。
///
/// 测试请直接注入 `FakeTtsEngine`（见 `tts_engine_fake.dart`）——这里返回的实现
/// 在测试环境（既非 Android 也非 Web）一定是 [UnsupportedTtsEngine]。
TtsEngine createTtsEngine() => impl.createPlatformTtsEngine();
