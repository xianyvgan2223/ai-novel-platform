import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/background/outline_background_notification.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/background/outline_generation_session.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/view/page/outline_generation_page.dart';

/// 一键生成大纲页面：新增「要求提示词」输入框；主题 / 要求提示词都有放大编辑按钮。
void main() {
  testWidgets('页面有要求提示词输入框，主题与要求提示词都能放大编辑', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OutlineGenerationPage()),
    );
    await tester.pump(); // 等待 initState 里的草稿检查（本地文件，无网络）

    // 新增输入框
    expect(
      find.text('要求提示词（如：节奏快、不要后宫、每个大事件都要有爽点）'),
      findsOneWidget,
    );
    // 主题输入框仍在
    expect(find.text('主题（如：废土世界中的 AI 觉醒）'), findsOneWidget);

    // 主题 / 主角 / 世界观 / 要求提示词 各有一个放大编辑按钮
    final expandButtons = find.byTooltip('放大编辑');
    expect(expandButtons, findsNWidgets(4));

    // 主题放大编辑
    await tester.ensureVisible(expandButtons.at(0));
    await tester.tap(expandButtons.at(0));
    await tester.pumpAndSettle();
    expect(find.text('主题'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '废土上的 AI 觉醒');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('废土上的 AI 觉醒'), findsOneWidget);

    // 要求提示词放大编辑
    final requirementButton = find.byTooltip('放大编辑').last;
    await tester.ensureVisible(requirementButton);
    await tester.tap(requirementButton);
    await tester.pumpAndSettle();
    expect(find.text('要求提示词'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '不要后宫，节奏要快');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('不要后宫，节奏要快'), findsOneWidget);
  });

  /// 用户点通知 / 从别的页面重新进来时，会话里可能已经有一份「生成中」的状态：
  /// 页面必须挂回同一个 controller，把主按钮、进度文案、停止 FAB 切到生成中的样子。
  /// 这里只摆状态、不调 generate，避免 widget 测试发起真实网络请求。
  testWidgets('会话已有生成中任务时，页面显示生成中按钮、进度与停止 FAB', (tester) async {
    final session = OutlineGenerationSession.instance;
    final attach = session.acquireForPage(
      debugControllerFactory: () => OutlineController(
        // 明确走「不支持通知」的假桥：widget 测试不碰 Android 通道
        backgroundNotification: OutlineBackgroundNotification(supported: false),
      ),
    );
    final controller = attach.controller;
    controller.debugSetRunStateForTest(
      loading: true,
      title: '测试书',
      currentStep: 1,
      totalSteps: 4,
    );
    // 失败也要清掉进程级会话，避免污染同文件其它测试
    addTearDown(session.resetForTest);

    await tester.pumpWidget(const MaterialApp(home: OutlineGenerationPage()));
    await tester.pump(); // 等 initState 里的草稿检查（本地文件，无网络）

    // 页面挂回的是会话里那个生成中的 controller，而不是新建实例
    expect(controller.loading, isTrue);

    // 主按钮变成不可点的「生成中...」
    final generatingButton = find.widgetWithText(ElevatedButton, '生成中...');
    expect(generatingButton, findsOneWidget);
    expect(tester.widget<ElevatedButton>(generatingButton).onPressed, isNull);

    // 进度文案：currentStep=1 / totalSteps=4 → 2/4
    expect(find.textContaining('2/4'), findsOneWidget);

    // 生成中提供「停止生成」FAB
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('停止生成'), findsOneWidget);

    // 页面卸载：生成中 detach 应保留会话（生成继续），最后显式释放
    await tester.pumpWidget(const SizedBox.shrink());
    expect(session.current, same(controller));
    session.resetForTest();
    await tester.pump();
  });
}
