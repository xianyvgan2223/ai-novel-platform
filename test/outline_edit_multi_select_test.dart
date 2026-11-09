import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_chapter_list_page.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」事件选择页：**平时没有复选框，长按卡片进入多选**；
/// 多选后才出现复选框与底部操作栏（取消选择 / 全选 / 编辑所选）。
///
/// 这一页打开时会读库校正结构，而测试环境没有 sqflite
/// （`databaseFactory not initialized`），失败被页面收进错误视图——因此本文件
/// 用 State 上的测试钩子 `debugSetSelectedForTest` 摆出章节与勾选状态
/// （该钩子会清掉读库错误，卡片才会渲染，长按行为才能验证）。
void main() {
  List<OutlineChapter> chapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 1,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '甲',
      eventSummary: '甲的概要',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 1,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '乙',
      eventSummary: '乙的概要',
    ),
    OutlineChapter(
      id: 3,
      outlineId: 1,
      eventIndex: 3,
      eventType: 'minor',
      eventTitle: '丙',
      eventSummary: '丙的概要',
    ),
  ];

  /// 挂上页面并返回它的 State（用于摆章节 / 勾选状态）。
  ///
  /// 章节页是**从上一页 push 进来的**（不是根路由）：「没勾选时返回真的退出」这条
  /// 用例需要有东西可弹，根路由下 pop 会直接把整棵树弹空、断言不出来。
  Future<OutlineEditChapterListPageState> pumpPage(WidgetTester tester) async {
    final key = GlobalKey<OutlineEditChapterListPageState>();
    OutlineEditChapterListPage page() => OutlineEditChapterListPage(
      key: key,
      outline: OutlineRecord(title: '测试小说', content: ''),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => page())),
              child: const Text('打开章节页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开章节页'));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('平时不显示复选框，也没有底部多选栏', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest(const {}, chapters: chapters());
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('已选 0 个事件'), findsNothing);
    expect(find.text('全选'), findsNothing);
    // 卡片本身可见（章节列表渲染出来了）
    expect(find.text('甲'), findsOneWidget);
    // 列表带常显可拖动滚动条（事件多时可快速下滑；贴右边缘显示）
    final bar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
    expect(bar.thumbVisibility, isTrue);
    expect(bar.interactive, isTrue);
    expect(bar.crossAxisMargin, 0);
  });

  testWidgets('长按卡片进入多选：出现复选框与底部栏，再点卡片可加选', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest(const {}, chapters: chapters());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('甲'));
    await tester.pumpAndSettle();

    expect(state.debugSelectedForTest, {1});
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.text('已选 1 个事件'), findsOneWidget);
    expect(find.text('编辑该事件'), findsOneWidget);

    // 多选模式下点另一张卡片 = 加选
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(state.debugSelectedForTest, {1, 2});
    expect(find.text('已选 2 个事件'), findsOneWidget);
    expect(find.text('编辑所选（2）'), findsOneWidget);
  });

  testWidgets('平时点卡片直接进入编辑页（不进入多选）', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest(const {}, chapters: chapters());
    await tester.pumpAndSettle();

    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();

    expect(find.byType(OutlineEditPage), findsOneWidget);
    // 没有进入多选：卡片页的底部多选栏不应出现
    expect(find.text('已选 1 个事件'), findsNothing);
  });

  testWidgets('「取消选择」清空勾选并退出多选，复选框消失', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest(const {}, chapters: chapters());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(find.text('编辑所选（2）'), findsOneWidget);

    await tester.tap(find.text('取消选择'));
    await tester.pumpAndSettle();

    expect(state.debugSelectedForTest, isEmpty);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('编辑所选（2）'), findsNothing);
    // 页面还在、没有退出
    expect(find.byType(OutlineEditChapterListPage), findsOneWidget);
  });

  testWidgets('「全选」只做全选：全选后自己置灰，清空交给「取消选择」', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest({1}, chapters: chapters());
    await tester.pumpAndSettle();

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 3 个事件'), findsOneWidget);
    expect(find.text('取消全选'), findsNothing);
    final allBtn = tester.widget<TextButton>(
      find.ancestor(of: find.text('全选'), matching: find.byType(TextButton)),
    );
    expect(allBtn.onPressed, isNull);

    await tester.tap(find.text('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 个事件'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('返回键：多选时先取消多选，不退出页面', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest({1, 2}, chapters: chapters());
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个事件'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(state.debugSelectedForTest, isEmpty);
    expect(find.byType(OutlineEditChapterListPage), findsOneWidget);
    expect(find.text('已选 2 个事件'), findsNothing);
  });

  testWidgets('返回手势：多选时拦下并取消多选，不退出页面', (tester) async {
    final state = await pumpPage(tester);
    state.debugSetSelectedForTest({1, 2}, chapters: chapters());
    await tester.pumpAndSettle();

    // 模拟系统返回（PopScope）：多选时 canPop=false → 页面不弹出
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(state.debugSelectedForTest, isEmpty);
    expect(find.byType(OutlineEditChapterListPage), findsOneWidget);

    // 勾选清空后再返回，才真的退出这一页
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OutlineEditChapterListPage), findsNothing);
  });

  /// 真机（KOZ-AL00，720×1520 @2.0 → 逻辑宽 360dp）上底部栏溢出 17px：
  /// 「已选 N 个事件 + 取消选择 + 全选 + 带图标的大按钮」按原尺寸放不下，
  /// 主按钮右边就是那条黄黑警示条。这里按同一尺寸复现，把宽度钉住。
  testWidgets('360dp 宽、勾选两个事件时底部栏不溢出', (tester) async {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    // 系统字体放大是另一条溢出路径，这里按默认比例 1.0
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final key = GlobalKey<OutlineEditChapterListPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditChapterListPage(
          key: key,
          outline: OutlineRecord(title: '天下第一尸兄世界', content: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.debugSetSelectedForTest({1, 2}, chapters: chapters());
    await tester.pumpAndSettle();

    // 有溢出时 RenderFlex 会把异常抛到测试里
    expect(tester.takeException(), isNull);

    // 底部栏里的每个控件都落在屏幕宽度内
    final rowRect = tester.getRect(find.byType(Row).last);
    for (final finder in [
      find.text('已选 2 个事件'),
      find.text('取消选择'),
      find.text('全选'),
      find.text('编辑所选（2）'),
    ]) {
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(
        rect.right,
        lessThanOrEqualTo(rowRect.right + 0.5),
        reason: '「${tester.widget<Text>(finder).data}」越过了底部栏右边界',
      );
      expect(rect.width, greaterThan(0));
    }

    // 逐个量出来的总宽约 330dp（图标与左右留白都算上），360dp 屏留约 30dp 余量。
    expect(rowRect.width, lessThanOrEqualTo(336.0));
  });

  /// 320dp（窄屏 / 分屏）同样不能溢出。
  testWidgets('320dp 宽时底部栏也不溢出', (tester) async {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final key = GlobalKey<OutlineEditChapterListPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditChapterListPage(
          key: key,
          outline: OutlineRecord(title: '天下第一尸兄世界', content: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.debugSetSelectedForTest({1, 2}, chapters: chapters());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final rowRect = tester.getRect(find.byType(Row).last);
    expect(rowRect.width, lessThanOrEqualTo(320.0 - 24.0 + 0.5));
    expect(find.text('编辑所选（2）'), findsOneWidget);
  });
}
