import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/domain/chat_message.dart';
import 'package:deepseekapp/features/chat/presentation/widgets/message_bubble.dart';

/// 消息气泡的展示层清洗：助手回复里的 Markdown 符号不直接显示；
/// 用户自己发的消息保持原样（用户输入的内容不动）。
void main() {
  Future<String> renderText(WidgetTester tester, ChatMessage message) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubble(message: message)),
      ),
    );
    await tester.pumpAndSettle();
    final text = find.byType(SelectableText);
    expect(text, findsOneWidget);
    return tester.widget<SelectableText>(text).data ?? '';
  }

  testWidgets('助手消息：标题 / 粗体 / 列表的 Markdown 标记不显示', (tester) async {
    final text = await renderText(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content: '# 本周要点\n\n**重点**内容\n\n- 第一项\n- 第二项',
        timestamp: '2026-11-06T20:49:00',
      ),
    );
    expect(text, '本周要点\n\n重点内容\n\n• 第一项\n• 第二项');
    expect(text.contains('**'), isFalse);
    expect(text.contains('# '), isFalse);
  });

  testWidgets('用户消息：原样显示，不被清洗', (tester) async {
    final text = await renderText(
      tester,
      const ChatMessage(
        role: MessageRole.user,
        content: '**这是我自己的输入**',
        timestamp: '2026-11-06T20:49:00',
      ),
    );
    expect(text, '**这是我自己的输入**');
  });
}
