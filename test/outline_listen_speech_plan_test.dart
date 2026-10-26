import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/model/listening_segment.dart';

/// 句子级朗读计划：把事件文本切成「逐句可读 / 可高亮 / 可拖动定位」的片段。
///
/// 这一层是「逐句朗读」的地基：切句错一位，高亮就会盖住半个字；
/// 偏移错一位，拖进度条定位到的句子就会差一句。因此这里全部按**原文偏移**
/// 断言（`substring(start, end)` 必须正好是那一句），而不是只看文本内容。
///
/// 一律直接构造 [OutlineListenSegment]，不碰数据库 / 引擎：
/// [buildSpeechPlan] 是纯函数，输入事件与朗读模式，输出计划。
void main() {
  OutlineListenSegment seg({
    int eventIndex = 1,
    bool isMajor = true,
    int? majorNumber = 1,
    int? minorNumber,
    String title = '初入江湖',
    String summary = '',
    String content = '',
  }) => OutlineListenSegment(
    chapterId: 0,
    eventIndex: eventIndex,
    isMajor: isMajor,
    majorNumber: isMajor ? (majorNumber ?? 1) : null,
    minorNumber: isMajor ? null : (minorNumber ?? 1),
    title: title,
    summary: summary,
    content: content,
  );

  /// 断言一个片段的偏移确实落在它的原文上（头尾没有空白）。
  void expectRangeOnSource(
    String source,
    SpeechPiece piece, {
    required String part,
  }) {
    expect(
      piece.start,
      greaterThanOrEqualTo(0),
      reason: '$part 片段起点不能为负',
    );
    expect(piece.end, lessThanOrEqualTo(source.length), reason: '$part 片段终点越界');
    final raw = source.substring(piece.start, piece.end);
    expect(raw.trim(), piece.text, reason: '$part 片段偏移与文本对不上');
    if (raw.isNotEmpty) {
      expect(raw.trimLeft(), raw, reason: '$part 片段开头不应带空白');
      expect(raw.trimRight(), raw, reason: '$part 片段结尾不应带空白');
    }
  }

  group('splitSentenceRanges · 基本切句', () {
    test('空文本返回空列表', () {
      expect(splitSentenceRanges(''), isEmpty);
      // 纯空白也不该切出「只有空白」的句子
      expect(splitSentenceRanges('   \n  '), isEmpty);
    });

    test('句末标点处断开，标点留在本句末尾', () {
      const text = '第一句。第二句！';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      expect(text.substring(ranges[0].start, ranges[0].end), '第一句。');
      expect(text.substring(ranges[1].start, ranges[1].end), '第二句！');
    });

    test('问号 / 分号 / 省略号 / 换行同样断句', () {
      const text = '甲？乙；丙…丁\n戊';
      final ranges = splitSentenceRanges(text);
      expect(ranges.map((r) => text.substring(r.start, r.end)), [
        '甲？',
        '乙；',
        '丙…',
        '丁',
        '戊',
      ]);
    });

    test('句末的闭引号 / 括号并入本句，不会被切到下句开头', () {
      const text = '“走吧。”他说。';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      expect(text.substring(ranges[0].start, ranges[0].end), '“走吧。”');
      expect(text.substring(ranges[1].start, ranges[1].end), '他说。');
    });

    test('末尾没有句末标点的残句也算一句', () {
      const text = '第一句。第二轮';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      expect(text.substring(ranges[1].start, ranges[1].end), '第二轮');
    });

    test('偏移已去掉首尾空白（可直接用于 TextRange 高亮）', () {
      const text = '  甲。  ';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 1);
      expect(ranges.single.start, 2);
      expect(ranges.single.end, 4);
      expect(text.substring(ranges.single.start, ranges.single.end), '甲。');
    });
  });

  group('splitSentenceRanges · 超长句再切短', () {
    test('超过上限时优先在逗号 / 顿号处切，不硬切在字中间', () {
      // 40 字 + 逗号 + 40 字 + 句号 = 82 字，超过默认 80 字上限
      final text = '${'甲' * 40}，${'乙' * 40}。';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      expect(ranges[0].end - ranges[0].start, 41);
      expect(text.substring(ranges[0].start, ranges[0].end), endsWith('，'));
      expect(
        text.substring(ranges[1].start, ranges[1].end),
        '${'乙' * 40}。',
      );
    });

    test('没有可切标点时按上限硬切', () {
      final text = '甲' * 100;
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      expect(ranges[0].end - ranges[0].start, 80);
      expect(ranges[1].end - ranges[1].start, 20);
      expect(text.substring(ranges[0].start, ranges[0].end), '甲' * 80);
    });

    test('maxLength 可调（测试用小上限验证规则）', () {
      const text = '甲乙丙丁戊';
      final ranges = splitSentenceRanges(text, maxLength: 2);
      expect(
        ranges.map((r) => text.substring(r.start, r.end)),
        ['甲乙', '丙丁', '戊'],
      );
    });

    test('不会把代理对（emoji / 扩展字）劈成两半', () {
      // 79 个汉字 + 😀（占 2 个 code unit）+ 5 字 = 86 > 80
      final text = '${'甲' * 79}😀${'乙' * 5}';
      final ranges = splitSentenceRanges(text);
      expect(ranges.length, 2);
      // 硬切位置原本落在 80，正好是 emoji 的低代理项：必须回退到 79
      expect(ranges[0].end, 79);
      expect(ranges[1].start, 79);
      final second = text.substring(ranges[1].start, ranges[1].end);
      expect(second, contains('😀'));
      // 第二段第一个 code unit 必须是 emoji 的高代理项（不是孤立的低代理项）
      expect(second.codeUnitAt(0), 0xD83D);
    });
  });

  group('buildSpeechPlan · 朗读范围', () {
    test('只读标题：计划里只有标题一句，概要 / 正文都不读', () {
      final plan = buildSpeechPlan(
        seg(
          title: '初入江湖',
          summary: '李云飞在青阳城醒来。\n他失去了记忆。',
          content: '正文一段。',
        ),
        OutlineListenMode.titleOnly,
      );

      expect(plan.length, 1);
      final piece = plan.pieces.single;
      expect(piece.part, SpeechPiecePart.title);
      // 标题整段一起高亮：区间覆盖整个标题输入框
      expect(piece.start, 0);
      expect(piece.end, '初入江湖'.length);
      // 类型标签用逗号与标题断开（语音才听得出「第 1 个大事件」）
      expect(piece.text, '大事件1，初入江湖');
    });

    test('标题 + 概要：标题一句 + 概要逐句，顺序不变', () {
      final plan = buildSpeechPlan(
        seg(
          title: '初入江湖',
          summary: '李云飞在青阳城醒来。\n他失去了记忆。',
          content: '正文一段。',
        ),
        OutlineListenMode.titleAndSummary,
      );

      expect(plan.length, 3);
      expect(plan.pieces.map((p) => p.part), [
        SpeechPiecePart.title,
        SpeechPiecePart.summary,
        SpeechPiecePart.summary,
      ]);
      expect(plan.pieces[1].text, '李云飞在青阳城醒来。');
      expect(plan.pieces[2].text, '他失去了记忆。');
      // 概要不读正文
      expect(plan.pieces.any((p) => p.part == SpeechPiecePart.content), isFalse);
    });

    test('标题 + 概要 + 正文：含「正文」提示词，正文逐句', () {
      final plan = buildSpeechPlan(
        seg(
          title: '初入江湖',
          summary: '甲。',
          content: '正文一段。第二段。',
        ),
        OutlineListenMode.full,
      );

      expect(plan.pieces.map((p) => p.part), [
        SpeechPiecePart.title,
        SpeechPiecePart.summary,
        SpeechPiecePart.content, // 「正文」提示词
        SpeechPiecePart.content,
        SpeechPiecePart.content,
      ]);
      // 提示词是纯提示、不指向原文任何区间
      final marker = plan.pieces[2];
      expect(marker.text, '正文');
      expect(marker.start, 0);
      expect(marker.end, 0);
      expect(plan.pieces[3].text, '正文一段。');
      expect(plan.pieces[4].text, '第二段。');
    });

    test('标题为空时跳过标题句（不会读成「大事件1，」）', () {
      final plan = buildSpeechPlan(
        seg(title: '', summary: '甲。'),
        OutlineListenMode.titleAndSummary,
      );

      expect(plan.length, 1);
      expect(plan.pieces.single.part, SpeechPiecePart.summary);
      expect(plan.pieces.single.text, '甲。');
    });

    test('正文为空时 full 模式也不加「正文」提示词', () {
      final plan = buildSpeechPlan(
        seg(title: '标题', summary: '甲。', content: '   '),
        OutlineListenMode.full,
      );

      expect(plan.pieces.any((p) => p.part == SpeechPiecePart.content), isFalse);
      expect(plan.length, 2);
    });

    test('概要 / 正文的偏移与原文可以 substring 对齐（高亮与拖动定位靠它）', () {
      final segment = seg(
        title: '初入江湖',
        summary: '  李云飞在青阳城醒来。\n\n他失去了记忆。  ',
        content: '  正文第一句；正文第二句！  ',
      );
      final plan = buildSpeechPlan(segment, OutlineListenMode.full);
      final summarySource = segment.summaryCtrl.text;
      final contentSource = segment.content;

      for (final piece in plan.pieces) {
        switch (piece.part) {
          case SpeechPiecePart.title:
            expect(piece.text, '${segment.typeLabel}，${segment.title}');
            break;
          case SpeechPiecePart.summary:
            expectRangeOnSource(summarySource, piece, part: '概要');
            break;
          case SpeechPiecePart.content:
            if (piece.start == 0 && piece.end == 0 && piece.text == '正文') {
              break; // 提示词
            }
            expectRangeOnSource(contentSource, piece, part: '正文');
            break;
        }
      }

      // 空行 / 首尾空白不该变成一句「空白朗读」
      expect(
        plan.pieces
            .where((p) => p.part == SpeechPiecePart.summary)
            .map((p) => p.text),
        ['李云飞在青阳城醒来。', '他失去了记忆。'],
      );
    });

    test('多行概要的每一行都单独成句（拖进度条能一句一句定位）', () {
      final plan = buildSpeechPlan(
        seg(summary: '第一行。\n第二行。\n第三行。'),
        OutlineListenMode.titleAndSummary,
      );
      expect(
        plan.pieces.map((p) => p.text),
        ['大事件1，初入江湖', '第一行。', '第二行。', '第三行。'],
      );
    });
  });

  group('SpeechPlan / SpeechPiece 基础行为', () {
    test('空计划：length 为 0、isEmpty、任何下标都取不到片段', () {
      const plan = SpeechPlan.empty;
      expect(plan.length, 0);
      expect(plan.isEmpty, isTrue);
      expect(plan.pieceAt(0), isNull);
      expect(plan.pieceAt(-1), isNull);
    });

    test('pieceAt 越界返回 null，合法下标返回对应片段', () {
      final plan = buildSpeechPlan(
        seg(summary: '甲。乙。'),
        OutlineListenMode.titleAndSummary,
      );
      expect(plan.pieceAt(0)!.text, '大事件1，初入江湖');
      expect(plan.pieceAt(2)!.text, '乙。');
      expect(plan.pieceAt(3), isNull);
      expect(plan.pieceAt(-1), isNull);
    });

    test('小事件用「小事件N」做类型标签（不是 eventIndex）', () {
      final segment = seg(
        eventIndex: 5,
        isMajor: false,
        minorNumber: 2,
        title: '拜师',
        summary: '甲。',
      );
      final plan = buildSpeechPlan(segment, OutlineListenMode.titleOnly);
      expect(plan.pieces.single.text, '小事件2，拜师');
    });
  });
}
