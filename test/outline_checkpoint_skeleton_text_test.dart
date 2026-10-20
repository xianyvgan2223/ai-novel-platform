import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';

/// 检查点编辑文本的解析（F）：必须走统一的事件识别规则。
///
/// 用户编辑「粗骨检查点 / 大事件检查点」里显示的文本后点「继续」，控制器要把
/// 文本解析回三幕骨架。旧实现另写了一份手写正则 `^大事件\d+：标题`，连检查点
/// 编辑器里显示的标准写法 `══ 大事件N：标题 ══` 都识别不了，导致编辑后继续必报
/// 「编辑内容无法解析为三幕结构」。修复后统一走 classifyOutlineLine，并保留
/// 多行概述（含段落空行）。
void main() {
  late OutlineController controller;

  setUp(() {
    controller = OutlineController();
  });

  tearDown(() {
    controller.dispose();
  });

  test('标准 ══ 写法 + 多行概述：能解析回三幕骨架，概述逐行保留', () {
    const text = '''
══ 第一幕：开端 ══
══ 大事件1：旧宅第一夜 ══
第一段：他搬进旧宅。
第二段：他把门闩上又拔出来。

第三段：天亮前他一直没睡。

══ 大事件2：首见尸兄 ══
他杀了穿越后第一只尸兄。

══ 第二幕：发展 ══
══ 大事件3：街头幸存者 ══
公交车侧翻在路口。

══ 第三幕：高潮&结局 ══
══ 大事件4：把药喝完 ══
他喝完了自己熬的药。
''';
    final parsed = controller.debugParseSkeletonTextForTest(text);
    expect(parsed, isNotNull);

    final acts = parsed!['acts'] as List;
    expect(acts, hasLength(3));

    final act1Events = ((acts[0] as Map)['events'] as List)
        .cast<Map<String, dynamic>>();
    expect(act1Events.map((e) => e['title']).toList(), ['旧宅第一夜', '首见尸兄']);

    final summary = act1Events.first['summary'] as String;
    // 多行概述完整保留（包括段落之间的空行）
    expect(summary, contains('第一段：他搬进旧宅。'));
    expect(summary, contains('第三段：天亮前他一直没睡。'));
    expect(summary, contains('\n\n'));
    // 标题行绝不能混进概述
    expect(summary, isNot(contains('大事件1：')));
    expect(summary, isNot(contains('══')));
  });

  test('裸标题 / markdown / 缩进写法同样能解析（与历史解析同一套规则）', () {
    const text = '''
## ══ 第一幕：开端 ══
**大事件1：旧宅第一夜**
概述A

### 第二幕：发展
  ══ 大事件2：首见尸兄 ══
概述B

══ 第三幕：高潮&结局 ══
大事件3：把药喝完
概述C
''';
    final parsed = controller.debugParseSkeletonTextForTest(text);
    expect(parsed, isNotNull);
    final acts = parsed!['acts'] as List;
    expect(acts, hasLength(3));
    final titles = [
      for (final act in acts)
        for (final e in (act as Map)['events'] as List) (e as Map)['title'],
    ];
    expect(titles, ['旧宅第一夜', '首见尸兄', '把药喝完']);
  });

  test('解析不出三幕结构时返回 null（保持原错误提示）', () {
    expect(controller.debugParseSkeletonTextForTest('这里只有普通说明文字'), isNull);
    expect(
      controller.debugParseSkeletonTextForTest('══ 大事件1：标题 ══\n概述'),
      isNull, // 没有三幕结构
    );
  });
}
