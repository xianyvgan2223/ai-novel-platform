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

## 验证规则（重要：不要重复测试）

用户明确要求：**不要重复测试，等待时间太长**。同一项检查只跑一次，谁跑谁负责，结果直接写进最终答复 / 验证报告，不要为了「确认最终状态」把相同命令再跑一遍。

- **Lead（主智能体）跑一次**：改动文件的 `flutter analyze` + 相关测试用例 + 必要构建 + 真机验证，跑完即算数；
- **子智能体 / 验证者不做重复项**：不得重跑 Lead 已经跑过的 analyze / test / 构建 / 真机检查；只做**不重复**的工作，例如：
  - 独立代码审查（读 diff、对照规格，不跑命令）；
  - 需要时才新写独立测试或执行 Lead 无法完成的检查（例如新增覆盖、独立真机证据）；
  - 汇总验证报告。
- **产品代码被修改后只补跑受影响项**：改哪个文件就 analyze / test 哪个文件相关的用例，不重跑全量矩阵；
- **构建按端选择**：只跑实际改动的那一端。只改手机端不必跑 `pnpm run build`，只改网页端不必构建 APK；跨端共用逻辑除外；
- **不重复真机验证**：同一操作（如导入一份 txt）只做一次；后续复核用截图 / 日志等已有证据，不重复操作污染用户数据；
- **验证报告引用一次真实输出即可**，不要写「Lead 跑过 + 我又跑了一遍」这种重复记录。

只有以下情况才允许跑第二次：前一次运行失败且已换环境/换代码修复，或用户明确要求重跑。

