import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/chat_prompt.dart';

/// 聊天系统提示词组装：
/// - 不再注入「禁止 Markdown」指令（Markdown 由展示层清洗）；
/// - 联网搜索开启时注入当前时间。
void main() {
  test('搜索关闭：只带会话提示词，不注入当前时间', () {
    final prompt = buildChatSystemPrompt(
      sessionPrompt: '你是一个助手',
      searchEnabled: false,
      now: DateTime(2026, 11, 6, 20, 49),
    );
    expect(prompt, '你是一个助手');
    expect(prompt.contains('当前时间'), isFalse);
    expect(prompt.contains('Markdown'), isFalse);
  });

  test('搜索开启：会话提示词后追加当前时间（只加时间，不加行为指令）', () {
    final prompt = buildChatSystemPrompt(
      sessionPrompt: '你是一个助手',
      searchEnabled: true,
      now: DateTime(2026, 11, 6, 20, 49),
    );
    expect(prompt, '你是一个助手\n\n当前时间：2026年11月6日 20:49（星期五，本地时区）');
    // 只注入时间本身，不附加「请以该时间为准」之类的行为指令，避免干扰模型
    expect(prompt.contains('请以该时间为准'), isFalse);
    expect(prompt.contains('时效性'), isFalse);
    // 会话提示词在前，时间追加在后
    expect(prompt.indexOf('你是一个助手'), lessThan(prompt.indexOf('当前时间')));
    // 不再出现「禁止 Markdown」的旧指令
    expect(prompt.contains('禁止'), isFalse);
  });

  test('搜索开启但会话提示词为空：只注入当前时间', () {
    final prompt = buildChatSystemPrompt(
      sessionPrompt: '   ',
      searchEnabled: true,
      now: DateTime(2026, 11, 8, 9, 5),
    );
    expect(prompt, '当前时间：2026年11月8日 09:05（星期日，本地时区）');
    expect(prompt.startsWith('当前时间：'), isTrue);
  });

  test('搜索关闭且会话提示词为空：返回空串（调用方跳过 system 消息）', () {
    expect(buildChatSystemPrompt(sessionPrompt: '', searchEnabled: false), '');
  });

  test('当前时间补零与星期覆盖：周一 / 周日', () {
    expect(buildCurrentTimeHint(DateTime(2026, 11, 9, 0, 0)), contains('星期一'));
    expect(
      buildCurrentTimeHint(DateTime(2026, 11, 6, 7, 8)),
      contains('07:08'),
    );
    expect(buildCurrentTimeHint(DateTime(2026, 11, 8, 9, 5)), contains('星期日'));
  });
}
