import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 粗骨保留：后续精写不能把粗骨改掉。
///
/// 用户报的问题：生成到后面（精写/展开）之后，再打开「编辑粗骨」看到的已经不是
/// 当初的粗骨。根因是 2b 精写会用精写概述覆盖 `_step2Json`，而落库的 skeleton
/// 只存了精写后的版本。现在控制器单独保存 `_coarseActs`，并写进 skeleton.coarse。
void main() {
  late OutlineController controller;

  setUp(() {
    controller = OutlineController();
  });

  tearDown(() {
    controller.dispose();
  });

  test('落库 skeleton 同时保存精写后的 step2 与粗骨 coarse', () {
    controller.debugSeedSkeletonForTest(
      step1: {'title': '书', 'concept': '概念'},
      step2: _actsJson('精写概述'),
      coarse: _actsJson('粗骨定位'),
    );

    final json =
        jsonDecode(controller.debugSkeletonJsonForTest())
            as Map<String, dynamic>;
    expect(json.keys, containsAll(['step1', 'step2', 'coarse']));

    final step2Summary = _firstSummary(json['step2'] as Map<String, dynamic>);
    final coarseSummary = _firstSummary(json['coarse'] as Map<String, dynamic>);
    expect(step2Summary, '精写概述-A');
    expect(coarseSummary, '粗骨定位-A');
    expect(step2Summary, isNot(coarseSummary));
  });

  test('编辑粗骨：优先使用记录里的 coarse，而不是正文/精写后的内容', () {
    expect(
      controller.debugSeedFromRecordForTest(_record(), kind: 'skeleton'),
      isTrue,
    );
    final coarse = controller.debugRenderCoarseSkeletonForTest();
    expect(coarse, contains('粗骨定位'));
    expect(coarse, isNot(contains('正文里的展开概述')));
  });

  test('编辑大事件：用正文解析出的大事件，同时保留记录里的粗骨', () {
    expect(
      controller.debugSeedFromRecordForTest(_record(), kind: 'events'),
      isTrue,
    );
    // 编辑大事件展示的是正文里（展开后）的大事件概述
    expect(controller.debugStepPreviewForTest, contains('正文里的展开概述'));
    // 但「返回上一步 / 编辑粗骨」仍然拿得到粗骨原文
    expect(controller.debugRenderCoarseSkeletonForTest(), contains('粗骨定位'));
  });

  test('旧记录没有 coarse 时仍可编辑粗骨（回退正文解析，不崩）', () {
    final legacy = _record(withCoarse: false);
    expect(
      controller.debugSeedFromRecordForTest(legacy, kind: 'skeleton'),
      isTrue,
    );
    expect(
      controller.debugRenderCoarseSkeletonForTest(),
      contains('正文里的展开概述'),
    );
  });
}

/// 三幕 JSON：三个大事件，summary 用 [prefix] 区分粗骨 / 精写版本
Map<String, dynamic> _actsJson(String prefix) => {
  'acts': [
    {
      'act': '第一幕',
      'events': [
        {'title': 'A', 'summary': '$prefix-A'},
      ],
    },
    {
      'act': '第二幕',
      'events': [
        {'title': 'B', 'summary': '$prefix-B'},
      ],
    },
    {
      'act': '第三幕',
      'events': [
        {'title': 'C', 'summary': '$prefix-C'},
      ],
    },
  ],
};

String _firstSummary(Map<String, dynamic> step2) {
  final acts = step2['acts'] as List;
  final events = (acts.first as Map)['events'] as List;
  return ((events.first as Map)['summary'] as String?) ?? '';
}

/// 历史记录：正文里的「大事件概述」是展开后的版本（正文里的展开概述），
/// skeleton 里同时带精写后的 step2 和粗骨 coarse。
OutlineRecord _record({bool withCoarse = true}) {
  const content =
      '书名：《书》\n\n'
      '概念\n\n'
      '══ 第一幕：开端 ══\n'
      '══ 大事件1：A ══\n'
      '正文里的展开概述A\n\n'
      '══ 第二幕：发展 ══\n'
      '══ 大事件2：B ══\n'
      '正文里的展开概述B\n\n'
      '══ 第三幕：高潮&结局 ══\n'
      '══ 大事件3：C ══\n'
      '正文里的展开概述C\n';
  final skeleton = <String, dynamic>{
    'step1': {'title': '书', 'concept': '概念'},
    'step2': _actsJson('精写概述'),
    if (withCoarse) 'coarse': _actsJson('粗骨定位'),
    'majorEventCount': 3,
    'minorEventCount': 2,
    'completedChunks': 1,
    'totalChunks': 1,
    'ledger': {
      'foreshadows': <Map<String, dynamic>>[],
      'characters': <String>[],
      'unresolved': <String>[],
    },
  };
  return OutlineRecord(
    title: '书',
    genre: '都市',
    theme: '主题',
    protagonist: '主角',
    worldview: '世界观',
    content: content,
    skeleton: jsonEncode(skeleton),
  );
}
