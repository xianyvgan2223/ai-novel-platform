import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/novel_writing_page.dart';

/// 「写小说」入口页的**截图工具**：文件名不以 `_test` 结尾，`flutter test`
/// 不会自动跑它。改动入口页布局后用它生成 PNG 肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/novel_writing_shot.dart
///
/// 输出在 test/ui_shot/shots/：
/// 1 正常高度（内容居中，与改前一致）
/// 2 输入法占位后的高度（421.5，内容超高 → 可滚动，不再 RenderFlex overflow）
void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 自带图标字体
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    if (flutterRoot.isNotEmpty) {
      await _loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf',
      );
    }
  });

  testWidgets('写小说入口页截图（正常高度）', (tester) async {
    await _pumpPage(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/4_novel_writing_normal.png'),
    );
  });

  testWidgets('写小说入口页截图（输入法未收起的高度）', (tester) async {
    await _pumpPage(tester, bodyHeight: 421.5);
    // 内容超出视口，滚动到底部让最后一个入口可见
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/5_novel_writing_short.png'),
    );
  });
}

Future<void> _pumpPage(WidgetTester tester, {double? bodyHeight}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final page = const NovelWritingPage();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D6BFE),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'SimHei',
      ),
      // bodyHeight 为空时正常全屏；给值时模拟「输入法占了底部」的正文高度
      home: bodyHeight == null
          ? page
          : Scaffold(body: SizedBox(height: bodyHeight, child: page)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
