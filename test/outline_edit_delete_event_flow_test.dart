import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」页删除事件的界面流程（用户报的 bug：小事件删不掉）：
/// - 点卡片右上角「⋯」→「删除事件」→ 弹确认弹窗（标题点名这一条）→ 确认后卡片消失、
///   事件数与底部「有事件增删未保存」同步变
/// - 点「取消」什么都不变
/// - 已写正文的小事件在弹窗里如实告知
void main() {
  OutlineChapter ch(int id, String type, String title, {String content = ''}) =>
      OutlineChapter(
        id: id,
        outlineId: 1,
        eventIndex: id,
        eventType: type,
        eventTitle: title,
        eventSummary: '$title 的概要',
        content: content,
      );

  List<OutlineChapter> chapters() => [
    ch(1, 'major', '甲'),
    ch(2, 'minor', '乙', content: '乙已写好的正文'),
    ch(3, 'minor', '丙'),
  ];

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditPage(
          outline: OutlineRecord(title: '测试小说', content: ''),
          chapters: chapters(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开第 [index] 张卡片右上角「⋯」菜单并点「删除事件」
  Future<void> openDeleteMenu(WidgetTester tester, int index) async {
    await tester.tap(find.byTooltip('更多操作').at(index));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除事件'));
    await tester.pumpAndSettle();
  }

  /// 卡片按**屏幕上的先后**排列的事件标题（ListView 回收 Element 时
  /// `find.byType(TextField)` 的顺序与视觉顺序不总一致，先按纵坐标排）
  List<String> cardTitles(WidgetTester tester) {
    final fields = find.byType(TextField).evaluate().toList()
      ..sort(
        (a, b) => (a.renderObject as RenderBox)
            .localToGlobal(Offset.zero)
            .dy
            .compareTo(
              (b.renderObject as RenderBox).localToGlobal(Offset.zero).dy,
            ),
      );
    return fields
        .where((e) => (e.widget as TextField).decoration?.hintText == '事件标题')
        .map((e) => (e.widget as TextField).controller?.text ?? '')
        .toList();
  }

  testWidgets('删小事件：确认后卡片消失、事件数少一条', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('3 个事件'), findsOneWidget);

    await openDeleteMenu(tester, 1); // 第二张卡片「乙」
    expect(find.text('删除「乙」？'), findsOneWidget);
    expect(find.textContaining('该事件已写正文'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 个事件'), findsOneWidget);
    expect(cardTitles(tester), ['甲', '丙']);
    expect(find.textContaining('已删除该事件'), findsOneWidget);
    expect(find.textContaining('有事件增删未保存'), findsOneWidget);
  });

  testWidgets('弹窗点取消：卡片一条都不少', (tester) async {
    await pumpPage(tester);

    await openDeleteMenu(tester, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 个事件'), findsOneWidget);
    expect(cardTitles(tester), ['甲', '乙', '丙']);
  });
}
