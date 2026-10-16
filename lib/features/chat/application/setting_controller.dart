/// lib/controllers/setting_controller.dart
/// 设置控制器 — 管理全局配置的加载、修改、保存
/// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'package:flutter/foundation.dart';
import '../../../core/config/user_setting.dart';
import '../../../core/config/user_setting_service.dart';

class SettingController extends ChangeNotifier {
  UserSetting _setting = const UserSetting();
  bool _loaded = false;

  // ── 只读 getter ──
  bool get isLoaded => _loaded;
  String get apiKey => _setting.apiKey;
  String get model => _setting.model;
  double get temperature => _setting.temperature;
  double get topP => _setting.topP;
  int get maxTokens => _setting.maxTokens;
  String get stop => _setting.stop;
  bool get stream => _setting.stream;
  String get streamOptions => _setting.streamOptions;
  double get frequencyPenalty => _setting.frequencyPenalty;
  double get presencePenalty => _setting.presencePenalty;
  String get responseFormat => _setting.responseFormat;
  bool get thinking => _setting.thinking;
  bool get logprobs => _setting.logprobs;
  int get topLogprobs => _setting.topLogprobs;
  String get logitBias => _setting.logitBias;
  int get n => _setting.n;
  int get contextRounds => _setting.contextRounds;
  bool get webSearch => _setting.webSearch;
  String get baiduApiKey => _setting.baiduApiKey;
  int get searchCount => _setting.searchCount;
  String get searchFreshness => _setting.searchFreshness;
  String get searchEngine => _setting.searchEngine;
  bool get searchNeedContent => _setting.searchNeedContent;

  /// 从数据库加载配置
  Future<void> loadSettings() async {
    try {
      _setting = await UserSettingService.getSettings();
    } catch (_) {
      _setting = const UserSetting();
    }
    _loaded = true;
    notifyListeners();
  }

  /// 保存当前配置到数据库
  Future<void> saveSettings() async {
    await UserSettingService.saveSettings(_setting);
  }

  // ── setter ──

  void setApiKey(String v) {
    _setting = _setting.copyWith(apiKey: v);
    notifyListeners();
  }

  void setModel(String v) {
    _setting = _setting.copyWith(model: v);
    notifyListeners();
  }

  void setTemperature(double v) {
    _setting = _setting.copyWith(temperature: v);
    notifyListeners();
  }

  void setTopP(double v) {
    _setting = _setting.copyWith(topP: v);
    notifyListeners();
  }

  void setMaxTokens(int v) {
    _setting = _setting.copyWith(
      maxTokens: v.clamp(1, UserSetting.maxTokensMax),
    );
    notifyListeners();
  }

  void setStop(String v) {
    _setting = _setting.copyWith(stop: v);
    notifyListeners();
  }

  void setStream(bool v) {
    _setting = _setting.copyWith(stream: v);
    notifyListeners();
  }

  void setStreamOptions(String v) {
    _setting = _setting.copyWith(streamOptions: v);
    notifyListeners();
  }

  void setFrequencyPenalty(double v) {
    _setting = _setting.copyWith(frequencyPenalty: v);
    notifyListeners();
  }

  void setPresencePenalty(double v) {
    _setting = _setting.copyWith(presencePenalty: v);
    notifyListeners();
  }

  void setResponseFormat(String v) {
    _setting = _setting.copyWith(responseFormat: v);
    notifyListeners();
  }

  void setThinking(bool v) {
    _setting = _setting.copyWith(thinking: v);
    notifyListeners();
  }

  void setLogprobs(bool v) {
    _setting = _setting.copyWith(logprobs: v);
    notifyListeners();
  }

  void setTopLogprobs(int v) {
    _setting = _setting.copyWith(topLogprobs: v);
    notifyListeners();
  }

  void setLogitBias(String v) {
    _setting = _setting.copyWith(logitBias: v);
    notifyListeners();
  }

  void setN(int v) {
    _setting = _setting.copyWith(n: v);
    notifyListeners();
  }

  void setContextRounds(int v) {
    _setting = _setting.copyWith(contextRounds: v);
    notifyListeners();
  }

  /// 历史遗留入口：联网开关现在由 [setSearchEngine] 统一管理
  /// （search_engine 是唯一事实来源）。这里转调一次，避免两个开关状态脱节。
  void setWebSearch(bool v) {
    setSearchEngine(v ? UserSetting.searchEngineBaidu : UserSetting.searchEngineOff);
  }

  void setBaiduApiKey(String v) {
    _setting = _setting.copyWith(baiduApiKey: v);
    notifyListeners();
  }

  void setSearchCount(int v) {
    _setting = _setting.copyWith(searchCount: v);
    notifyListeners();
  }

  void setSearchFreshness(String v) {
    _setting = _setting.copyWith(searchFreshness: v);
    notifyListeners();
  }

  /// 是否抓取网页正文（DeepSeek 官方搜索的 need_content）
  void setSearchNeedContent(bool v) {
    _setting = _setting.copyWith(searchNeedContent: v);
    notifyListeners();
  }

  void setSearchEngine(String v) {
    // search_engine 是联网搜索的「唯一事实来源」，旧的 web_search 布尔量
    // 只是历史遗留：这里同步写一次，保证两处判断永远一致
    // （chat_controller 只认 searchEngine，避免两个开关互相打架）。
    _setting = _setting.copyWith(
      searchEngine: v,
      webSearch: v != UserSetting.searchEngineOff,
    );
    notifyListeners();
  }

  /// context_rounds 静态裁剪：1 ~ 100
  static int clampContextRounds(int v) => v.clamp(1, 100);
}
