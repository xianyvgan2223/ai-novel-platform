import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/chat_prompt.dart';

/// 第二阶段（带搜索结果回答）必须复用第一阶段的消息前缀，否则缓存必然失配。
void main() {
  test('第二阶段消息 = 第一阶段消息原样 + 末尾搜索结果', () {
    final phaseOne = <Map<String, dynamic>>[
      {'role': 'system', 'content': '会话提示'},
      {'role': 'user', 'content': '今天桂林天气如何'},
      {'role': 'assistant', 'content': '……'},
      {
        'role': 'user',
        'content': '明天呢\n\n【运行环境】当前时间：2026年11月17日 15:35（星期一，本地时区）',
      },
    ];

    final phaseTwo = buildSearchAnswerMessages(
      phaseOneMessages: phaseOne,
      searchContext: '【搜索结果】1. 桂林明天多云……',
    );

    // 前缀逐字节一致（长度多一条、前 N 条内容和顺序完全相同）
    expect(phaseTwo.length, phaseOne.length + 1);
    for (var i = 0; i < phaseOne.length; i++) {
      expect(phaseTwo[i], equals(phaseOne[i]));
    }
    // 时间注记原样保留在倒数第一条用户消息里，不能被丢掉或挪位置
    expect(
      phaseTwo[phaseOne.length - 1]['content'],
      contains('【运行环境】当前时间'),
    );
    // 末尾追加的是搜索结果消息
    expect(phaseTwo.last['role'], 'user');
    expect(phaseTwo.last['content'], contains('【搜索结果】'));
  });

  test('复用快照时不会修改第一阶段消息（避免污染下一次构建）', () {
    final phaseOne = <Map<String, dynamic>>[
      {'role': 'user', 'content': '原问题'},
    ];
    final phaseTwo = buildSearchAnswerMessages(
      phaseOneMessages: phaseOne,
      searchContext: '搜索结果',
    );
    expect(phaseOne.length, 1);
    expect(phaseOne.single['content'], '原问题');
    expect(phaseTwo.length, 2);
  });
}
