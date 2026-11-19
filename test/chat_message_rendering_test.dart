import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/features/chat/domain/chat_message.dart';
import 'package:deepseekapp/features/chat/presentation/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// 消息气泡现在直接渲染 Markdown；同时助手气泡占满列表可用宽度，
/// 用户气泡仍按内容宽度靠右。
void main() {
  testWidgets('助手消息：Markdown 按富文本渲染，原始标记不显示', (tester) async {
    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content: '# 本周要点\n\n**重点**内容\n\n- 第一项\n- 第二项',
        timestamp: '2026-11-06T20:49:00',
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    final plain = _plainText(tester);
    expect(plain, contains('本周要点'));
    expect(plain, contains('重点内容'));
    expect(plain, contains('第一项'));
    expect(plain, isNot(contains('**')));
    expect(plain, isNot(contains('# ')));
  });

  testWidgets('用户消息同样支持 Markdown', (tester) async {
    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.user,
        content: '**这是我自己的输入**',
        timestamp: '2026-11-06T20:49:00',
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    final plain = _plainText(tester);
    expect(plain, contains('这是我自己的输入'));
    expect(plain, isNot(contains('**')));
  });

  testWidgets('单换行保留为换行，不把两行合并成一行', (tester) async {
    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content: '第一行\n第二行',
        timestamp: '2026-11-06T20:49:00',
      ),
    );

    expect(_plainText(tester), contains('第一行\n第二行'));
  });

  testWidgets('字号 12，粗体保持黑色不加蓝色', (tester) async {
    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content: '这是**重点**内容',
        timestamp: '2026-11-06T20:49:00',
      ),
    );

    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    // 按需求使用黑色粗体：颜色与正文相同，w700 让中文也能看出加粗。
    expect(body.styleSheet?.p?.fontSize, 12);
    expect(body.styleSheet?.strong?.fontWeight, FontWeight.w700);
    expect(
      body.styleSheet?.strong?.color,
      AppPalette.light.bubbleAssistantText,
    );
  });

  testWidgets('表格与代码块在窄屏气泡里不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content:
            '| 名称 | 数量 | 说明 |\n'
            '| --- | --- | --- |\n'
            '| 苹果 | 3 | 红色水果 |\n'
            '| 香蕉 | 5 | 黄色水果 |\n\n'
            '```dart\n'
            'final message = "一整段比较长的代码，用来验证代码块会横向滚动";\n'
            '```',
        timestamp: '2026-11-06T20:49:00',
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('助手气泡占满可用宽度，用户气泡按内容收窄', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.assistant,
        content: '短',
        timestamp: '2026-11-06T20:49:00',
      ),
    );
    final assistantWidth = tester.getSize(find.byType(MarkdownBody)).width;

    await _pumpBubble(
      tester,
      const ChatMessage(
        role: MessageRole.user,
        content: '短',
        timestamp: '2026-11-06T20:49:00',
      ),
    );
    final userWidth = tester.getSize(find.byType(MarkdownBody)).width;

    // 360dp 窗口：列表左右各 12dp + 气泡左右各 10dp → 助手正文约 316dp
    expect(assistantWidth, greaterThan(300));
    expect(assistantWidth, greaterThan(userWidth + 60));
  });
}

Future<void> _pumpBubble(WidgetTester tester, ChatMessage message) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: MessageBubble(message: message),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// MarkdownBody 的每个块是 SelectableText.rich；拼起来检查渲染后的纯文本。
String _plainText(WidgetTester tester) {
  final texts = tester.widgetList<SelectableText>(find.byType(SelectableText));
  return texts.map((t) => t.textSpan?.toPlainText() ?? t.data ?? '').join('\n');
}
