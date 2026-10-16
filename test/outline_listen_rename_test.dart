import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/service/outline_rename.dart';

/// 「一键改名」的核心：在大纲正文里定位 + 替换。
///
/// 这些用例盯的都是**会改坏数据**的地方：改错行、丢格式、把下一行事件标题
/// 当成概要吃掉、连锁改名（甲→乙 之后 乙→丙 把刚改出来的乙又改掉）。
void main() {
  /// 一份带各种真实写法的大纲：`══` 包裹 / 裸标题 / markdown 前缀 /
  /// 多行概要 / 幕标题 / 事件之外的正文
  const sample = '''
这里是事件之外的说明文字：李云飞与青阳城的设定。

══ 第一幕：开端 ══

══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来，发现自己失去了记忆。
  他遇到了师父玄机子。

○ 小事件1：拜师
  ## 李云飞拜入青云宗。
  师父玄机子让他记住门规。

○ 小事件2：下山
  **李云飞**第一次下山，路过青阳城。
''';

  group('findRenameHits 定位', () {
    test('标题与概要都命中，并说清是哪个事件的哪一处', () {
      final result = findRenameHits(sample, '李云飞');

      // 大事件1 概要 1 处；小事件2（全篇第 2 个事件）概要 1 处；
      // 小事件3 概要 1 处
      expect(result.totalCount, 3);
      expect(result.eventCount, 3);
      expect(
        result.hits.map((h) => h.where).toSet(),
        {'大事件1 · 概要', '小事件2 · 概要', '小事件3 · 概要'},
      );
      // 事件之外的说明文字不算（它不属于任何事件，改了也说不清改在哪儿）
      expect(
        result.hits.any((h) => h.context.contains('设定')),
        isFalse,
        reason: '事件之外的正文不该被改名命中',
      );
    });

    test('标题里的命中单独标出来', () {
      const text = '''
══ 大事件1：李云飞传 ══
  概要里也有李云飞。
''';
      final result = findRenameHits(text, '李云飞');
      expect(result.hits.length, 2);
      expect(result.hits[0].inTitle, isTrue);
      expect(result.hits[0].where, '大事件1 · 标题');
      expect(result.hits[1].inTitle, isFalse);
      expect(result.hits[1].where, '大事件1 · 概要');
    });

    test('不改装饰行与幕标题：命中只落在事件标题与概要区', () {
      final result = findRenameHits(sample, '开端');
      expect(result.isEmpty, isTrue, reason: '幕标题不属于任何事件，不参与改名');
    });

    test('大小写敏感：英文名区分大小写', () {
      const text = '''
○ 小事件1：Alice 登场
  alice 与 ALICE 都在这一行。
''';
      expect(findRenameHits(text, 'Alice').totalCount, 1);
      expect(findRenameHits(text, 'alice').totalCount, 1);
    });

    test('空词 / 找不到时不产生命中', () {
      expect(findRenameHits(sample, '  ').isEmpty, isTrue);
      expect(findRenameHits(sample, '不存在的名字').isEmpty, isTrue);
    });
  });

  group('替换', () {
    test('标题与概要一起换，且只换命中位置', () {
      const text = '''
══ 大事件1：李云飞传 ══
  李云飞在青阳城醒来。
''';
      final result = findRenameHits(text, '李云飞');
      final next = replaceOccurrences(
        text,
        [for (final h in result.hits) ...h.occurrences],
        '顾长风',
      );
      expect(next, contains('══ 大事件1：顾长风传 ══'));
      expect(next, contains('  顾长风在青阳城醒来。'));
      // 别的名字没被牵连
      expect(next, contains('青阳城'));
    });

    test('保留装饰、缩进与 markdown 前缀（不做重新格式化）', () {
      const text = '''
○ 小事件1：拜师
  ## 李云飞拜入青云宗。
''';
      final next = renameInOutlineText(text, {'李云飞': '顾长风'});
      expect(next, contains('○ 小事件1：拜师'));
      expect(next, contains('  ## 顾长风拜入青云宗。'));
      // 行数不变：没多出空行也没少行
      expect(next.split('\n').length, text.split('\n').length);
    });

    test('不会把下一行事件标题当成概要吃掉', () {
      const text = '''
══ 大事件1：李云飞传 ══
  概要一行。

○ 小事件1：拜师
  第二段概要。
''';
      final next = renameInOutlineText(text, {'李云飞': '顾长风'});
      expect(next, contains('══ 大事件1：顾长风传 ══'));
      expect(next, contains('○ 小事件1：拜师'));
      expect(next, contains('  第二段概要。'));
    });

    test('嵌套名字一起换：李云 会命中 李云飞（连名带姓一起改）', () {
      const text = '''
○ 小事件1：李云飞登场
  李云飞与李云是同一个人吗？
''';
      final next = renameInOutlineText(text, {'李云': '顾长'});
      // 这正是「不做全词匹配」的用意：改名要连名带姓一起换；
      // 面板上会显示实际替换掉的文字与上下文，让用户自己确认
      expect(next, contains('顾长飞登场'));
      expect(next, contains('顾长飞与顾长是'));
    });

    test('连锁改名被阻断：甲→乙 之后 乙→丙 不会把刚改出来的乙再改掉', () {
      const text = '''
○ 小事件1：甲出场
  甲与乙都在场。
''';
      // 甲→乙、乙→丙：若不做保护，第二轮的「乙」会把第一轮写进去的乙也改成丙
      final next = renameInOutlineText(text, {'甲': '乙', '乙': '丙'});
      expect(next, contains('乙出场'));
      expect(next, contains('乙与丙都在场'));
    });

    test('多个规则同时应用', () {
      const text = '''
══ 大事件1：青阳城之变 ══
  李云飞在青阳城遇到了玄机子。
''';
      final next = renameInOutlineText(text, {
        '李云飞': '顾长风',
        '青阳城': '洛水关',
        '玄机子': '无涯子',
      });
      expect(next, contains('══ 大事件1：洛水关之变 ══'));
      expect(next, contains('顾长风在洛水关遇到了无涯子。'));
    });

    test('同一行多处命中都要换掉', () {
      const text = '''
○ 小事件1：相遇
  李云飞看着李云飞自己的影子。
''';
      final next = renameInOutlineText(text, {'李云飞': '顾长风'});
      expect(next, contains('顾长风看着顾长风自己的影子。'));
    });

    test('空规则 / 原新同名时不改动正文', () {
      expect(renameInOutlineText(sample, {}), sample);
      expect(renameInOutlineText(sample, {'李云飞': '  '}), sample);
      expect(renameInOutlineText(sample, {'李云飞': '李云飞'}), sample);
    });

    test('没有事件结构时（伏笔清单）按纯文本替换', () {
      const foreshadows = '李云飞身上的玉佩\n青阳城的旧伤';
      final next = renameInOutlineText(
        foreshadows,
        {'李云飞': '顾长风', '青阳城': '洛水关'},
        fallbackToPlainText: true,
      );
      expect(next, '顾长风身上的玉佩\n洛水关的旧伤');
    });

    test('纯文本替换不会把自己刚写进去的字再改一遍', () {
      const text = '李云身上的剑';
      // 李云 → 李云霄：替换文本里含原词，不做保护会越改越长
      final next = renameInOutlineText(
        text,
        {'李云': '李云霄'},
        fallbackToPlainText: true,
      );
      expect(next, '李云霄身上的剑');
    });
  });

  group('事件索引', () {
    test('事件序号与章节表的 event_index 对齐（全篇连续编号）', () {
      final index = OutlineTextIndex.of(sample);
      expect(index.events.length, 3);
      expect(index.events.map((e) => e.index), [1, 2, 3]);
      expect(index.events[0].isMajor, isTrue);
      expect(index.events[1].isMajor, isFalse);
      expect(index.events.map((e) => e.title), ['初入江湖', '拜师', '下山']);
    });

    test('概要区到下一个事件 / 幕标题为止', () {
      final index = OutlineTextIndex.of(sample);
      final major = index.events.first;
      final body = index.lines.sublist(major.bodyStart, major.bodyEnd).join('\n');
      expect(body, contains('李云飞在青阳城醒来'));
      expect(body, contains('他遇到了师父玄机子'));
      // 事件之外的说明文字不在概要区里
      expect(body, isNot(contains('设定')));
    });
  });
}
