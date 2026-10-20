import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_chunk_normalizer.dart';

/// 展开块归一化：以骨架为准合成最终内容。
///
/// 用户报的问题：「生成小事件时，有时候没有把大事件的全部内容包括到」。
/// 旧逻辑把模型输出整段（含它重写/压缩的大事件概述）原样落库，模型少写一条
/// 大事件时还会编号错位、整条消失。现在大事件标题/概述一律取骨架，模型只提供
/// 小事件部分，缺块也会补上概述。
void main() {
  group('展开块归一化（以骨架为准）', () {
    test('大事件概述逐字保留骨架版本，模型重写的概述/开场白不进入正文', () {
      const summary =
          '骨架里的精写概述：顾泽把药喝完。\n'
          '第二段有细节：旧铁条、姜黎那句没接的话、欠着的那一场。';
      final result = OutlineChunkNormalizer.normalize(
        expected: [(title: '把药喝完', summary: summary)],
        modelText:
            '好的，遵照您的指示，我将展开大事件1。\n'
            '══ 大事件1：把药喝完 ══\n'
            '模型自己重写的概述（更短，还漏了内容）。\n'
            '○ 小事件1：门槛上的一夜\n顾泽坐在门槛上没动。\n'
            '○ 小事件2：仓库区最后一战\n他空着手往外走。',
      )!;

      expect(result, hasLength(1));
      expect(result.first.summary, summary); // 逐字保留（含换行）
      expect(result.first.title, '把药喝完');
      expect(result.first.minorsBody, contains('○ 小事件1：门槛上的一夜'));
      expect(result.first.minorsBody, contains('顾泽坐在门槛上没动。'));
      // 模型重写的概述、开场白、markdown 大事件标题都不进正文
      expect(result.first.minorsBody, isNot(contains('模型自己重写')));
      expect(result.first.minorsBody, isNot(contains('遵照您的指示')));
      expect(result.first.minorsBody, isNot(contains('══ 大事件1')));
    });

    test('模型少输出一条大事件：缺的也补上骨架标题 + 完整概述（一条不少）', () {
      final result = OutlineChunkNormalizer.normalize(
        expected: [
          (title: '旧宅第一夜', summary: '概述A'),
          (title: '把药喝完', summary: '概述B'),
        ],
        // 模型只输出了第二个大事件
        modelText: '══ 大事件2：把药喝完 ══\n○ 小事件1：收尾\n喝完了。\n',
      )!;

      expect(result.map((e) => e.position), [0, 1]);
      expect(result.map((e) => e.title), ['旧宅第一夜', '把药喝完']);
      expect(result.map((e) => e.summary), ['概述A', '概述B']);
      expect(result.first.minorsBody, isEmpty); // 缺块：只有概述，内容不丢
      expect(result.last.minorsBody, contains('喝完了。'));
    });

    test('标题被模型轻微改写：位置照填，标题/概述仍用骨架的', () {
      final result = OutlineChunkNormalizer.normalize(
        expected: [
          (title: '旧宅第一夜', summary: '概述A'),
          (title: '把药喝完', summary: '概述B'),
        ],
        modelText:
            '══ 大事件1：旧宅第一夜（改） ══\n○ 小事件1：门\n门闩上了。\n'
            '══ 大事件2：把药喝完 ══\n○ 小事件1：药\n喝完了。\n',
      )!;

      expect(result, hasLength(2));
      expect(result[0].title, '旧宅第一夜');
      expect(result[0].summary, '概述A');
      expect(result[0].minorsBody, contains('门闩上了。'));
      expect(result[1].minorsBody, contains('喝完了。'));
    });

    test('跨块回显：前面块已输出过的标题不再重复取用', () {
      final result = OutlineChunkNormalizer.normalize(
        expected: [(title: '把药喝完', summary: '概述B')],
        alreadySeenTitles: ['旧宅第一夜'],
        modelText:
            '══ 大事件1：旧宅第一夜 ══\n○ 小事件9：回显\n不该出现。\n'
            '══ 大事件2：把药喝完 ══\n○ 小事件1：收尾\n喝完了。\n',
      )!;

      expect(result, hasLength(1));
      expect(result.first.title, '把药喝完');
      expect(result.first.minorsBody, contains('喝完了。'));
      expect(result.first.minorsBody, isNot(contains('不该出现')));
    });

    test('模型输出完全切不出大事件块时返回 null（调用方保留原文）', () {
      final result = OutlineChunkNormalizer.normalize(
        expected: [(title: 'A', summary: '概述A')],
        modelText: '这里只有一段普通文字，没有任何事件标题。',
      );
      expect(result, isNull);
    });

    test('标题归一化键：去空白与结尾标点', () {
      expect(
        OutlineChunkNormalizer.titleKey('  旧宅第一夜： '),
        OutlineChunkNormalizer.titleKey('旧宅第一夜'),
      );
    });
  });
}
