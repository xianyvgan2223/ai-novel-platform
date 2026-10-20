import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_syntax.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_text_sync.dart';

/// 事件边界统一（E）：概述里以 `-` / `○` 开头的普通行不再被当成事件边界。
///
/// 之前三处规则不一致：
/// - `parseOutlineEvents` 把任何 `-` 行排除在概述外（概述内容少几行）；
/// - `isOutlineBoundaryLine`（编辑写回）把任何 `-` / `○` 行当边界
///   （改概述时列表行留在区外，改/删事件时漏改漏删）；
/// - `_parseRecordActs`（局部重新生成）却把 `-` 行算进概述。
/// 现在统一为：**只有被 classifyOutlineLine 识别成事件 / 幕标题 / 装饰行才算边界**，
/// `- 小事件N：x` 这种真事件行仍被正确识别。
void main() {
  test('概述里的 `-` 列表行属于概述内容（parseOutlineEvents 不再丢）', () {
    const content =
        '══ 大事件1：旧宅第一夜 ══\n'
        '第一段：他搬进旧宅。\n'
        '- 旧铁条\n'
        '- 姜黎那句话\n'
        '○ 小事件1：门槛\n'
        '他在门槛上坐了一夜。\n';
    final events = parseOutlineEvents(content, outlineId: 0);

    expect(events.map((e) => e.eventTitle).toList(), ['旧宅第一夜', '门槛']);
    expect(events[0].eventSummary, contains('- 旧铁条'));
    expect(events[0].eventSummary, contains('- 姜黎那句话'));
    expect(events[0].eventSummary, contains('第一段：他搬进旧宅。'));
    // 列表行不会被误当成事件
    expect(events.length, 2);
  });

  test('`- 小事件N：x` / `○ 小事件N：x` 仍然是事件边界', () {
    const content =
        '══ 大事件1：甲 ══\n'
        '概述\n'
        '- 小事件1：乙\n'
        '- 小事件2：丙\n'
        '正文\n';
    final events = parseOutlineEvents(content, outlineId: 0);

    expect(events.map((e) => e.eventTitle).toList(), ['甲', '乙', '丙']);
    expect(events[0].eventSummary, '概述');
    expect(events[1].eventType, 'minor');
    expect(events[2].eventType, 'minor');
  });

  test('边界判定：只认事件 / 幕标题 / 装饰行', () {
    for (final raw in [
      '══ 大事件1：甲 ══',
      '大事件1：甲',
      '○ 小事件1：乙',
      '- 小事件1：乙',
      '══ 第二幕：发展 ══',
      '════',
    ]) {
      expect(isOutlineBoundaryLine(raw), isTrue, reason: raw);
    }
    for (final raw in [
      '- 旧铁条',
      '- 第13个事件：说明文字',
      '○ 说明性文字',
      '普通概要文字',
      '   ',
    ]) {
      expect(isOutlineBoundaryLine(raw), isFalse, reason: raw);
    }
  });

  test('编辑大事件概述：`-` 列表行随概述区一起替换', () {
    const content =
        '══ 大事件1：甲 ══\n'
        '旧概述\n'
        '- 旧铁条\n'
        '- 旧列表\n'
        '○ 小事件1：乙\n'
        '正文\n';
    final merged = mergeEventIntoOutlineText(
      content,
      oldTitle: '甲',
      newTitle: '甲',
      newSummary: '新概述\n- 新列表',
      eventIndex: 1,
    );

    expect(merged, contains('新概述'));
    expect(merged, contains('- 新列表'));
    expect(merged, isNot(contains('旧列表')));
    expect(merged, isNot(contains('旧铁条')));
    expect(merged, contains('○ 小事件1：乙'));
  });

  test('删除事件：概述里的 `-` 列表行随块一起删除，后续事件不受影响', () {
    const content =
        '══ 大事件1：甲 ══\n'
        '旧概述\n'
        '- 旧铁条\n'
        '○ 小事件1：乙\n'
        '正文\n';
    final removed = removeEventFromOutlineText(
      content,
      1,
      expectTitles: const ['甲'],
      expectMajor: true,
    );

    expect(removed, isNot(contains('旧概述')));
    expect(removed, isNot(contains('旧铁条')));
    expect(removed, contains('○ 小事件1：乙'));
    expect(removed, contains('正文'));
  });
}
