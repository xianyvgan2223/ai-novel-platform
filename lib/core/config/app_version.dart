/// ⚠️ 发版规则：只有用户明确要求「发布 / 出新版 / 更新版本号」时才修改
/// kAppVersion / kAppBuildNumber / kAppReleaseId。功能开发、调样式、调试期间
/// 一律不动；日常验证只构建 debug，见根目录 AGENTS.md。
///
/// 当前 App 版本号（设置页最下方展示）。
///
/// 为什么手写一份常量、不用 package_info_plus：
/// 项目依赖里 `file_picker 11` 钉死了 `win32 ^5`，而 `package_info_plus 10`
/// 要求 `win32 ^6`，pub 直接解决不了；版本号本来就在发布流程里手动维护
/// （`pubspec.yaml` 的 `version:` + 开发日志），这里再放一份，
/// 由 `test/app_version_test.dart` 保证两者一致——只改一处时单测会先红。
///
/// 发版时改 `pubspec.yaml` 的 `version:`，同步改这里。
const String kAppVersion = '5.2.4';

/// 构建号（与 pubspec.yaml 的 `+N` 保持一致）。
const String kAppBuildNumber = '10';

/// 发版标识：用于「首次打开新版本时只显示一次更新公告」。
/// 每次发版修改 kAppVersion / kAppBuildNumber 后，这里和
/// currentUpdateAnnouncement.releaseId 要同步更新。
const String kAppReleaseId = '5.2.4+10';
