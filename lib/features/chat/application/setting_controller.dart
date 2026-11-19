/// lib/controllers/setting_controller.dart
/// 设置控制器 — 管理全局配置的加载、修改、保存
/// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  String get responseFormat => _setting.responseFormat;
  bool get thinking => _setting.thinking;
  String get reasoningEffort => _setting.reasoningEffort;
  bool get streamIncludeUsage => _setting.streamIncludeUsage;
  String get toolChoice => _setting.toolChoice;
  String get safetyCheck => _setting.safetyCheck;
  bool get titleEnabled => _setting.titleEnabled;
  String get userId => _setting.userId;
  bool get logprobs => _setting.logprobs;
  int get topLogprobs => _setting.topLogprobs;
  bool get webSearch => _setting.webSearch;
  String get baiduApiKey => _setting.baiduApiKey;
  int get searchCount => _setting.searchCount;
  String get searchFreshness => _setting.searchFreshness;
  String get searchEngine => _setting.searchEngine;
  bool get searchNeedContent => _setting.searchNeedContent;

  /// 聊天页是否显示缓存命中率（默认开启，见 [UserSetting.showCacheHit]）
  bool get showCacheHit => _setting.showCacheHit;

  /// 正在进行的加载（同一时刻只查一次库）
  Future<void>? _loading;

  /// 从数据库加载配置
  ///
  /// 幂等：App 启动时已被预热（见 ChatPage.initState），设置页打开时再调用
  /// 只是立即返回。否则会在页面推入动画中途 notify 一次，让整页从「转圈」
  /// 重建成完整表单——那次切换正是打开设置页掉帧的主因。
  Future<void> loadSettings() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
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
    _setting = _setting.copyWith(temperature: v.clamp(0.0, 2.0));
    notifyListeners();
  }

  void setTopP(double v) {
    _setting = _setting.copyWith(topP: v.clamp(0.0, 1.0));
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

  void setResponseFormat(String v) {
    _setting = _setting.copyWith(responseFormat: v);
    notifyListeners();
  }

  void setThinking(bool v) {
    // thinking 开着但强度为 none 时补回 high，避免界面显示开启、请求实际关闭。
    final effort = v && _setting.reasoningEffort == 'none'
        ? 'high'
        : _setting.reasoningEffort;
    _setting = _setting.copyWith(thinking: v, reasoningEffort: effort);
    notifyListeners();
  }

  void setReasoningEffort(String v) {
    final effort = const {'none', 'low', 'high', 'max'}.contains(v)
        ? v
        : 'high';
    _setting = _setting.copyWith(
      reasoningEffort: effort,
      thinking: effort == 'none' ? false : _setting.thinking,
    );
    notifyListeners();
  }

  void setStreamIncludeUsage(bool v) {
    _setting = _setting.copyWith(streamIncludeUsage: v);
    notifyListeners();
  }

  void setToolChoice(String v) {
    final choice = const {'auto', 'none', 'required'}.contains(v) ? v : 'auto';
    _setting = _setting.copyWith(toolChoice: choice);
    notifyListeners();
  }

  void setSafetyCheck(String v) {
    _setting = _setting.copyWith(safetyCheck: v == 'high' ? 'high' : 'low');
    notifyListeners();
  }

  void setTitleEnabled(bool v) {
    _setting = _setting.copyWith(titleEnabled: v);
    notifyListeners();
  }

  void setUserId(String v) {
    _setting = _setting.copyWith(userId: v);
    notifyListeners();
  }

  void setLogprobs(bool v) {
    _setting = _setting.copyWith(logprobs: v);
    notifyListeners();
  }

  void setTopLogprobs(int v) {
    _setting = _setting.copyWith(topLogprobs: v.clamp(0, 20));
    notifyListeners();
  }

  /// 历史遗留入口：联网开关现在由 [setSearchEngine] 统一管理
  /// （search_engine 是唯一事实来源）。这里转调一次，避免两个开关状态脱节。
  void setWebSearch(bool v) {
    setSearchEngine(
      v ? UserSetting.searchEngineBaidu : UserSetting.searchEngineOff,
    );
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

  /// 是否在聊天页显示缓存命中率（纯展示开关，不影响请求）
  void setShowCacheHit(bool v) {
    _setting = _setting.copyWith(showCacheHit: v);
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
}

/// SettingController Riverpod Provider（全局单例）
///
/// 放在控制器旁边而不是设置页里：聊天页、悬浮聊天面板等展示层都要读它，
/// 不应该为了一个 Provider 去 import 整个设置页。
final settingProvider = ChangeNotifierProvider<SettingController>(
  (ref) => SettingController(),
);
