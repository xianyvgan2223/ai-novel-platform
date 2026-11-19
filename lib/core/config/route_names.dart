/// lib/core/config/route_names.dart
/// 全应用共享的命名路由名。
///
/// 目前只服务于一条规则：「哪些全屏页面要隐藏全局悬浮聊天球」。悬浮球挂在
/// Overlay 上、固定停在屏幕右侧（top = 屏幕高 - 200dp），而设置页这种整页
/// 表单右上角全是开关与输入框，球会一路压着控件。让浮层按路由名识别页面，
/// 比在每个页面里各自控制可见性更稳：页面被重建、被从不同入口推入都不漏。
library;

/// 主设置页的路由名（入口有两处：主页右上 ⋮ → 设置；小说游戏页的「设置」）。
///
/// 每一处 push 都必须带上这个 name，否则从那一侧进入时悬浮球仍会盖住页面。
const String kSettingsRouteName = '/settings';

/// 会话设置页（主页点会话标题进入，系统提示词编辑）。
const String kSessionSettingsRouteName = '/session_settings';

/// 大纲生成设置页（「一键生成大纲」页右上齿轮进入）。
const String kOutlineSettingsRouteName = '/outline_settings';

/// 章节写作设置页（章节写作页 AppBar「AI 设置」进入）。
const String kChapterSettingsRouteName = '/chapter_settings';

/// 战斗设置页（「AI 写战斗」页右上齿轮进入）。
const String kBattleSettingsRouteName = '/battle_settings';
/// 大纲编辑 AI 生成设置页（大纲编辑 → AI 生成面板右上齿轮进入）。
const String kOutlineEditAiSettingsRouteName = '/outline_edit_ai_settings';

/// 这些「整页设置」路由上不显示全局悬浮聊天球。
///
/// 球是 Overlay 上的固定层，设置页右上角又全是开关、滑杆、输入框，真机截图
/// 里每个滚动位置都被盖住一块（主设置页上一轮已按同一机制隐藏）。新增同类
/// 设置页时的做法：给它的 push 加 `settings: RouteSettings(name: ...)`，
/// 再把路由名加进这个集合，浮层会自动跟着隐藏。
const Set<String> kHideBallRouteNames = {
  kSettingsRouteName,
  kSessionSettingsRouteName,
  kOutlineSettingsRouteName,
  kChapterSettingsRouteName,
  kBattleSettingsRouteName,
  kOutlineEditAiSettingsRouteName,
};
