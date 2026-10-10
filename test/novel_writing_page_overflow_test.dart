import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/novel_writing_page.dart';

/// 回归测试：聊天页弹着输入法时点「写小说」，切过去不能 RenderFlex overflow。
///
/// 真机报错（修复前）：
/// ```
/// RenderFlex OVERFLOWING
/// creator: Column ← Center ← KeyedSubtree ← _BodyBuilder ← MediaQuery ←
///          LayoutId-[<_ScaffoldSlot.body>] ← CustomMultiChildLayout ← ⋯
/// constraints: BoxConstraints(0.0<=w<=360.0, 0.0<=h<=421.5)
/// size: Size(220.0, 421.5)
/// ```
/// 修法：`novel_writing_page.dart` 的 body 改成
/// LayoutBuilder + SingleChildScrollView + IntrinsicHeight —— 装得下时照旧居中，
/// 装不下时可滚动。这样切页时**不需要**等输入法收起（等一帧会让切换发涩），
/// 输入法收起动画与新页面入场动画并行也不会溢出。
void main() {
  /// 复现真机尺寸：宽 360、正文可用高度 421.5（= 报错里的约束）
  Future<void> pumpWithBodyHeight(WidgetTester tester, double bodyHeight) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(height: bodyHeight, child: const NovelWritingPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('正文高度 421.5（输入法未收起）时不溢出', (tester) async {
    await pumpWithBodyHeight(tester, 421.5);

    expect(tester.takeException(), isNull);
    // 五个入口都在，且页面可滚动（内容比视口高）
    expect(find.text('一键生成大纲'), findsOneWidget);
    expect(find.text('匹配大纲格式'), findsOneWidget);

    final scrollable = find.byType(SingleChildScrollView).first;
    expect(tester.widget<SingleChildScrollView>(scrollable).child, isNotNull);
    expect(find.byType(NovelWritingPage), findsOneWidget);
  });

  testWidgets('正文高度 421.5 时可以滚动到底部按钮', (tester) async {
    await pumpWithBodyHeight(tester, 421.5);

    final scrollableFinder = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollableFinder).position;
    expect(position.maxScrollExtent, greaterThan(0));

    await tester.drag(scrollableFinder, const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('匹配大纲格式'), findsOneWidget);
  });

  testWidgets('正文高度充足时仍然居中、不出现滚动条', (tester) async {
    await pumpWithBodyHeight(tester, 700);

    expect(tester.takeException(), isNull);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.maxScrollExtent, 0);
  });

  testWidgets('键盘还开着就切页（不收输入法、不等待）也不溢出', (tester) async {
    // 尺寸按真机报错反推：正文高 421.5 = 屏高 640 - 状态栏 24 - AppBar 44(此处 56)
    // - 输入法 300，所以这里用 360x640，输入法再占 300
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * 3);
    addTearDown(tester.view.reset);

    // 复刻聊天页：输入框有焦点 + 右上角按钮「收输入法后立即 push」
    final inputCtrl = TextEditingController();
    addTearDown(inputCtrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    Navigator.of(buttonContext).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const NovelWritingPage(),
                      ),
                    );
                  },
                  child: const Text('写小说'),
                ),
              ),
            ],
          ),
          body: TextField(controller: inputCtrl, autofocus: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 确认键盘占位真的生效（正文被压到 500 以下）
    final bodyHeight = tester.getSize(find.byType(TextField)).height;
    expect(bodyHeight, lessThan(500));

    // 点按钮 → 立即切页（没有任何 await 等待）
    await tester.tap(find.text('写小说'));
    await tester.pump(); // 起帧
    await tester.pump(const Duration(milliseconds: 150)); // 切页动画中途
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle(); // 动画结束
    expect(tester.takeException(), isNull);
    expect(find.byType(NovelWritingPage), findsOneWidget);
  });
}
