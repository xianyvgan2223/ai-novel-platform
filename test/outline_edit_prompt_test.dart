import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/service/outline_edit_service.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」AI 生成面板的**输出约束**（系统提示词）回归。
///
/// 业务要求：
/// - 概要写成连贯叙述，不要一条一条列出来、衔接自然；
/// - 不再一刀切「禁止场景描写 / 人物对白 / 心理刻画」，而是只有概要本来就有
///   这类内容时才允许出现相应描写，其他时候仍然禁止。
void main() {
  OutlineEditService service() => OutlineEditService();

  String prompt() => service().buildSystemPrompt(
    outline: OutlineRecord(
      title: '测试小说',
      genre: '玄幻',
      theme: '成长',
      protagonist: '顾泽',
      worldview: '九域',
      content: '',
    ),
    eventTitle: '初抵炼狱',
    eventSummary: '顾泽在城郊醒来。',
    isMajor: false,
  );

  test('要求写成连贯叙述：不要逐条列、衔接自然；不再出现「可分段或分点」', () {
    final text = prompt();
    expect(text, contains('不要一条一条列出来，衔接要自然'));
    expect(text, isNot(contains('可分段或分点')));
  });

  test('场景描写 / 对白 / 心理刻画改为「概要本来就有才允许」，其他时候禁止', () {
    final text = prompt();
    expect(text, contains('只写大纲：只有在概要有出现场景描写、人物对白、心理刻画等内容时才能出现相应描写，其他时候禁止'));
    // 旧的一刀切禁令不应再出现
    expect(text, isNot(contains('禁止输出场景描写、人物对白、心理刻画等小说正文内容')));
  });

  test('原有约束仍然保留（标题、纯输出、一致性、篇幅）', () {
    final text = prompt();
    expect(text, contains('用户要求起标题时只输出标题本身'));
    expect(text, contains('不要寒暄、解释，也不要输出 Markdown 代码块标记'));
    expect(text, contains('不改变既有剧情走向、人物设定与伏笔安排'));
    expect(text, contains('篇幅与既有条目相近'));
  });
}
