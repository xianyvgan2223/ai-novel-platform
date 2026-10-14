/// lib/core/config/deepseek_models.dart
/// DeepSeek 模型标识与显示名的唯一映射表。
///
/// 为什么要这层映射：官方 API 实际接受的名字并不整齐——
///   * flash 叫 `deepseek-flash`（**不带 v4**）
///   * pro   叫 `deepseek-v4-pro`（**必须带 v4**，写 `deepseek-pro` 会 400）
/// 于是界面上一律用简短的 flash / pro，发请求时再换成真实 ID，
/// 既不会让人误以为有两个"版本"，也不会拼错名字。
///
/// 实测（真 key 调 /chat/completions，2026-05）：
///   deepseek-flash    → 200
///   deepseek-pro      → 400 "The supported API model names are
///                            deepseek-flash, deepseek-v4-pro"
///   deepseek-v4-pro   → 200
/// 官方 /models 也只列出 `deepseek-flash` 与 `deepseek-v4-pro` 两个。
library;

class DeepSeekModels {
  /// flash 模型标识（官方名，不带 v4）
  static const String flashId = 'deepseek-flash';

  /// pro 模型标识（官方名，**必须**带 v4）
  static const String proId = 'deepseek-v4-pro';

  /// 下拉框里展示的模型：显示名 → 真实 API 标识
  ///
  /// 显示名刻意与真实标识分开：界面上统一写成 deepseek-flash / deepseek-pro
  /// （读起来一致、不带版本号歧义），而 pro 实际发出去的必须是
  /// `deepseek-v4-pro` —— 官方把 `deepseek-pro` 判为非法（400）。
  static const Map<String, String> displayToId = {
    'deepseek-flash': flashId,
    'deepseek-pro': proId,
  };

  /// 历史遗留标识 → 现行标识
  ///
  /// `deepseek-v4-flash` 曾是本应用的默认值：官方仍把它当别名接受，
  /// 但它并不是 /models 里的正式名字，所以统一收敛到 `deepseek-flash`。
  /// `deepseek-v4-pro` 保持原样（它就是正式名）。
  static const Map<String, String> legacyToCurrent = {
    'deepseek-v4-flash': flashId,
  };

  /// 可选项（下拉框顺序）
  static const List<String> selectableIds = [flashId, proId];

  /// 把任意写法（显示名 / 历史标识 / 真实标识）统一成真实 API 标识。
  ///
  /// 认不出来的一律原样返回：用户可以在"自定义模型"里填任意字符串，
  /// 拼错时让 API 自己报错，比在这里静默兜底更好排查。
  static String toApiId(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return flashId;
    final byDisplay = displayToId[v.toLowerCase()];
    if (byDisplay != null) return byDisplay;
    return legacyToCurrent[v] ?? v;
  }

  /// 真实标识 → 界面显示名；不是已知模型时返回 null（交由调用方按自定义处理）
  static String? toDisplayName(String raw) {
    final id = toApiId(raw);
    for (final e in displayToId.entries) {
      if (e.value == id) return e.key;
    }
    return null;
  }

  /// 该标识是否属于官方当前正式支持的模型
  static bool isOfficial(String raw) => selectableIds.contains(toApiId(raw));
}
