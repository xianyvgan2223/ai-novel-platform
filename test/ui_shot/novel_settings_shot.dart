import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/widgets/settings_kit.dart';
import 'package:deepseekapp/features/novel_writing/chapter_writing/view/page/outline_setting_page.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/view/page/outline_setting_page.dart';

/// 「写小说」两个设置页（大纲生成设置 / 章节写作设置）的**截图工具**：
/// 文件名不以 `_test` 结尾，`flutter test` 不会自动跑它。改动这两个页面的
/// 视觉层后用下面命令出图，再逐张肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/novel_settings_shot.dart
///
/// 设备真身是 Honor KOZ-AL00：720×1600 px @320dpi = 360×800 dp，系统字号
/// 实测 1.15 倍。1.0 倍黄金图会遮蔽真机截断问题，所以每页都按 360dp 出
/// 1.0 与 1.15 两张全页图；大纲页再加一张 320dp 窄屏，验证长标签自动堆叠。
///
/// 输出在 test/ui_shot/shots/：
///   32 大纲生成设置·360dp 全页·1.0
///   33 大纲生成设置·360dp 全页·1.15
///   34 章节写作设置·360dp 全页·1.0
///   35 章节写作设置·360dp 全页·1.15
///   39 大纲生成设置·320dp 全页·1.0
void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 图标字体
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    // SimHei 缺部分西文标点字形，Arial 作为字体 fallback（与主设置页黄金图一致）
    await _loadFont('Arial', r'C:\Windows\Fonts\arial.ttf');
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    if (flutterRoot.isNotEmpty) {
      await _loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf',
      );
    }
  });

  testWidgets('32 大纲生成设置·360dp 全页·1.0', (tester) async {
    await _pumpSettingPage(tester, page: const OutlineSettingPage());
    await _expectGolden(tester, '32_novel_outline_setting_full.png');
  });

  testWidgets('33 大纲生成设置·360dp 全页·1.15', (tester) async {
    await _pumpSettingPage(
      tester,
      page: const OutlineSettingPage(),
      textScale: 1.15,
    );
    await _expectGolden(tester, '33_novel_outline_setting_full_font115.png');
  });

  testWidgets('34 章节写作设置·360dp 全页·1.0', (tester) async {
    await _pumpSettingPage(tester, page: const ChapterSettingPage());
    await _expectGolden(tester, '34_novel_chapter_setting_full.png');
  });

  testWidgets('35 章节写作设置·360dp 全页·1.15', (tester) async {
    await _pumpSettingPage(
      tester,
      page: const ChapterSettingPage(),
      textScale: 1.15,
    );
    await _expectGolden(tester, '35_novel_chapter_setting_full_font115.png');
  });

  testWidgets('39 大纲生成设置·320dp 全页·1.0', (tester) async {
    await _pumpSettingPage(
      tester,
      page: const OutlineSettingPage(),
      width: 320,
    );
    await _expectGolden(tester, '39_novel_outline_setting_full_320.png');
  });
}

Future<void> _expectGolden(WidgetTester tester, String fileName) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('shots/$fileName'),
  );
}

/// 渲染设置页并固定视口。
///
/// 全页图用「高视口渲染 → 量内容底部 → 收紧视口」的方式：先给一个足够高的
/// 视口（3600dp，一次布局完所有区块），量出最后一张卡片底部，再把视口收到
/// 「卡片底部 + 40dp 列表底部留白」，避免长图末尾拖一大块空白。
Future<void> _pumpSettingPage(
  WidgetTester tester, {
  required Widget page,
  double width = 360,
  double dpr = 2,
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(width * dpr, _kMeasureViewportHeight * dpr);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
  }
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: _cjkTheme(),
      // 截图不要 DEBUG 角标：它会盖住 AppBar 右上角的「保存」按钮
      debugShowCheckedModeBanner: false,
      home: page,
    ),
  );
  await tester.pumpAndSettle();

  // 页面 initState 里读库：widget test 没有 sqflite 插件，异常已被页面的
  // try/catch 吞掉并落回默认值；这里再兜底清一次残留异常，保证截图不中断。
  tester.takeException();

  final bottom = tester.getBottomRight(find.byType(SettingsCard).last).dy;
  final height = ((bottom + _kListBottomPadding) * dpr).ceilToDouble() / dpr;
  tester.view.physicalSize = Size(width * dpr, height * dpr);
  await tester.pumpAndSettle();
}

/// 量全页时的初始视口高度：足够装下两个页面的所有区块（实际内容约 1100dp）。
const double _kMeasureViewportHeight = 3600;

/// 页面 ListView 的底部留白（与页面里 `40 + safeArea` 的 40 对齐；测试环境
/// 没有手势条，safeArea 为 0）。
const double _kListBottomPadding = 40;

/// 截图用主题：test 环境默认字体（FlutterTest）画不出字形，会渲染成一排空心方框。
/// ThemeData(fontFamily:) 只覆盖一部分文本样式，输入框/下拉框取的是 textTheme 里的
/// 具名样式，所以这里再 apply 一遍，保证整页都能看清。
/// SimHei 缺部分西文标点，用 Arial 兜底（见 setUpAll）。
ThemeData _cjkTheme() {
  const fallback = <String>['Arial'];
  final base = ThemeData(fontFamily: 'SimHei', fontFamilyFallback: fallback);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'SimHei',
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'SimHei',
      fontFamilyFallback: fallback,
    ),
  );
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
