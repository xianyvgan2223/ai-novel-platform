# AI 协作规则

## 发版规则（重要）

功能开发、修 bug、调样式、调试期间：

- **不要**修改 `pubspec.yaml` 的 `version` / build number；
- **不要**修改 `lib/core/config/app_version.dart` 的 `kAppVersion` / `kAppBuildNumber` / `kAppReleaseId`；
- **不要**修改 `lib/features/update/data/update_announcement.dart` 的 `releaseId`；
- **不要**执行 `flutter build apk --release`；
- **不要**更新 `web/server/data/app-update/latest.json` 或发布 APK。

日常真机验证只用 debug：

```powershell
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

只有在用户明确说「发布」「出新版」「更新版本号」「打 release」「发 release」时，才允许按顺序做：

1. 修改 `pubspec.yaml` 的 `version`（versionName 和 build number）；
2. 同步 `lib/core/config/app_version.dart` 的 `kAppVersion` / `kAppBuildNumber` / `kAppReleaseId`；
3. 如需公告，同步 `lib/features/update/data/update_announcement.dart` 的 `releaseId`；
4. `flutter build apk --release`；
5. 发布到 `web/server/data/app-update/` 并更新 `latest.json`。

用户说「版本号不变」时，只允许改代码和 debug 验证，禁止动以上发版文件。
