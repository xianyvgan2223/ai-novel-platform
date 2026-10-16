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

/// 本机语音引擎的现状快照（[TtsEngine.diagnose] 的返回）。
///
/// 为什么单独要一个「诊断」而不只看 init 的成败：init 返回 false 时可能是
/// 「根本没装引擎」「引擎被停用」「引擎不支持中文」，这三种要给用户的下一步
/// 完全不同（装引擎 / 去应用管理里启用 / 换引擎或下载中文语音包）。
@immutable
class TtsEngineStatus {
  /// 系统里可用的 TTS 引擎包名（没有引擎时为空表）
  final List<String> engines;

  /// 系统默认 TTS 引擎包名（可能为空）
  final String? defaultEngine;

  /// 中文可用性：`ok` / `missing_data` / `not_supported` / `no_engine` / `unknown`
  final String zhState;

  const TtsEngineStatus({
    this.engines = const [],
    this.defaultEngine,
    this.zhState = 'unknown',
  });

  /// 本机有没有任何可用的语音引擎
  bool get hasEngine => engines.isNotEmpty;

  /// 中文可用性文案（给错误提示用；`ok` 时返回空串）
  String get zhStateLabel => switch (zhState) {
    'missing_data' => '本机语音引擎缺少中文语音数据',
    'not_supported' => '本机语音引擎不支持中文',
    'no_engine' => '本机没有可用的语音引擎',
    _ => '',
  };
}

/// 朗读引擎的抽象接口。
///
/// 为什么要有这层抽象：
/// - 平台差异（Android 走原生 TextToSpeech，Web 走浏览器 SpeechSynthesis，
///   其余平台没有内置引擎）由各实现自己吞掉，页面只认这一套方法；
/// - widget 测试里注入 [FakeTtsEngine]，无需真实引擎就能验「读完自动读下一条」
///   这类流程。
/// 一个可选用的朗读引擎（设置面板里的「朗读用哪个引擎」）。
@immutable
class TtsEngineOption {
  /// 引擎标识：
  /// - [TtsEngineOption.autoId]：跟随系统默认（系统没有就用内置语音）
  /// - [TtsEngineOption.builtinId]：App 自带的离线语音
  /// - 其余为系统 TTS 引擎的包名（如 `com.reecedunn.espeak`）
  final String id;

  /// 界面上显示的名字
  final String label;

  /// 是不是 App 自带的离线语音
  final bool builtin;

  const TtsEngineOption({
    required this.id,
    required this.label,
    this.builtin = false,
  });

  /// 默认项：跟随系统（系统引擎优先，系统没有才用内置语音）
  static const String autoId = 'auto';

  /// App 自带离线语音的标识
  static const String builtinId = 'builtin';

  static const TtsEngineOption autoOption = TtsEngineOption(
    id: autoId,
    label: '跟随系统（系统没有就用内置语音）',
  );

  static const TtsEngineOption builtinOption = TtsEngineOption(
    id: builtinId,
    label: '内置离线语音（App 自带，不占系统）',
    builtin: true,
  );

  @override
  bool operator ==(Object other) => other is TtsEngineOption && other.id == id;

  @override
  int get hashCode => id.hashCode;
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

  /// 初始化失败时的原因排查（本机有几个引擎 / 默认引擎 / 中文支持情况）。
  ///
  /// 各实现必须给出自己的答案：诊断直接决定给用户看的是「装引擎」还是
  /// 「下中文语音包」，写成默认空实现会让提示退化成笼统的那句。
  Future<TtsEngineStatus> diagnose();

  /// 丢掉当前引擎实例并允许下次 [init] 重建。
  ///
  /// 调用时机：用户在系统里装好 / 启用好语音引擎、换过发音人之后。原生侧的引擎
  /// 实例与初始化结果都是缓存的，光调 [init] 拿不回新引擎，必须先丢实例。
  Future<void> reset();

  /// 打开系统「文字转语音」设置页；本机没有这个页面时返回 false。
  Future<bool> openTtsSettings();

  /// 打开应用商店的搜索页找语音引擎（本机装引擎的唯一自助途径）；没有商店时返回 false。
  ///
  /// 为什么要这条：[openTtsSettings] 只能带用户去系统设置页，而魅族这类精简 ROM 的
  /// 「文字转语音」页里**首选引擎是「无」**——用户到那儿也没东西可选，得先装一个
  /// 引擎 App。App 不能替用户装（Android 不允许静默安装 APK），能做的就是把他送到
  /// 商店搜索页，一步装完。
  Future<bool> openVoiceEngineStore({String query = '语音引擎'});

  /// 本机可以选用的朗读引擎（设置面板里给用户挑）。
  ///
  /// 约定：第一项是 [TtsEngineOption.auto]，其后若有内置语音则是 [TtsEngineOption.builtin]，
  /// 再往后是系统里安装的各个 TTS 引擎包名。不支持选择的平台只返回前两项。
  Future<List<TtsEngineOption>> availableEngines();

  /// 指定后续朗读用哪个引擎（[TtsEngineOption.autoId] = 跟随系统默认）。
  ///
  /// 切换引擎要重新初始化：调用方应先 [reset] 再 [init]。
  Future<void> selectEngine(String engineId);

  /// 当前选中的引擎标识（默认 [TtsEngineOption.autoId]）
  String get selectedEngineId;

  /// 释放引擎
  Future<void> dispose();
}

/// 创建当前平台的朗读引擎。
///
/// 测试请直接注入 `FakeTtsEngine`（见 `tts_engine_fake.dart`）——这里返回的实现
/// 在测试环境（既非 Android 也非 Web）一定是 [UnsupportedTtsEngine]。
///
/// 注意：这只是**系统**那一条路。页面要的是「系统优先 + 内置兜底」，
/// 用 `tts_engine_fallback.dart` 里的 `FallbackTtsEngine`。
TtsEngine createTtsEngine() => impl.createPlatformTtsEngine();
