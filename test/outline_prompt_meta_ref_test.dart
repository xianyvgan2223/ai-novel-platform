import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_service.dart';

/// 生成提示词里的**硬性禁止编号引用**规则：
///
/// 用户报的问题：大纲变长后，大事件概述里会写「54与70埋的…」「第52章那根铁条」，
/// 这些编号会污染后续大事件 / 小事件的生成。要求：伏笔照应**直接写出内容本身**
/// （人物 / 旧物件 / 原话 / 场景），要么就不写编号。提示词是这条规则的第一道防线，
/// 这里把关键措辞钉住，防止后续改提示词时被顺手删掉。
void main() {
  test('精写大事件（步骤 2b）提示词：禁止编号引用 + 正反例', () {
    final prompt = OutlinePromptTemplate.buildRefineBatchPrompt(
      genre: '都市异能',
      theme: '从孑然一身到有人围着',
      protagonist: '顾泽',
      worldview: 'H市尸潮',
      title: '天下第一尸兄世界',
      concept: '杀神学着过日子',
      coarseSkeletonText: '第一幕：开端\n旧宅第一夜\n旧铁条',
      batchContent: '标题：旧宅第一夜\n定位：他搬进旧宅的第一夜',
      ledgerText: '（暂无）',
    );

    expect(prompt, contains('严禁编号引用'));
    expect(prompt, contains('summary 正文一律不带编号'));
    expect(prompt, contains('反例（禁止）'));
    expect(prompt, contains('正例（照此写）'));
    expect(prompt, contains('直接写出内容本身'));
    expect(prompt, contains('「第54章」'));
    expect(prompt, contains('「54与70埋的」'));
  });

  test('展开小事件（步骤 3）提示词：编号只出现在标题行 + 概述必须完整保留', () {
    final prompt = OutlinePromptTemplate.buildStep3Prompt(
      genre: '都市异能',
      theme: '主题',
      protagonist: '顾泽',
      worldview: 'H市尸潮',
      majorEventCount: 10,
      minorEventCount: 3,
      title: '天下第一尸兄世界',
      actContent: '══ 大事件3：旧宅第一夜 ══\n他搬进旧宅的第一夜。',
      actIndex: 1,
      globalSummary: '完整骨架……',
    );

    expect(prompt, contains('编号只允许出现在标题行'));
    expect(prompt, contains('大事件概述、小事件概要等正文里严禁'));
    expect(prompt, contains('直接写出内容本身'));
    expect(prompt, contains('第54章'));
    // 大事件概述必须原样保留（用户报的「小事件没把大事件全部内容包括到」）
    expect(prompt, contains('原样完整保留'));
    expect(prompt, contains('不得删减信息、不得压缩、不得重写'));
    // 小事件必须完整覆盖大事件概述里的内容
    expect(prompt, contains('小事件组合起来必须完整覆盖'));
  });

  test('伏笔账本（步骤 2c）提示词：账本字段禁止编号，plan 只写叙事阶段', () {
    final prompt = OutlinePromptTemplate.buildLedgerPrompt(
      batchContent: '标题：旧宅第一夜\n概述：他搬进旧宅。',
      prevLedgerText: '（暂无）',
    );

    expect(prompt, contains('严禁编号引用'));
    expect(prompt, contains('第一幕 / 第二幕 / 第三幕 / 终章'));
    expect(prompt, contains('不要写「第几章埋的伏笔」'));
  });

  test('粗骨架（步骤 2a）提示词：定位里禁止编号引用', () {
    final prompt = OutlinePromptTemplate.buildCoarseSkeletonPrompt(
      genre: '都市异能',
      theme: '主题',
      protagonist: '顾泽',
      worldview: 'H市尸潮',
      majorEventCount: 10,
      minorEventCount: 3,
      titleAndConcept: '书名+概念',
    );

    expect(prompt, contains('定位里严禁写章节 / 事件编号'));
    expect(prompt, contains('不要写「第几章埋的伏笔」'));
  });
}
