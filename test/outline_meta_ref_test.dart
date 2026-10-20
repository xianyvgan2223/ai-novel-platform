import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_meta_refs.dart';

/// 大纲正文里「第几章 / 第几号事件」编号引用的清理。
///
/// 用户报的问题：大纲变长后，模型会把伏笔照应写成
/// 「54与70埋的…」「90姜黎…」「52搬出宅邸第一夜…」——编号是生成过程的定位，
/// 写进大事件概述会污染后续批次与展开小事件。要求：**伏笔要么直接写出内容，
/// 要么不写编号引用**。
void main() {
  group('编号引用清理', () {
    test('用户报告的整段伏笔照应：编号全部去掉，内容保留', () {
      const bad =
          '54与70埋的“只学会一种接受方式”在此第一次被真正掰开，'
          '与90姜黎“不给他转的机会”合扣；他自己闩门那根旧铁条，'
          '52搬出宅邸第一夜“别上又拔出来”在终章重新闩上；'
          '88旧台补法失传的缺口没有补全；79与99埋的“那一场”仍欠着。';
      expect(OutlineMetaRefCleaner.hasNumberReference(bad), isTrue);

      final clean = OutlineMetaRefCleaner.clean(bad);
      for (final n in ['54', '70', '90', '52', '88', '79', '99']) {
        expect(clean, isNot(contains(n)), reason: '编号 $n 应被清掉');
      }
      // 伏笔内容本身（人物 / 旧物件 / 原话）必须保留
      expect(clean, contains('只学会一种接受方式'));
      expect(clean, contains('姜黎'));
      expect(clean, contains('不给他转的机会'));
      expect(clean, contains('别上又拔出来'));
      expect(clean, contains('旧台补法失传'));
      expect(clean, contains('那一场'));
      expect(OutlineMetaRefCleaner.hasNumberReference(clean), isFalse);
    });

    test('明确带编号标记的写法都清掉', () {
      expect(
        OutlineMetaRefCleaner.clean('第54章埋下的剑意'),
        isNot(contains('54')),
      );
      expect(OutlineMetaRefCleaner.clean('第3幕的高潮'), '这一幕的高潮');
      expect(
        OutlineMetaRefCleaner.clean('第54个事件里的伏笔'),
        isNot(contains('54')),
      );
      expect(
        OutlineMetaRefCleaner.clean('大事件54埋的旧铁条'),
        isNot(contains('54')),
      );
      expect(
        OutlineMetaRefCleaner.clean('小事件12的伏笔'),
        isNot(contains('12')),
      );
      // 「第54、70章」这种列表写法
      expect(
        OutlineMetaRefCleaner.clean('第54、70章埋的旧事'),
        isNot(contains(RegExp(r'\d'))),
      );
    });

    test('正常的时间 / 数量 / 序号词不动', () {
      const line = '他修炼30年，闯过3000人的尸潮，3天没合眼，从5楼跳下';
      expect(OutlineMetaRefCleaner.clean(line), line);

      // 带数量单位 / 序数单位时，「第N+单位」也不是编号引用
      const line2 = '第5号仓库、第3次突围、第2把刀都还在';
      expect(OutlineMetaRefCleaner.clean(line2), line2);
    });

    test('普通正文里没有「伏笔」类词时，裸数字也不乱动', () {
      const line = '敌军3人埋伏在路口，5辆车停在街边，2楼亮着灯';
      expect(OutlineMetaRefCleaner.clean(line), line);
    });

    test('标题行里的编号是格式的一部分，不能被清', () {
      const text =
          '══ 大事件54：标题 ══\n'
          '54与70埋的旧铁条在终章重新闩上。\n'
          '○ 小事件12：标题\n'
          '这段概要里不要写大事件54。';
      final cleaned = OutlineMetaRefCleaner.cleanBodyText(text);
      expect(cleaned, contains('══ 大事件54：标题 ══'));
      expect(cleaned, contains('○ 小事件12：标题'));
      expect(cleaned, isNot(contains('54与70')));
      expect(cleaned, isNot(contains('大事件54。')));
      expect(cleaned, contains('旧铁条在终章重新闩上'));
    });

    test('空文本与干净文本原样返回', () {
      expect(OutlineMetaRefCleaner.cleanBodyText(''), '');
      expect(OutlineMetaRefCleaner.clean(''), '');
      const clean = '他推开那扇门，把食盒提进去一口一口喝完。';
      expect(OutlineMetaRefCleaner.cleanBodyText(clean), clean);
      expect(OutlineMetaRefCleaner.hasNumberReference(clean), isFalse);
    });
  });
}
