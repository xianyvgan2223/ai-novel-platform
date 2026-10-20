import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/controller/outline_listen_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/tts_engine_fake.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/view/page/outline_listen_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「听大纲改名」页的**截图工具**：文件名不以 `_test` 结尾，`flutter test`
/// 不会自动跑它。改动播控条 / 卡片样式后用它生成 PNG 肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/outline_listen_shot.dart
///
/// 输出在 test/ui_shot/shots/：
/// 1 展开态（播控条两行 + 一个事件一张卡片）
/// 2 收起态（一条窄条 + 单个「展开」按钮）
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

  testWidgets('听大纲改名页截图（展开态）', (tester) async {
    await _pumpPage(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/9_outline_listen_expanded.png'),
    );
  });

  testWidgets('听大纲改名页截图（收起态）', (tester) async {
    await _pumpPage(tester, collapsed: true);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/10_outline_listen_collapsed.png'),
    );
  });
}

Future<void> _pumpPage(WidgetTester tester, {bool collapsed = false}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  OutlineChapter ch(int index, String type, String title, String summary) =>
      OutlineChapter(
        outlineId: 0,
        eventIndex: index,
        eventType: type,
        eventTitle: title,
        eventSummary: summary,
      );

  final ctrl = OutlineListenController(
    OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
    engine: FakeTtsEngine(),
  );
  // 两张卡片的序号口径要看得出结论：大事件只数大事件（第二个大事件显示「大事件2」），
  // 小事件在每个大事件内部从 1 重新计数（大事件2 名下的第一个小事件显示「小事件1」）
  ctrl.init([
    ch(1, 'major', '初入江湖', '李云飞在青阳城醒来，发现自己失去了记忆。\n他遇到了师父玄机子，得知自己是青云宗弟子。'),
    ch(2, 'minor', '拜师', '李云飞拜入青云宗，成了玄机子的记名弟子。'),
    ch(3, 'minor', '下山', '他第一次下山，路过青阳城时遇见了旧识。'),
    ch(4, 'major', '公园兔潮', '城中惊现变异兔群，李云飞第一次直面尸兄潮。'),
    ch(5, 'minor', '初战', '他凭一根铁棍挡住了兔潮的第一波冲击。'),
  ], reload: false);
  if (collapsed) ctrl.setPlayerCollapsed(true);
  // 控制器交给页面接管：页面 dispose 时会一起释放
  addTearDown(() => tester.pumpWidget(const SizedBox()));

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
      home: OutlineListenPage(
        outline: ctrl.outline,
        chapters: const [],
        controller: ctrl,
      ),
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
