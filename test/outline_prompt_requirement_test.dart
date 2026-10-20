import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_service.dart';

/// 「要求提示词」输入框（一键生成大纲页面）注入生成提示词。
///
/// 用户在页面里填写的额外要求（节奏、禁忌、偏好等）必须进入定调、粗骨架、
/// 精写大事件、展开小事件四步提示词；留空时提示词保持原样。
void main() {
  const requirement = '节奏要快，不要后宫，每个大事件都要有爽点';

  test('要求提示词注入到定调 / 粗骨架 / 精写 / 展开四步提示词', () {
    final step1 = OutlinePromptTemplate.buildStep1Prompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      extraRequirement: requirement,
    );
    expect(step1, contains('=== 额外要求'));
    expect(step1, contains(requirement));
    expect(step1, contains('以本要求为准'));

    final coarse = OutlinePromptTemplate.buildCoarseSkeletonPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      titleAndConcept: '书名+概念',
      extraRequirement: requirement,
    );
    expect(coarse, contains(requirement));

    final refine = OutlinePromptTemplate.buildRefineBatchPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      title: '书名',
      concept: '概念',
      coarseSkeletonText: '粗骨架',
      batchContent: '本批事件',
      ledgerText: '（暂无）',
      extraRequirement: requirement,
    );
    expect(refine, contains(requirement));

    final expand = OutlinePromptTemplate.buildStep3Prompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      title: '书名',
      actContent: '══ 大事件1：标题 ══\n概述',
      actIndex: 1,
      globalSummary: '全局框架',
      extraRequirement: requirement,
    );
    expect(expand, contains(requirement));
  });

  test('不填要求提示词时，四步提示词都不会出现「额外要求」段', () {
    final step1 = OutlinePromptTemplate.buildStep1Prompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
    );
    expect(step1, isNot(contains('=== 额外要求')));

    final coarse = OutlinePromptTemplate.buildCoarseSkeletonPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      titleAndConcept: '书名+概念',
    );
    expect(coarse, isNot(contains('=== 额外要求')));

    final refine = OutlinePromptTemplate.buildRefineBatchPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      title: '书名',
      concept: '概念',
      coarseSkeletonText: '粗骨架',
      batchContent: '本批事件',
      ledgerText: '（暂无）',
    );
    expect(refine, isNot(contains('=== 额外要求')));

    final expand = OutlinePromptTemplate.buildStep3Prompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      title: '书名',
      actContent: '══ 大事件1：标题 ══\n概述',
      actIndex: 1,
      globalSummary: '全局框架',
    );
    expect(expand, isNot(contains('=== 额外要求')));
  });
}
