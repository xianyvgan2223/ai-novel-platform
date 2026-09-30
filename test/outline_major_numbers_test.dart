import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';

/// 大事件序号：只数大事件（对应大纲正文里的「大事件N」），小事件不占号。
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
}
