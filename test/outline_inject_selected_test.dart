import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/service/outline_edit_service.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「注入同批所选事件」开关：打开后把本次一起勾选、正在编辑的其他事件也交给 AI；
/// 当前事件、所属大事件、前 / 后续各 2 条已经进提示词，不再重复注入。
void main() {
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  // 全篇：大事件 A(id 1) + 小事件 a1..a6(id 2..7) + 大事件 B(id 8)
  final all = <OutlineChapter>[
    ch(1, 'major', 'A'),
    for (var i = 1; i <= 6; i++) ch(1 + i, 'minor', 'a$i'),
    ch(8, 'major', 'B'),
  ];

  /// [selectedIds] 为选事件页勾选的章节，[aiTarget] 为点了「AI 生成」的那张卡片
  OutlineEditController build(List<int> selectedIds, int aiTarget) {
    final ctrl = OutlineEditController(OutlineRecord(title: 'T'));
    ctrl.allChapters = all; // 相当于已从库里读出全篇章节
    ctrl.init([
      for (final c in all)
        if (selectedIds.contains(c.id)) c,
    ]);
    ctrl.setAiTarget(aiTarget);
    return ctrl;
  }

  test('开关默认关闭，关闭时不注入任何东西（行为与改动前一致）', () {
    final ctrl = build([1, 2, 3, 6, 7], 1);
    expect(ctrl.injectSelectedEvents, isFalse);
    expect(ctrl.aiSelectedEventsText, '');
    ctrl.dispose();
  });

  test('打开后注入同批所选事件；前后事件与所属大事件不重复注入', () {
    // 目标 = a1：前一条 = A(id1)、后两条 = a2(id3)、a3(id4)、所属大事件 = A(id1)
    // 同批勾选 A、a1、a2、a5、a6 → 只有 a5、a6 需要额外注入
    final ctrl = build([1, 2, 3, 6, 7], 1);
    ctrl.setInjectSelectedEvents(true);

    final text = ctrl.aiSelectedEventsText;
    expect(text, contains('a5'));
    expect(text, contains('a6'));
    // a2 已经作为【后续事件】注入、A 已经作为【所属大事件】注入 → 不重复
    expect(text.contains('a2'), isFalse);
    expect(text.contains('【大事件】'), isFalse);
    ctrl.dispose();
  });

  test('只勾选了当前这一章时没有可额外注入的内容', () {
    final ctrl = build([2], 0);
    ctrl.setInjectSelectedEvents(true);
    expect(ctrl.aiSelectedEventsText, '');
    ctrl.dispose();
  });

  test('同批所选过多时截断，并写明省略了多少条', () {
    final many = <OutlineChapter>[
      ch(1, 'major', 'A'),
      for (var i = 1; i <= 40; i++) ch(1 + i, 'minor', 'a$i'),
    ];
    final ctrl = OutlineEditController(OutlineRecord(title: 'T'));
    ctrl.allChapters = many;
    ctrl.init(many); // 全选
    ctrl.setAiTarget(1); // 目标 a1
    ctrl.setInjectSelectedEvents(true);

    final text = ctrl.aiSelectedEventsText;
    // 跳过的 4 条：A(所属大事件)、a1(当前)、a2 / a3(后续) → 41 - 4 = 37 条，
    // 上限 30 条，其余 7 条省略
    expect(text, contains('其余 7 条未注入'));
    expect(text.split('\n').length, 31); // 30 条 + 1 行省略说明
    ctrl.dispose();
  });

  test('提示词：注入时多出【同批所选事件】栏目，空串时完全不出现', () {
    final service = OutlineEditService();
    final outline = OutlineRecord(title: 'T');

    final without = service.buildSystemPrompt(
      outline: outline,
      eventTitle: 'a1',
      eventSummary: 's',
      isMajor: false,
    );
    expect(without.contains('【同批所选事件】'), isFalse);

    final withInjection = service.buildSystemPrompt(
      outline: outline,
      eventTitle: 'a1',
      eventSummary: 's',
      isMajor: false,
      parentMajor: 'A：A 的概要',
      selectedEvents: '【章节】a5：a5 的概要',
      prevEvents: '【章节】a2：a2 的概要',
    );
    expect(withInjection, contains('【同批所选事件】'));
    expect(withInjection, contains('【章节】a5：a5 的概要'));
    // 栏目顺序：所属大事件 → 同批所选事件 → 前一事件
    final parentAt = withInjection.indexOf('【所属大事件】');
    final selectedAt = withInjection.indexOf('【同批所选事件】');
    final prevAt = withInjection.indexOf('【前一事件】');
    expect(parentAt, greaterThan(-1));
    expect(selectedAt, greaterThan(parentAt));
    expect(prevAt, greaterThan(selectedAt));
  });
}
