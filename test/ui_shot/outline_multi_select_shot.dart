import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_chapter_list_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」章节选择页底部操作栏的**截图工具**（多选 / 取消选择）：
///
///     flutter test --update-goldens test/ui_shot/outline_multi_select_shot.dart
///
/// 输出在 test/ui_shot/shots/：6 未勾选 / 7 勾选两章（出现「取消选择」）。
/// 说明：页面正文要读库校正结构，测试环境没有 sqflite，正文区会显示加载失败；
/// 这三张图只用来看底部栏——对齐、字号、按钮是否挤在一起。
void main() {
  setUpAll(() async {
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

  List<OutlineChapter> chapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 1,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '企鹅变异',
      eventSummary: '动物园的企鹅突然变异，主角第一次直面尸潮。',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 1,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '动物园来客',
      eventSummary: '一个自称研究员的人找上门。',
    ),
    OutlineChapter(
      id: 3,
      outlineId: 1,
      eventIndex: 3,
      eventType: 'minor',
      eventTitle: '心痕',
      eventSummary: '主角发现自己身上的伤痕会说话。',
    ),
  ];

  Future<void> pump(WidgetTester tester, Set<int> selected) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey<OutlineEditChapterListPageState>();
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
        home: OutlineEditChapterListPage(
          key: key,
          outline: OutlineRecord(title: '天下第一尸兄世界', content: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 读库失败（测试环境无 sqflite）会让正文区显示错误视图；
    // 这里把章节与勾选摆好，只为了看底部操作栏
    key.currentState!.debugSetSelectedForTest(selected, chapters: chapters());
    await tester.pumpAndSettle();
  }

  testWidgets('底栏截图：未勾选', (tester) async {
    await pump(tester, const {});
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('shots/6_outline_select_none.png'),
    );
  });

  testWidgets('底栏截图：勾选两章', (tester) async {
    await pump(tester, {1, 3});
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('shots/7_outline_select_two.png'),
    );
  });

  testWidgets('底栏截图：全选', (tester) async {
    await pump(tester, {1, 2, 3});
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('shots/8_outline_select_all.png'),
    );
  });
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
