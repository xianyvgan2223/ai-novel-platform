import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';

/// 大 / 小事件序号（与大纲正文里的「大事件N」/「○ 小事件N」同一套）：
/// - 大事件：全篇只数大事件，从 1 连续；
/// - 小事件：在**所属大事件内部**从 1 重新计数，大事件不占号。
///
/// 选择事件页按行下标取序号，编辑页只拿到勾选的几章，按 chapter.id 反查。
void main() {
  OutlineChapter ch(String type, String title, {int? id, int eventIndex = 1}) =>
      OutlineChapter(
        id: id,
        outlineId: 1,
        eventIndex: eventIndex,
        eventType: type,
        eventTitle: title,
      );

  test('大事件从 1 连续编号，小事件位置为 null', () {
    final numbers = majorEventNumbers([
      ch('major', '企鹅变异'),
      ch('minor', '动物园来客'),
      ch('minor', '心痕'),
      ch('major', '公园兔潮'),
      ch('major', '一体同人'),
    ]);
    expect(numbers, <int?>[1, null, null, 2, 3]);
  });

  test('空列表与没有大事件', () {
    expect(majorEventNumbers([]), isEmpty);
    expect(majorEventNumbers([ch('minor', '只有小事件')]), <int?>[null]);
  });

  test('大事件编号不受小事件数量影响（event_index 会跳号，它不会）', () {
    final chapters = <OutlineChapter>[
      ch('major', 'A'),
      for (var i = 1; i <= 12; i++) ch('minor', '小事件$i'),
      ch('major', 'B'),
    ];
    final numbers = majorEventNumbers(chapters);
    expect(numbers.first, 1);
    expect(numbers.last, 2);
  });

  test('按 id 反查：编辑页只勾选了一章，序号也不从头排', () {
    final all = <OutlineChapter>[
      ch('major', 'A', id: 11, eventIndex: 1),
      ch('minor', 'a1', id: 12, eventIndex: 2),
      ch('minor', 'a2', id: 13, eventIndex: 3),
      ch('major', 'B', id: 14, eventIndex: 4),
    ];
    final byId = majorEventNumbersById(all);
    expect(byId[11], 1);
    expect(byId[12], isNull); // 小事件没有大事件序号
    expect(byId[14], 2); // 勾选 B 单独编辑时，显示的仍是 2
    expect(byId.length, 4);
  });

  test('未入库（id 为 null）的章节不进序号表', () {
    final byId = majorEventNumbersById([ch('major', 'A'), ch('minor', 'a')]);
    expect(byId, isEmpty);
  });

  group('小事件序号：所属大事件内部从 1 重新计数', () {
    test('每个大事件重新从 1 开始，大事件位置为 null', () {
      final numbers = minorEventNumbers([
        ch('major', '企鹅变异'),
        ch('minor', '动物园来客'),
        ch('minor', '心痕'),
        ch('major', '公园兔潮'),
        ch('minor', '售票亭的约定'),
        ch('minor', '地下车库'),
      ]);
      expect(numbers, <int?>[null, 1, 2, null, 1, 2]);
    });

    test('不能拿 event_index 当小事件编号（小事件也会跳号）', () {
      final chapters = <OutlineChapter>[
        ch('major', 'A', eventIndex: 1),
        for (var i = 2; i <= 14; i++) ch('minor', '小事件${i - 1}', eventIndex: i),
        ch('major', 'B', eventIndex: 15),
        ch('minor', 'b1', eventIndex: 16),
      ];
      final numbers = minorEventNumbers(chapters);
      expect(numbers[0], isNull);
      expect(numbers[1], 1); // 不是 event_index 的 2
      expect(numbers[13], 13);
      expect(numbers[14], isNull);
      expect(numbers[15], 1); // 大事件 B 名下第一个小事件
    });

    test('开头没有大事件时小事件也从 1 起（与正文规范化同一口径）', () {
      expect(minorEventNumbers([
        ch('minor', '序章一'),
        ch('minor', '序章二'),
        ch('major', '甲'),
        ch('minor', '乙'),
      ]), <int?>[1, 2, null, 1]);
    });

    test('空列表 / 只有大事件', () {
      expect(minorEventNumbers([]), isEmpty);
      expect(minorEventNumbers([ch('major', 'A')]), <int?>[null]);
    });

    test('按 id 反查：只勾选一章时显示的仍是全篇里的那个序号', () {
      final byId = minorEventNumbersById([
        ch('major', 'A', id: 21, eventIndex: 1),
        ch('minor', 'a1', id: 22, eventIndex: 2),
        ch('minor', 'a2', id: 23, eventIndex: 3),
        ch('major', 'B', id: 24, eventIndex: 4),
        ch('minor', 'b1', id: 25, eventIndex: 5),
      ]);
      expect(byId[21], isNull); // 大事件没有小事件序号
      expect(byId[22], 1);
      expect(byId[23], 2);
      expect(byId[25], 1); // 大事件 B 名下第 1 个
    });
  });
}
