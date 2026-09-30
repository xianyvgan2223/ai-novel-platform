import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/list_scroll_offset.dart';

/// 「进入编辑页再返回时要停在原来的区域」靠 captureScrollOffset /
/// restoreScrollOffset 这对工具实现（「大纲编辑」的事件选择页与小说卡片网格
/// 都用它，否则返回后的刷新会把列表拆掉、位置清零，界面跳回顶部）。
void main() {
  /// 挂一个 60 行 × 60 像素的可滚动列表，返回它的控制器
  Future<ScrollController> mountList(
    WidgetTester tester, {
    int count = 60,
  }) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: count,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('第 $i 行')),
          ),
        ),
      ),
    );
    return controller;
  }

  Future<void> unmount(WidgetTester tester, ScrollController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  test('列表还没建好时位置按 0 处理', () {
    final controller = ScrollController();
    expect(captureScrollOffset(controller), 0.0);
    controller.dispose();
  });

  testWidgets('列表没被重建：位置原样保留、不跳动', (tester) async {
    final controller = await mountList(tester);
    controller.jumpTo(900);
    await tester.pump();

    final offset = captureScrollOffset(controller);
    expect(offset, 900.0);

    // 刷新完成时列表还在原处：不做任何纠偏
    restoreScrollOffset(controller, offset);
    await tester.pump();
    expect(controller.offset, 900.0);

    await unmount(tester, controller);
  });

  testWidgets('位置被清零后回到原处，越界时钳制到可滚动范围', (tester) async {
    final controller = await mountList(tester);
    controller.jumpTo(900);
    await tester.pump();
    final offset = captureScrollOffset(controller);

    // 模拟列表被重建（例如刷新时切成了整页 loading）：位置归零
    controller.jumpTo(0);
    await tester.pump();
    restoreScrollOffset(controller, offset);
    await tester.pump();
    expect(controller.offset, 900.0);

    // 内容变短：记下的位置越界，停到新的最大可滚动距离
    final maxExtent = controller.position.maxScrollExtent;
    controller.jumpTo(0);
    await tester.pump();
    restoreScrollOffset(controller, maxExtent + 500);
    await tester.pump();
    expect(controller.offset, maxExtent);

    await unmount(tester, controller);
  });
}
