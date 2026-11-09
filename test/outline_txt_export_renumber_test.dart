import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_transfer.dart';

/// 导出前自动整理：事件 / 幕标题统一成规范写法并重新编号。
///
/// 背景：大纲编辑里新增事件写入的行号取的是「全文事件序号」，会出现重号 /
/// 跳号。导出时统一一次，导出的 v2 txt 编号与顺序一致；数据库原文不动。
void main() {
  /// 故意写乱的大纲正文：大事件 5 / 6 / 7（跳号）、小事件 9 / 2 / 4（重号），
  /// 还有 markdown 前缀与加粗包裹；概要行带缩进。
  const dirty = '''## 第一幕：开端

══ 大事件5：穿越临海市 ══
- 小事件9：初抵炼狱
  深夜里，顾泽在城郊醒来。

**大事件7：首见丧尸**
○ 小事件2：异响惊夜
  深夜，客房中顾泽并未真正熟睡。

══ 大事件6：街头幸存者 ══
小事件4：公交车惨剧
  清晨离开天台后。''';

  /// 规范化后的唯一正确结果：大事件全篇连续 1..3，小事件在每个大事件内从 1 开始。
  const expected = '''══ 第一幕：开端 ══

══ 大事件1：穿越临海市 ══
○ 小事件1：初抵炼狱
  深夜里，顾泽在城郊醒来。

══ 大事件2：首见丧尸 ══
○ 小事件1：异响惊夜
  深夜，客房中顾泽并未真正熟睡。

══ 大事件3：街头幸存者 ══
○ 小事件1：公交车惨剧
  清晨离开天台后。''';

  test('导出整理：重号 / 跳号 / markdown 写法统一成规范编号', () {
    expect(prepareOutlineTxtExportContent(dirty), expected);
  });

  test('整理是幂等的：对已规范文本再执行一次结果不变', () {
    final once = prepareOutlineTxtExportContent(dirty);
    expect(prepareOutlineTxtExportContent(once), once);
    expect(once, expected);
  });

  test('只改标题行：概要行逐字节保留（含缩进与空行）', () {
    final result = prepareOutlineTxtExportContent(dirty);
    expect(result.contains('  深夜里，顾泽在城郊醒来。'), isTrue);
    expect(result.contains('  深夜，客房中顾泽并未真正熟睡。'), isTrue);
    expect(result.contains('  清晨离开天台后。'), isTrue);
    // 非标题行数量与内容一致
    List<String> bodyLines(String text) => text
        .split('\n')
        .where(
          (line) =>
              line.trim().isNotEmpty &&
              !line.contains('大事件') &&
              !line.contains('小事件') &&
              !line.contains('第') &&
              !line.contains('幕'),
        )
        .toList();
    expect(bodyLines(result), bodyLines(dirty));
  });

  test('嵌套事件前缀在规范化时被剥掉', () {
    expect(prepareOutlineTxtExportContent('大事件3：大事件8：唯欣苏醒'), '══ 大事件1：唯欣苏醒 ══');
  });

  test('没有事件行时原样返回', () {
    const plain = '这段是普通大纲说明，没有任何事件标题。\n\n第二段也正常。';
    expect(prepareOutlineTxtExportContent(plain), plain);
  });

  test('导出的 txt 再导入：能识别规范写法，正文与编号保持一致', () {
    final content = prepareOutlineTxtExportContent(dirty);
    final text = renderOutlineTxtDocument(title: '测试小说', content: content);
    expect(text.contains('## 大纲正文'), isTrue);

    final doc = parseOutlineTxtDocument(text);
    expect(doc.structured, isTrue);
    expect(doc.title, '测试小说');
    expect(doc.content, content);

    final events = parseOutlineEvents(doc.content, outlineId: 0);
    expect(events.map((e) => e.eventTitle).toList(), [
      '穿越临海市',
      '初抵炼狱',
      '首见丧尸',
      '异响惊夜',
      '街头幸存者',
      '公交车惨剧',
    ]);
    expect(events.map((e) => e.eventType).toList(), [
      'major',
      'minor',
      'major',
      'minor',
      'major',
      'minor',
    ]);
    expect(countOutlineTxtEvents(doc.content), 6);
  });

  test('旧版纯正文 txt 导入同样识别规范写法', () {
    final content = prepareOutlineTxtExportContent(dirty);
    final doc = parseOutlineTxtDocument(content);
    expect(doc.structured, isFalse);
    expect(doc.content, content);
    expect(countOutlineTxtEvents(doc.content), 6);
  });
}
