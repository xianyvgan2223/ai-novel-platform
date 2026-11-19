import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/chat_prompt.dart';

/// 聊天提示词组装：
/// - 系统提示词 = 稳定基础提示 + 会话自定义提示，绝不能带时间；
/// - 时间按每条用户消息自己的发送时间追加，重建历史时逐字节一致。
void main() {
  test('系统提示词 = 稳定基础提示 + 会话自定义提示，不注入时间', () {
    final prompt = buildChatSystemPrompt(sessionPrompt: '你是一个助手');
    expect(prompt, contains(kChatBaseSystemPrompt));
    expect(prompt, endsWith('你是一个助手'));
    expect(prompt.contains('当前时间'), isFalse);
    expect(prompt.contains('Markdown'), isFalse);
  });

  test('会话提示词为空时仍返回稳定基础提示（保证跨会话可缓存前缀）', () {
    expect(buildChatSystemPrompt(sessionPrompt: '   '), kChatBaseSystemPrompt);
  });

  test('运行环境注记按消息时间稳定生成，同一时间重建结果完全一致', () {
    final at = DateTime(2026, 11, 6, 20, 49);
    final first = runtimeHintedContent('第一问', at);
    final rebuilt = runtimeHintedContent('第一问', at);
    expect(rebuilt, first);
    expect(first, startsWith('第一问\n\n'));
    expect(first, contains('当前时间：2026年11月6日 20:49'));
    expect(first, contains('星期五'));
  });

  test('不同消息使用各自时间，历史重建不会引入当前时间', () {
    final a = runtimeHintedContent('第一问', DateTime(2026, 11, 6, 20, 49));
    final b = runtimeHintedContent('第二问', DateTime(2026, 11, 7, 8, 5));
    expect(a, contains('11月6日 20:49'));
    expect(b, contains('11月7日 08:05'));
    expect(b, isNot(contains('11月6日')));
  });

  test('时间补零与星期覆盖：周一 / 周日', () {
    expect(buildCurrentTimeHint(DateTime(2026, 11, 9, 0, 0)), contains('星期一'));
    expect(
      buildCurrentTimeHint(DateTime(2026, 11, 6, 7, 8)),
      contains('07:08'),
    );
    expect(buildCurrentTimeHint(DateTime(2026, 11, 8, 9, 5)), contains('星期日'));
  });
}
