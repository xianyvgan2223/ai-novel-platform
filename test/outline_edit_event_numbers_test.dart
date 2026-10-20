import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/widget/event_type_tag.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」页卡片上的序号（V4.9.2）：
///
/// 小事件原先显示为「第 N 节」——N 是**本页第几张卡片**，只勾选几章时与正文里
/// 的「○ 小事件N」毫无关系。现在与大纲正文 / 听大纲改名页统一成同一套：
/// - 大事件：全篇只数大事件，从 1 连续（══ 大事件N）；
/// - 小事件：在**所属大事件内部**从 1 重新计数（○ 小事件N）。
///
/// 这些用例直接检查类型标签组件（[EventTypeTag]）上的序号，不依赖文字排版。
void main() {
  const content = '''
══ 大事件1：甲 ══
甲的概要

○ 小事件1：乙
乙的概要

○ 小事件2：丙
丙的概要

══ 大事件2：丁 ══
丁的概要

○ 小事件1：戊
戊的概要
''';

  List<OutlineChapter> chapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 7,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '甲',
      eventSummary: '甲的概要',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 7,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '乙',
      eventSummary: '乙的概要',
    ),
    OutlineChapter(
      id: 3,
      outlineId: 7,
      eventIndex: 3,
      eventType: 'minor',
      eventTitle: '丙',
      eventSummary: '丙的概要',
    ),
    OutlineChapter(
      id: 4,
      outlineId: 7,
      eventIndex: 4,
      eventType: 'major',
      eventTitle: '丁',
      eventSummary: '丁的概要',
    ),
    OutlineChapter(
      id: 5,
      outlineId: 7,
      eventIndex: 5,
      eventType: 'minor',
      eventTitle: '戊',
      eventSummary: '戊的概要',
    ),
  ];

  Future<void> pumpPage(WidgetTester tester) async {
    // 屏够高：五张卡片一次全渲染出来，序号顺序才能整表核对
    tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditPage(
          outline: OutlineRecord(title: '测试小说', content: content),
          chapters: chapters(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 卡片从上到下的类型标签（按渲染位置排序）
  List<EventTypeTag> tagsTopToBottom(WidgetTester tester) {
    final tags = tester.widgetList<EventTypeTag>(find.byType(EventTypeTag));
    final positioned = find.byType(EventTypeTag).evaluate().toList()
      ..sort(
        (a, b) => tester
            .getTopLeft(find.byWidget(a.widget))
            .dy
            .compareTo(tester.getTopLeft(find.byWidget(b.widget)).dy),
      );
    expect(positioned.length, tags.length);
    return [for (final e in positioned) e.widget as EventTypeTag];
  }

  testWidgets('卡片序号 = 正文写法：大事件N / 小事件N（不再显示「第N节」）', (tester) async {
    await pumpPage(tester);

    final tags = tagsTopToBottom(tester);
    expect(tags.length, 5);
    expect(tags.map((t) => t.isMajor).toList(), [
      true,
      false,
      false,
      true,
      false,
    ]);
    // 大事件只数大事件：甲=1、丁=2
    expect(tags.map((t) => t.majorNumber).toList(), [1, null, null, 2, null]);
    // 小事件在每个大事件内部从 1 起：乙=1、丙=2、戊=1
    expect(tags.map((t) => t.minorNumber).toList(), [
      null,
      1,
      2,
      null,
      1,
    ]);

    // 旧的「第 N 节」位置标题已删除
    expect(find.textContaining('第 1 节'), findsNothing);
    expect(find.textContaining('第 2 节'), findsNothing);
    expect(find.textContaining('第 5 节'), findsNothing);
  });

  testWidgets('标签文字就是 大事件N / 小事件N', (tester) async {
    await pumpPage(tester);

    // Text.rich 的纯文本：序号紧跟在类型后面
    expect(find.text('大事件1'), findsOneWidget);
    expect(find.text('大事件2'), findsOneWidget);
    expect(find.text('小事件1'), findsNWidgets(2)); // 乙、戊
    expect(find.text('小事件2'), findsOneWidget); // 丙
    expect(find.text('事件'), findsNothing);
    expect(find.text('章节'), findsNothing);
  });
}
