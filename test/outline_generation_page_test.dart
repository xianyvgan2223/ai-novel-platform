import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
