import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_service.dart';

/// 一键生成大纲的伏笔策略（提示词侧）：
/// - 不再要求「预留 3 处长线伏笔」；
/// - 只做短线伏笔：每条必须能在 5 个大事件内回收；
/// - 账本只保留未回收项，已回收 / 已实现的伏笔直接删除。
void main() {
  test('定调提示词不再写「核心概念简介概括世界观、主角核心困境、故事最终落点」', () {
    final prompt = OutlinePromptTemplate.buildStep1Prompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
    );
    expect(prompt, isNot(contains('核心概念简介概括世界观')));
    expect(prompt, isNot(contains('故事最终落点')));
    // 书名要求与 JSON 输出格式仍在
    expect(prompt, contains('书名务必贴合'));
    expect(prompt, contains('"concept"'));
  });

  test('粗骨架提示词：去掉「至少预留 3 处长线伏笔」，改为只做短线伏笔', () {
    final prompt = OutlinePromptTemplate.buildCoarseSkeletonPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      titleAndConcept: '书名+概念',
    );
    expect(prompt, isNot(contains('至少预留 3 处长线伏笔')));
    expect(prompt, isNot(contains('埋长线伏笔：')));
    expect(prompt, contains('只做短线伏笔'));
    expect(prompt, contains('必须能在 5 个大事件之内埋设并回收'));
    expect(prompt, contains('不要写长线伏笔'));
  });

  test('粗骨架提示词：每 5 个大事件形成一个递进弧', () {
    final prompt = OutlinePromptTemplate.buildCoarseSkeletonPrompt(
      genre: '玄幻',
      theme: '主题',
      protagonist: '主角',
      worldview: '世界观',
      majorEventCount: 10,
      minorEventCount: 3,
      titleAndConcept: '书名+概念',
    );
    expect(
      prompt,
      contains('每5个大事件之间要有递进关系：铺垫→冲突升级→危机加剧→高潮→收束或者危机→冲突→怎么解决→反转→剧情展开'),
    );
  });

  test('精写大事件提示词：新伏笔 5 个大事件内回收，已回收不再写', () {
    final prompt = OutlinePromptTemplate.buildRefineBatchPrompt(
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
    expect(prompt, contains('必须能在 5 个大事件之内回收'));
    expect(prompt, contains('不要写长线伏笔'));
    expect(prompt, contains('已回收的伏笔不要再写'));
  });

  test('步骤 3 展开提示词：伏笔只做短线、5 个大事件内回收', () {
    final prompt = OutlinePromptTemplate.buildStep3Prompt(
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
    expect(prompt, contains('伏笔只做短线'));
    expect(prompt, contains('必须能在 5 个大事件之内回收'));
    expect(prompt, contains('不要设计长线伏笔'));
  });

  test('伏笔账本提示词：只保留未回收项，已实现的直接删除', () {
    final prompt = OutlinePromptTemplate.buildLedgerPrompt(
      batchContent: '标题：旧宅第一夜\n概述：他搬进旧宅。',
      prevLedgerText: '（暂无）',
    );
    expect(prompt, contains('账本只保留**未回收**的短线伏笔'));
    expect(prompt, contains('必须能在 5 个大事件之内回收'));
    expect(prompt, contains('已经跨过 5 个大事件仍未回收的伏笔直接删除'));
    expect(prompt, contains('本批内已经回收/兑现的伏笔直接删除'));
    expect(prompt, contains('账本里不再保留已实现的伏笔'));
    // 计划回收时机仍然只写叙事阶段
    expect(prompt, contains('第一幕 / 第二幕 / 第三幕 / 终章'));
  });
}
