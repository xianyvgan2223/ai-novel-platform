import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」页新增事件的入口与两步选择：
/// - 新增入口**只剩**卡片标题行右侧的「＋」（挨着「AI 生成」）：
///   顶栏不再有＋，底部栏不再有「添加事件」按钮
/// - 点＋先选「上方 / 下方」，再选「大事件 / 小事件」，两步都选完才多出一条
/// - 中途取消不多出任何卡片
/// - 页面上方的「只改标题与概要，不动已写正文」提示已删除
void main() {
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  List<OutlineChapter> chapters() => [
    ch(1, 'major', '甲'),
    ch(2, 'minor', '乙'),
  ];

  /// 打开编辑页（outline.id 传 null：不落库，只看界面与内存结构）
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

  /// 第 [index] 张卡片标题行右侧的「＋」
  Finder addButton(int index) =>
      find.byTooltip('在它上方 / 下方添加事件').at(index);

  /// 弹窗里的类型选项（「大事件 / 小事件」两行）：卡片上的类型标签也写着同样的字，
  /// 但那是 10 号小字；选项标题是 13 号加粗，按字号认就不会点错
  Finder typeOption(String text) => find.byWidgetPredicate(
    (w) =>
        w is Text &&
        w.data == text &&
        w.style?.fontSize == 13 &&
        w.style?.fontWeight == FontWeight.w600,
  );

  /// 卡片按**屏幕上的先后**排列的事件标题。
  /// 不能直接用 `find.byType(TextField)` 的顺序：每张卡片有标题、概要两个输入框，
  /// 而且 ListView 回收 Element 时那个顺序与视觉顺序并不总是一致，
  /// 所以先按纵坐标排序，再只取标题框（概要框的提示文字是「事件概要」）。
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
        .where(
          (e) =>
              (e.widget as TextField).decoration?.hintText == '事件标题',
        )
        .map((e) => (e.widget as TextField).controller?.text ?? '')
        .toList();
  }

  testWidgets('新增入口只剩卡片上的＋：顶栏与底部栏都没有添加按钮', (tester) async {
    await pumpPage(tester);

    // 每张卡片各一个＋
    expect(find.byTooltip('在它上方 / 下方添加事件'), findsNWidgets(2));
    // 顶栏的「在末尾添加事件」没了
    expect(find.byTooltip('在末尾添加事件'), findsNothing);
    // 底部栏的「添加事件」按钮没了
    expect(find.text('添加事件'), findsNothing);
    // 撤销 / 反撤销 / 保存仍在
    expect(find.byTooltip('撤销'), findsOneWidget);
    expect(find.byTooltip('反撤销'), findsOneWidget);
    expect(find.text('保存'), findsWidgets);
  });

  testWidgets('页面上方的「只改标题与概要」提示已删除，事件数还在', (tester) async {
    await pumpPage(tester);

    expect(find.text('只改标题与概要，不动已写正文'), findsNothing);
    expect(find.textContaining('2 个事件'), findsOneWidget);
    expect(find.text('测试小说'), findsOneWidget);
  });

  testWidgets('点＋先选上方/下方，再选类型；选「下方」加在它后面', (tester) async {
    await pumpPage(tester);

    await tester.tap(addButton(0)); // 第一张卡片「甲」
    await tester.pumpAndSettle();
    expect(find.text('在「甲」上方添加'), findsOneWidget);
    expect(find.text('在「甲」下方添加'), findsOneWidget);

    await tester.tap(find.text('在「甲」下方添加'));
    await tester.pumpAndSettle();
    // 第二步：类型（插在「甲」后面，「甲」是大事件 → 默认大事件）
    expect(typeOption('大事件'), findsOneWidget);
    expect(typeOption('小事件'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);

    await tester.tap(typeOption('小事件'));
    await tester.pumpAndSettle();

    // 多出一条，且落在「甲」后面、「乙」前面
    expect(find.textContaining('3 个事件'), findsOneWidget);
    expect(cardTitles(tester), ['甲', '新事件', '乙']);
  });

  testWidgets('选「上方」加在它前面', (tester) async {
    await pumpPage(tester);

    await tester.tap(addButton(1)); // 第二张卡片「乙」
    await tester.pumpAndSettle();
    await tester.tap(find.text('在「乙」上方添加'));
    await tester.pumpAndSettle();
    await tester.tap(typeOption('大事件'));
    await tester.pumpAndSettle();

    expect(cardTitles(tester), ['甲', '新事件', '乙']);
  });

  testWidgets('两步里任意一步取消都不多出卡片', (tester) async {
    await pumpPage(tester);

    // 第一步取消
    await tester.tap(addButton(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个事件'), findsOneWidget);

    // 第二步取消
    await tester.tap(addButton(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在「甲」下方添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个事件'), findsOneWidget);
  });
}
