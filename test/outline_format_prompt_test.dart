import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_format/service/outline_format_service.dart';

/// 「匹配大纲格式」提示词：不再写任何字数限制
/// （核心概念 / 大事件概述 / 小事件概要原本分别带了 30-50、50-100、30-50 字）。
void main() {
  test('格式化提示词里不再出现字数限制', () {
    final prompt = OutlineFormatPromptTemplate.buildFormatPrompt('原始大纲内容');

    expect(prompt, isNot(contains('30-50')));
    expect(prompt, isNot(contains('50-100')));
    expect(prompt, isNot(contains('字，概括')));
    expect(prompt, isNot(contains('（50-100 字）')));
  });

  test('保留格式结构，但概要不再带字数括号', () {
    final prompt = OutlineFormatPromptTemplate.buildFormatPrompt('原始大纲内容');

    expect(prompt, contains('3. 核心概念简介（概括世界观、主角核心困境、故事最终落点）'));
    expect(prompt, contains('══ 大事件1：标题 ══\n大事件概述\n○ 小事件1：标题\n小事件概要\n'));
    expect(prompt, contains('用户的大纲内容如下'));
  });
}
