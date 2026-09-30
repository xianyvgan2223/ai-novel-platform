import 'package:flutter_test/flutter_test.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_text_sync.dart';

/// 增删事件的正文写法：新增事件插进大纲正文、删除事件连同概要区一起移除。
/// 这两件事必须与 `parseOutlineEvents` 完全对齐——正文里的第 N 个事件
/// 就是编辑页的第 N 张卡片、也是「大纲转章节」的第 N 章。
void main() {
  /// 正文里的第 N 个事件（从 1 开始）
  String titleAt(String content, int n) =>
      parseOutlineEvents(content, outlineId: 1)[n - 1].eventTitle;

  String typeAt(String content, int n) =>
      parseOutlineEvents(content, outlineId: 1)[n - 1].eventType;

  String summaryAt(String content, int n) =>
      parseOutlineEvents(content, outlineId: 1)[n - 1].eventSummary;

  group('insertEventIntoOutlineText 新增事件', () {
    final base = [
      '══ 大事件1：甲 ══',
      '甲的第一段',
      '甲的第二段',
      '',
      '○ 小事件1：乙',
      '乙的概要',
      '',
      '══ 大事件2：丙 ══',
      '丙的概要',
    ].join('\n');

    test('插到中间：不并进上一条概要，标题与概要都不被打散', () {
      final out = insertEventIntoOutlineText(
        base,
        eventIndex: 2,
        isMajor: false,
        title: '新事件',
      );
      final chapters = parseOutlineEvents(out, outlineId: 1);

      expect(chapters.length, 4);
      expect(titleAt(out, 1), '甲');
      expect(summaryAt(out, 1), '甲的第一段\n甲的第二段'); // 概要没被吃掉
      expect(titleAt(out, 2), '新事件'); // 正好插在第 2 位
      expect(typeAt(out, 2), 'minor');
      expect(titleAt(out, 3), '乙');
      expect(summaryAt(out, 3), '乙的概要');
      expect(titleAt(out, 4), '丙');
      expect(summaryAt(out, 4), '丙的概要');
    });

    test('插到中间（大事件）：写规范标题行', () {
      final out = insertEventIntoOutlineText(
        base,
        eventIndex: 2,
        isMajor: true,
        title: '大事',
      );
      expect(out.contains('══ 大事件2：大事 ══'), isTrue);
      expect(typeAt(out, 2), 'major');
      expect(summaryAt(out, 1), '甲的第一段\n甲的第二段');
    });

    test('追加到末尾：仍是合法事件行，前面条目的概要不受影响', () {
      final out = insertEventIntoOutlineText(
        base,
        eventIndex: 4, // 现有 3 条，越界即追加
        isMajor: true,
        title: '尾巴',
      );
      expect(parseOutlineEvents(out, outlineId: 1).length, 4);
      expect(titleAt(out, 4), '尾巴');
      expect(summaryAt(out, 3), '丙的概要');
      expect(summaryAt(out, 1), '甲的第一段\n甲的第二段');
    });

    test('空正文里新增：能解析出这一条', () {
      final out = insertEventIntoOutlineText(
        '',
        eventIndex: 1,
        isMajor: true,
        title: '开篇',
      );
      expect(parseOutlineEvents(out, outlineId: 1).length, 1);
      expect(titleAt(out, 1), '开篇');
    });

    test('新增的标题带嵌套事件前缀时会被剥掉（与生成侧同一套写法）', () {
      final out = insertEventIntoOutlineText(
        base,
        eventIndex: 1,
        isMajor: true,
        title: '大事件9：重复前缀',
      );
      expect(titleAt(out, 1), '重复前缀');
    });
  });

  group('removeEventFromOutlineText 删除事件', () {
    final base = [
      '══ 大事件1：甲 ══',
      '甲的第一段',
      '甲的第二段',
      '',
      '○ 小事件1：乙',
      '乙的概要',
      '',
      '══ 大事件2：丙 ══',
      '丙的概要',
    ].join('\n');

    test('删中间一条：只删它自己，前后条目完整保留', () {
      final out = removeEventFromOutlineText(base, 2);
      final chapters = parseOutlineEvents(out, outlineId: 1);

      expect(chapters.length, 2);
      expect(titleAt(out, 1), '甲');
      expect(summaryAt(out, 1), '甲的第一段\n甲的第二段');
      expect(titleAt(out, 2), '丙');
      expect(summaryAt(out, 2), '丙的概要');
      expect(out.contains('乙'), isFalse);
    });

    test('删第一条：后面的条目变成第一条且不与末尾粘连', () {
      final out = removeEventFromOutlineText(base, 1);
      expect(parseOutlineEvents(out, outlineId: 1).length, 2);
      expect(titleAt(out, 1), '乙');
      expect(summaryAt(out, 1), '乙的概要');
      expect(titleAt(out, 2), '丙');
      expect(summaryAt(out, 2), '丙的概要');
      expect(out.contains('甲'), isFalse);
    });

    test('删最后一条：前面的条目不受影响', () {
      final out = removeEventFromOutlineText(base, 3);
      expect(parseOutlineEvents(out, outlineId: 1).length, 2);
      expect(titleAt(out, 2), '乙');
      expect(summaryAt(out, 2), '乙的概要');
      expect(titleAt(out, 1), '甲');
      expect(summaryAt(out, 1), '甲的第一段\n甲的第二段');
      expect(out.contains('丙'), isFalse);
    });

    test('序号不存在时原样返回', () {
      expect(removeEventFromOutlineText(base, 9), base);
      expect(removeEventFromOutlineText(base, 0), base);
    });

    test('不吞掉幕标题等边界行', () {
      final withAct = [
        '══ 大事件1：甲 ══',
        '甲的概要',
        '',
        '══ 第二幕：开端 ══',
        '',
        '══ 大事件2：乙 ══',
        '乙的概要',
      ].join('\n');
      final out = removeEventFromOutlineText(withAct, 2);
      expect(out.contains('第二幕：开端'), isTrue);
      expect(out.contains('甲的概要'), isTrue);
      expect(out.contains('乙的概要'), isFalse);
    });

    test('删掉唯一一条：只剩空正文，不留下孤立空行', () {
      final single = ['══ 大事件1：甲 ══', '甲的概要'].join('\n');
      final out = removeEventFromOutlineText(single, 1);
      expect(out.trim(), isEmpty);
    });

    test('概要区紧挨着下一条标题时（中间没有空行）也能整块删掉', () {
      final tight = [
        '══ 大事件1：甲 ══',
        '甲的概要',
        '○ 小事件1：乙',
        '乙的概要',
      ].join('\n');
      final out = removeEventFromOutlineText(tight, 1);
      expect(out.contains('甲'), isFalse);
      expect(titleAt(out, 1), '乙');
      expect(summaryAt(out, 1), '乙的概要');
    });
  });

  group('新增与删除互不干扰的回归点', () {
    test('连续新增两条后序号与解析结果一致', () {
      final one = insertEventIntoOutlineText(
        '',
        eventIndex: 1,
        isMajor: true,
        title: 'A',
      );
      final two = insertEventIntoOutlineText(
        one,
        eventIndex: 2,
        isMajor: false,
        title: 'B',
      );
      final three = insertEventIntoOutlineText(
        two,
        eventIndex: 2,
        isMajor: false,
        title: 'C',
      );

      expect(parseOutlineEvents(three, outlineId: 1).length, 3);
      expect(titleAt(three, 1), 'A');
      expect(titleAt(three, 2), 'C');
      expect(titleAt(three, 3), 'B');
      expect(summaryAt(three, 2), ''); // 新事件没有概要，不会粘上前一条
      expect(summaryAt(three, 3), '');
    });

    test('带缩进的事件行：新增时保持同一缩进（对齐事件行而不是概要）', () {
      final indented = ['  大事件1：甲', '    甲的概要'].join('\n');
      final out = insertEventIntoOutlineText(
        indented,
        eventIndex: 2,
        isMajor: true,
        title: '乙',
      );
      final line = out.split('\n').firstWhere((l) => l.contains('乙'));
      // 两个空格（事件行的缩进），不是四个（概要的缩进），也不是零个
      expect(line.length - line.trimLeft().length, 2);
      expect(line.trim(), '══ 大事件2：乙 ══'); // 规范写法
      expect(parseOutlineEvents(out, outlineId: 1).length, 2);
    });
  });

  group('增删配对：与编辑页看到的第几条一致', () {
    test('新增后按新序号删除，删掉的正是刚加的那条', () {
      final base = [
        '══ 大事件1：甲 ══',
        '甲的概要',
        '',
        '══ 大事件2：乙 ══',
        '乙的概要',
      ].join('\n');

      final added = insertEventIntoOutlineText(
        base,
        eventIndex: 2,
        isMajor: false,
        title: '夹心',
      );
      expect(titleAt(added, 2), '夹心');

      final removed = removeEventFromOutlineText(added, 2);
      expect(removed.contains('夹心'), isFalse);
      expect(parseOutlineEvents(removed, outlineId: 1).length, 2);
      expect(titleAt(removed, 1), '甲');
      expect(summaryAt(removed, 1), '甲的概要');
      expect(titleAt(removed, 2), '乙');
      expect(summaryAt(removed, 2), '乙的概要');
    });
  });

  group('mergeEventIntoOutlineText：序号错位时不再按标题兜底', () {
    final content = [
      '══ 大事件1：甲 ══',
      '甲的概要',
      '══ 大事件2：乙 ══',
      '乙的概要',
    ].join('\n');

    test('序号位置上标题对不上：原样返回，不去改别处的同名事件', () {
      // 序号 1 的位置是「甲」，却要写「乙」——说明结构与序号已错位。
      // 旧实现会按标题兜底找到第 2 条并把它的概要改掉（改错行）。
      expect(
        mergeEventIntoOutlineText(
          content,
          oldTitle: '乙',
          newTitle: '乙（改）',
          newSummary: '不该写进去',
          eventIndex: 1,
        ),
        content,
      );
    });

    test('没给序号时仍按标题定位（保留旧调用方的兜底能力）', () {
      final out = mergeEventIntoOutlineText(
        content,
        oldTitle: '乙',
        newTitle: '乙（改）',
        newSummary: '新概要',
      );
      expect(out.contains('乙（改）'), isTrue);
      expect(out.contains('新概要'), isTrue);
      expect(out.contains('甲的概要'), isTrue);
    });
  });
}
