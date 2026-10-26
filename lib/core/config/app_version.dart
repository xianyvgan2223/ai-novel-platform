/// 当前 App 版本号（设置页最下方展示）。
///
/// 为什么手写一份常量、不用 package_info_plus：
/// 项目依赖里 `file_picker 11` 钉死了 `win32 ^5`，而 `package_info_plus 10`
/// 要求 `win32 ^6`，pub 直接解决不了；版本号本来就在发布流程里手动维护
/// （`pubspec.yaml` 的 `version:` + 开发日志），这里再放一份，
/// 由 `test/app_version_test.dart` 保证两者一致——只改一处时单测会先红。
///
/// 发版时改 `pubspec.yaml` 的 `version:`，同步改这里。
const String kAppVersion = '4.11.7';
