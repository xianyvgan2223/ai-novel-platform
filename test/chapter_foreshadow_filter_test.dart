import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/chapter_writing/service/chapter_write_service.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_foreshadow_filter.dart';

/// 「小事件详写」写正文 / AI 审校时，已回收 / 已实现的伏笔不再注入提示词。
void main() {
  const mixed =
      '旧铁条的来历（状态：已埋 / 计划：第二幕）\n'
      '欠着的那句话（状态：已回收 / 计划：第二幕）\n'
      '续尽则断（状态：已实现 / 计划：第三幕）\n'
      '失传的补法（状态：已埋 / 计划：第三幕）';

  group('filterResolvedForeshadowText', () {
    test('去掉已回收 / 已实现 / 已兑现 / 回收完成的行，其余原样保留', () {
      final filtered = filterResolvedForeshadowText(mixed);
      expect(filtered.contains('旧铁条的来历'), isTrue);
      expect(filtered.contains('失传的补法'), isTrue);
      expect(filtered.contains('欠着的那句话'), isFalse);
      expect(filtered.contains('续尽则断'), isFalse);
    });

    test('全部已实现时返回空串（调用方据此省略整段）', () {
      expect(
        filterResolvedForeshadowText('甲（状态：已回收）\n乙（状态：已兑现）\n丙（状态：回收完成）'),
        '',
      );
    });

    test('普通文本（没有状态词）原样保留', () {
      const plain = '旧铁条：第一章埋，第三幕回收\n一句没说完的话';
      expect(filterResolvedForeshadowText(plain), plain);
    });

    test('过滤后不会留下连续多余空行', () {
      final filtered = filterResolvedForeshadowText(
        '甲（已埋）\n\n乙（已回收）\n\n\n丙（已埋）',
      );
      expect(filtered, '甲（已埋）\n\n丙（已埋）');
    });
  });

  group('章节写作提示词', () {
    OutlineRecord outline() => OutlineRecord(title: '测试小说', content: '');
    OutlineChapter chapter() => OutlineChapter(
      id: 1,
      outlineId: 1,
      eventIndex: 1,
      eventType: 'minor',
      eventTitle: '初抵炼狱',
      eventSummary: '顾泽在城郊醒来。',
    );

    test('写正文只注入未回收的伏笔', () {
      final prompt = ChapterWritePromptTemplate.buildWritePrompt(
        outline: outline(),
        outlineExcerpt: '大纲片段',
        ch: chapter(),
        prevContent: '前文',
        foreshadows: mixed,
      );
      expect(prompt, contains('【伏笔清单】'));
      expect(prompt, contains('旧铁条的来历'));
      expect(prompt, contains('失传的补法'));
      expect(prompt, isNot(contains('欠着的那句话')));
      expect(prompt, isNot(contains('续尽则断')));
    });

    test('伏笔全部已实现时，写正文提示词不再出现【伏笔清单】段', () {
      final prompt = ChapterWritePromptTemplate.buildWritePrompt(
        outline: outline(),
        outlineExcerpt: '大纲片段',
        ch: chapter(),
        prevContent: '前文',
        foreshadows: '甲（状态：已回收）\n乙（状态：已实现）',
      );
      // 要求里会提到「【伏笔清单】」这个词，但清单段落本身不应再出现
      expect(prompt, isNot(contains('\n\n【伏笔清单】\n')));
    });

    test('AI 审校提示词同样只保留未回收的伏笔', () {
      final messages = ChapterWriteService().buildReviewMessages(
        eventTitle: '初抵炼狱',
        eventSummary: '顾泽在城郊醒来。',
        prevEnding: '上一章结尾',
        storyState: '剧情状态',
        characters: '人物档案',
        foreshadows: mixed,
        chapterContent: '正文内容',
      );
      final user = messages.last['content'] as String;
      expect(user, contains('【伏笔清单】'));
      expect(user, contains('旧铁条的来历'));
      expect(user, isNot(contains('欠着的那句话')));
      expect(user, isNot(contains('续尽则断')));
    });
  });
}
