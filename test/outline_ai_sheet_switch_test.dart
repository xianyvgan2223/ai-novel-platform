import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/widget/outline_ai_chat_sheet.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// AI 面板顶部的「注入同批所选事件」开关：整行可点、默认关闭；
/// 这一行在面板里默认**收起**，收起 / 展开不影响开关状态；
/// 只编辑了一个事件时说明文字要如实提示没有别的事件可注入。
void main() {
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  Future<OutlineEditController> pumpSheet(
    WidgetTester tester,
    List<OutlineChapter> chapters,
  ) async {
    final ctrl = OutlineEditController(OutlineRecord(title: 'T'));
    ctrl.init(chapters);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OutlineAiChatSheet(controller: ctrl)),
      ),
    );
    return ctrl;
  }

  /// 展开选项行（默认收起）
  Future<void> expandOptions(WidgetTester tester) async {
    await tester.tap(find.byTooltip('展开选项'));
    await tester.pumpAndSettle();
  }

  testWidgets('开关默认关闭，点整行可开可关', (tester) async {
    final ctrl = await pumpSheet(tester, [
      ch(1, 'major', 'A'),
      ch(2, 'minor', 'a1'),
    ]);

    await expandOptions(tester);
    expect(find.text('注入同批所选事件'), findsOneWidget);
    expect(ctrl.injectSelectedEvents, isFalse);

    await tester.tap(find.text('注入同批所选事件'));
    await tester.pumpAndSettle();
    expect(ctrl.injectSelectedEvents, isTrue);

    await tester.tap(find.text('注入同批所选事件'));
    await tester.pumpAndSettle();
    expect(ctrl.injectSelectedEvents, isFalse);

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });

  testWidgets('说明文字随本次编辑的事件数变化', (tester) async {
    final single = await pumpSheet(tester, [ch(1, 'major', 'A')]);
    await expandOptions(tester);
    expect(find.textContaining('只编辑了 1 个事件'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    single.dispose();

    final multi = await pumpSheet(tester, [
      ch(1, 'major', 'A'),
      ch(2, 'minor', 'a1'),
      ch(3, 'minor', 'a2'),
    ]);
    await expandOptions(tester);
    expect(find.textContaining('已在「前一/后续事件」里的不重复注入'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    multi.dispose();
  });

  testWidgets('选项行默认收起，收起 / 展开不影响开关状态', (tester) async {
    final ctrl = await pumpSheet(tester, [
      ch(1, 'major', 'A'),
      ch(2, 'minor', 'a1'),
    ]);

    // 默认收起：开关那一行不显示
    expect(find.text('注入同批所选事件'), findsNothing);
    expect(find.byTooltip('展开选项'), findsOneWidget);

    // 展开后打开开关
    await tester.tap(find.byTooltip('展开选项'));
    await tester.pumpAndSettle();
    expect(find.text('注入同批所选事件'), findsOneWidget);
    await tester.tap(find.text('注入同批所选事件'));
    await tester.pumpAndSettle();
    expect(ctrl.injectSelectedEvents, isTrue);

    // 收起：行藏起来，但开关仍是开启
    await tester.tap(find.byTooltip('收起选项'));
    await tester.pumpAndSettle();
    expect(find.text('注入同批所选事件'), findsNothing);
    expect(ctrl.injectSelectedEvents, isTrue);

    // 再展开：开关还是开启，没有被收起动作重置
    await tester.tap(find.byTooltip('展开选项'));
    await tester.pumpAndSettle();
    expect(find.text('注入同批所选事件'), findsOneWidget);
    expect(ctrl.injectSelectedEvents, isTrue);

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
