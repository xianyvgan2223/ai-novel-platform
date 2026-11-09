import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」页的两处版面调整：
/// - 每张卡片**右上角横排三个点「⋯」**，添加 / 删除 / AI 生成收进展开菜单，
///   平时不再显示三个按钮把标题行挤窄；
/// - 列表右侧是**常显 + 可拖动**的滚动条（事件多时可按住快速下滑）。
void main() {
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    List<OutlineChapter>? list,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditPage(
          outline: OutlineRecord(title: '测试小说', content: ''),
          chapters: list ?? [ch(1, 'major', '甲'), ch(2, 'minor', '乙')],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('卡片右上角是横排三个点，三个操作在展开菜单里', (tester) async {
    await pumpPage(tester);

    // 每张卡片一个「⋯」（横向三个点），不再有独立的添加 / 删除 / AI 按钮
    expect(find.byIcon(Icons.more_horiz), findsNWidgets(2));
    expect(find.byTooltip('在它上方 / 下方添加事件'), findsNothing);
    expect(find.byTooltip('删除该事件'), findsNothing);
    expect(find.text('AI 生成'), findsNothing);
    expect(find.text('添加一个大事件'), findsNothing);

    // 展开菜单：三个操作按 添加 / 删除 / AI 生成 排列
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    expect(find.text('添加事件'), findsOneWidget);
    expect(find.text('删除事件'), findsOneWidget);
    expect(find.text('AI 生成'), findsOneWidget);

    // 点空白关掉菜单后页面仍在
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('保存'), findsWidgets);
  });

  testWidgets('列表带常显可拖动的滚动条（贴右边缘显示）', (tester) async {
    await pumpPage(tester);

    final scrollbars = find.byType(RawScrollbar);
    expect(scrollbars, findsOneWidget);
    final bar = tester.widget<RawScrollbar>(scrollbars);
    expect(bar.thumbVisibility, isTrue);
    expect(bar.interactive, isTrue);
    expect(bar.controller, isNotNull);
    // 贴边显示（不额外缩进），视觉上就是系统滚动条的位置
    expect(bar.crossAxisMargin, 0);
  });

  testWidgets('没有可编辑事件时只提示，没有菜单可点', (tester) async {
    await pumpPage(tester, list: const <OutlineChapter>[]);

    expect(find.text('没有可编辑的事件'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.text('添加一个大事件'), findsNothing);
    // 没有列表时也不会出现滚动条
    expect(find.byType(Scrollbar), findsNothing);
  });
}
