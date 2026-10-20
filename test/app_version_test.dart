import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/config/app_version.dart';

/// 设置页最下方的「当前版本 vX.Y.Z」来自 [kAppVersion]，
/// 而真正的发版版本号写在 pubspec.yaml 的 `version:` 里。
/// 两处必须同步：只改一处（常见于发版时漏改常量）时这条用例会先红。
void main() {
  test('App 内展示的版本号与 pubspec.yaml 的 version 一致', () {
    final pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: 'flutter test 应在项目根目录运行（找不到 pubspec.yaml）',
    );
    final content = pubspec.readAsStringSync();
    // 形如 `version: 4.9.4` 或 `version: 4.9.4+12`：取 + 号前的版本号
    final match = RegExp(
      r'^version:\s*([^\s+]+)',
      multiLine: true,
    ).firstMatch(content);
    expect(match, isNotNull, reason: 'pubspec.yaml 里应有 version: 行');
    expect(
      kAppVersion,
      match!.group(1),
      reason: '设置页显示的版本号必须与 pubspec.yaml 一致（发版时两处一起改）',
    );
  });

  test('版本号格式是 x.y.z（纯数字三段）', () {
    expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(kAppVersion), isTrue);
  });
}
