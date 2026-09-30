import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/widget/outline_ai_chat_sheet.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」AI 面板的**截图工具**：文件名不以 `_test` 结尾，`flutter test`
/// 不会自动跑它（免得 UI 一改测试就红）。改动面板样式后用它生成 PNG 肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/ai_sheet_shot.dart
///
/// 输出在 test/ui_shot/shots/：默认收起 / 展开（开关关）/ 展开（开关开）/
/// 收起后仍开着（收起不影响开关状态）。
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

  testWidgets('AI 面板截图', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctrl = OutlineEditController(OutlineRecord(title: '天下第一尸兄世界'));
    ctrl.init([
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
        eventSummary: '',
      ),
      OutlineChapter(
        id: 3,
        outlineId: 1,
        eventIndex: 3,
        eventType: 'minor',
        eventTitle: '心痕',
        eventSummary: '',
      ),
    ]);
    ctrl.setAiTarget(1);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4D6BFE),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'SimHei',
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFFEDEFF5),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: OutlineAiChatSheet(controller: ctrl),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1) 默认（收起）
    await expectLater(
      find.byType(OutlineAiChatSheet),
      matchesGoldenFile('shots/1_collapsed.png'),
    );

    // 2) 展开选项行（开关仍关闭）
    await tester.tap(find.byTooltip('展开选项'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OutlineAiChatSheet),
      matchesGoldenFile('shots/2_expanded_off.png'),
    );

    // 3) 打开开关
    await tester.tap(find.text('注入同批所选事件'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OutlineAiChatSheet),
      matchesGoldenFile('shots/3_expanded_on.png'),
    );

    // 4) 收起：开关应当仍是开启（图标变主色）
    await tester.tap(find.byTooltip('收起选项'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OutlineAiChatSheet),
      matchesGoldenFile('shots/4_collapsed_still_on.png'),
    );

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
