import 'package:flutter_test/flutter_test.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」的撤销 / 反撤销：多章标题与概要整体快照，连续输入合并为一步。
void main() {
  testWidgets('大纲编辑撤销与反撤销', (tester) async {
    final ctrl = OutlineEditController(OutlineRecord(title: 'T'));
    ctrl.init([
      OutlineChapter(
        id: 1,
        outlineId: 0,
        eventIndex: 0,
        eventTitle: 'A',
        eventSummary: 's1',
      ),
      OutlineChapter(
        id: 2,
        outlineId: 0,
        eventIndex: 1,
        eventTitle: 'B',
        eventSummary: 's2',
      ),
    ]);

    // 初始无可撤销 / 反撤销内容
    expect(ctrl.canUndo, isFalse);
    expect(ctrl.canRedo, isFalse);

    // 第 1 章标题改动，防抖结束后并入撤销栈
    ctrl.drafts[0].titleCtrl.text = 'A1';
    expect(ctrl.canUndo, isTrue);
    await tester.pump(const Duration(milliseconds: 700));

    // 第 2 章概要改动，作为独立一步
    ctrl.drafts[1].summaryCtrl.text = 's2x';
    await tester.pump(const Duration(milliseconds: 700));

    // 撤销第 2 章改动
    ctrl.undo();
    expect(ctrl.drafts[0].titleCtrl.text, 'A1');
    expect(ctrl.drafts[1].summaryCtrl.text, 's2');
    expect(ctrl.canRedo, isTrue);

    // 撤销第 1 章改动，回到初始状态
    ctrl.undo();
    expect(ctrl.drafts[0].titleCtrl.text, 'A');
    expect(ctrl.drafts[0].isDirty, isFalse);

    // 反撤销逐步前进
    ctrl.redo();
    expect(ctrl.drafts[0].titleCtrl.text, 'A1');
    ctrl.redo();
    expect(ctrl.drafts[1].summaryCtrl.text, 's2x');

    // 未等待防抖就撤销：先并入当前改动，再回到上一次提交状态
    ctrl.drafts[0].titleCtrl.text = 'A2';
    expect(ctrl.canRedo, isFalse);
    ctrl.undo();
    expect(ctrl.drafts[0].titleCtrl.text, 'A1');
    expect(ctrl.drafts[1].summaryCtrl.text, 's2x');
    expect(ctrl.canRedo, isTrue);

    ctrl.dispose();
  });
}
