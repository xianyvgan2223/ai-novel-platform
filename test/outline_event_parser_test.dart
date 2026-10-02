import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_syntax.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_text_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实大纲片段：第 9、10、11 个大事件的交界处（取自「天下第一尸兄世界」）。
/// 修复前：10、11 的标题行被整行丢弃，其小事件被挂到「企鹅变异」名下，
/// 大事件概述被粘到上一条小事件上。
final String _kPenguinSnippet = [
  '══ 大事件9：企鹅变异 ══',
  '大事件概述：三人带老人穿越小区时，遭遇从动物园逃出的变异巨型企鹅群。',
  '',
  '○ 小事件1：动物园来客',
  '五只近两米高的巨型企鹅从广场另一侧涌出。',
  '',
  '○ 小事件4：扫帚与夕照',
  '他们在商铺后间里躲了整整一个下午。',
  '',
  '══ 大事件10：公园兔潮 ══',
  '大事件概述：三人为避开街道上的尸兄群，决定横穿中央公园抄近路。',
  '',
  '○ 小事件1：售票亭的约定',
  '老人脚踝的伤还没好，决定留在售票亭等他们回来。',
  '',
  '○ 小事件4：地下车库的星星',
  '他们冲出公园北门时，天色已经彻底黑透。',
  '',
  '══ 大事件11：血莲教现身 ══',
  '大事件概述：地下车库度过一夜后，顾泽带着小惠和小鹿向安全区转移。',
  '',
  '○ 小事件1：逃亡者口中的血莲教',
  '他们迎面撞上一群衣衫褴褛的难民。',
].join('\n');

void main() {
  group('parseOutlineEvents 事件识别', () {
    test('多位编号的大事件不再被吞掉（回归：编号曾只允许一位）', () {
      final events = parseOutlineEvents(_kPenguinSnippet, outlineId: 1);

      expect(events.map((e) => e.eventType).toList(), [
        'major', 'minor', 'minor', // 企鹅变异
        'major', 'minor', 'minor', // 公园兔潮（两位数编号）
        'major', 'minor', // 血莲教现身（两位数编号）
      ]);
      expect(events.map((e) => e.eventTitle).toList(), [
        '企鹅变异',
        '动物园来客',
        '扫帚与夕照',
        '公园兔潮',
        '售票亭的约定',
        '地下车库的星星',
        '血莲教现身',
        '逃亡者口中的血莲教',
      ]);
      // 序号连续，且每个小事件都排在它所属的大事件之后
      expect(events.map((e) => e.eventIndex).toList(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
    });

    test('大事件概述归属正确：不会被粘到上一条小事件上', () {
      final events = parseOutlineEvents(_kPenguinSnippet, outlineId: 1);

      expect(events[3].eventSummary, contains('中央公园'));
      expect(events[2].eventSummary, isNot(contains('中央公园')));
      expect(events[6].eventSummary, contains('安全区'));
      expect(events[5].eventSummary, isNot(contains('安全区')));
    });

    test('容忍 markdown 前缀（## / ###）', () {
      final content = [
        '## ══ 大事件28：小惠养伤 ══',
        '大事件概述：小惠在药房里醒来。',
        '',
        '### ○ 小事件1：药房里的烛火',
        '她睁眼时，闻到了碘伏的味道。',
        '',
        '### ══ 大事件29：唯欣告白 ══',
        '大事件概述：唯欣在屋顶说出了心里话。',
      ].join('\n');

      final events = parseOutlineEvents(content, outlineId: 1);
      expect(events.map((e) => e.eventTitle).toList(), [
        '小惠养伤',
        '药房里的烛火',
        '唯欣告白',
      ]);
      expect(events.map((e) => e.eventType).toList(), [
        'major',
        'minor',
        'major',
      ]);
    });

    test('没有 ══ 包裹的多位编号标题行同样被识别', () {
      final content = [
        '大事件10：黑小飞诞生',
        '概述：黑小飞在尸巢中诞生。',
        '小事件1：第一声啼哭',
        '那声音穿透了整片废墟。',
      ].join('\n');

      final events = parseOutlineEvents(content, outlineId: 1);
      expect(events.length, 2);
      expect(events[0].eventTitle, '黑小飞诞生');
      expect(events[0].eventType, 'major');
    });

    test('小事件编号支持多位 / X 占位符 / 事件前缀', () {
      final content = [
        '大事件X：占位标题',
        '○ 小事件10：第十个小事件',
        '内容',
        '事件11：直接以事件开头',
        '内容',
      ].join('\n');

      final events = parseOutlineEvents(content, outlineId: 1);
      expect(events.map((e) => e.eventTitle).toList(), [
        '占位标题',
        '第十个小事件',
        '直接以事件开头',
      ]);
    });

    test('幕标题不会并入上一事件的概要', () {
      final content = [
        '══ 大事件10：公园兔潮 ══',
        '大事件概述：横穿中央公园。',
        '',
        '══ 第二幕：发展 ══',
        '',
        '○ 小事件1：售票亭的约定',
        '老人决定留下。',
      ].join('\n');

      final events = parseOutlineEvents(content, outlineId: 1);
      expect(events[0].eventSummary, isNot(contains('第二幕')));
      expect(events[0].eventSummary, contains('中央公园'));
    });

    test('解析不到事件时回退为单个「正文」大事件', () {
      final events = parseOutlineEvents('只有一些说明文字\n第二行说明', outlineId: 7);
      expect(events.length, 1);
      expect(events.single.eventTitle, '正文');
      expect(events.single.eventType, 'major');
    });
  });

  group('classifyOutlineLine 行识别', () {
    test('「大事件概述：」「小事件概述：」不会被当成事件标题', () {
      for (final raw in [
        '大事件概述：三人为了避开街道上的尸兄群',
        '小事件概述：这里是说明',
        '大事件概述',
        '第一幕：开端',
        '══ 第二幕：发展 ══',
      ]) {
        expect(classifyOutlineLine(raw).isEvent, isFalse, reason: raw);
      }
      expect(classifyOutlineLine('第一幕：开端').isAct, isTrue);
      expect(classifyOutlineLine('══ 第二幕：发展 ══').isAct, isTrue);
    });

    test('事件行判定顺序：先大事件，再小事件', () {
      expect(classifyOutlineLine('══ 大事件9：企鹅变异 ══').isMajor, isTrue);
      expect(classifyOutlineLine('○ 小事件1：动物园来客').isMinor, isTrue);
      expect(classifyOutlineLine('### ○ 小事件2：心痕').isMinor, isTrue);
      expect(classifyOutlineLine('══ 大事件10：公园兔潮 ══').isMajor, isTrue);
      expect(classifyOutlineLine('大事件138：一体同人').isMajor, isTrue);
    });

    test('边界判定覆盖裸标题与 markdown 标题（写回时不能吃掉它们）', () {
      for (final raw in [
        '══ 大事件10：公园兔潮 ══',
        '大事件10：公园兔潮',
        '## ══ 大事件28：小惠养伤 ══',
        '○ 小事件1：售票亭的约定',
        '### ○ 小事件2：心痕',
        '- 小事件3：某条',
        '══ 第二幕：发展 ══',
      ]) {
        expect(isOutlineBoundaryLine(raw), isTrue, reason: raw);
      }
      expect(isOutlineBoundaryLine('普通概要文字'), isFalse);
      expect(isOutlineBoundaryLine('   '), isFalse);
    });

    test('粗体包裹的事件行能被识别（真实漏读主因：○ **小事件1：标题**）', () {
      final input = [
        '### ══ 大事件28：小惠养伤 ══',
        '',
        '**大事件概述**：顾泽从工业区归来后，左臂的刀伤还没好。',
        '',
        '○ **小事件1：归来的伤口**',
        '顾泽推开指挥所临时医务室的门。',
        '',
        '○ **小事件2：指挥所的清晨**',
        '天亮后，指挥所外传来士兵跑操的脚步声。',
      ].join('\n');

      final events = parseOutlineEvents(input, outlineId: 19);
      expect(events.map((e) => e.eventTitle).toList(), [
        '小惠养伤',
        '归来的伤口',
        '指挥所的清晨',
      ]);
      expect(events.map((e) => e.eventType).toList(), [
        'major',
        'minor',
        'minor',
      ]);
      // 「**大事件概述**：」不是事件，必须归到上一个大事件的概要里
      expect(events[0].eventSummary, contains('左臂的刀伤'));
    });

    test('其它真实变体：**大事件**、**══ ══**、=== ===', () {
      expect(classifyOutlineLine('**大事件1：穿越异世**').isMajor, isTrue);
      expect(classifyOutlineLine('**大事件1：穿越异世**').title, '穿越异世');
      expect(classifyOutlineLine('**══ 大事件19：黑白小飞汇合 ══**').title, '黑白小飞汇合');
      expect(classifyOutlineLine('=== 大事件97：石井四郎现身 ===').title, '石井四郎现身');
      expect(classifyOutlineLine('○ **小事件3：战情通报会**').title, '战情通报会');
    });

    test('说明性文字不会被误判成事件', () {
      for (final raw in [
        '**小事件概要 (120字)：**',
        '- 第13个事件：在休息中，唯欣身上未解的禁制再次产生轻微波动。',
        '=== 下一块大事件预告（第13–14个事件） ===',
        '好的，遵照您的指示，我将承接前文“大事件27：高阶尸兄战”的结尾。',
        '**大事件概述**：顾泽从工业区归来后，因左臂的刀伤和连日奔波。',
      ]) {
        expect(classifyOutlineLine(raw).isEvent, isFalse, reason: raw);
      }
    });
  });

  group('removeEventFromOutlineText 删真实大纲里的中间一条', () {
    test('删「售票亭的约定」：前后的大事件与其他小事件逐条不变', () {
      final out = removeEventFromOutlineText(
        _kPenguinSnippet,
        5, // 公园兔潮名下的第一个小事件
        expectTitles: const ['售票亭的约定'],
        expectMajor: false,
      );
      final events = parseOutlineEvents(out, outlineId: 1);

      expect(events.map((e) => e.eventTitle).toList(), [
        '企鹅变异',
        '动物园来客',
        '扫帚与夕照',
        '公园兔潮',
        '地下车库的星星',
        '血莲教现身',
        '逃亡者口中的血莲教',
      ]);
      // 大事件概述仍归它自己的大事件（没被并进上一条小事件）
      expect(events[3].eventSummary, contains('中央公园'));
      expect(events[2].eventSummary, isNot(contains('中央公园')));
      expect(events[5].eventSummary, contains('安全区'));
      expect(events[4].eventSummary, isNot(contains('安全区')));
      // 全篇只剩 7 条，且删掉的那一条不再出现在正文里
      expect(events.length, 7);
      expect(out.contains('售票亭的约定'), isFalse);
    });
  });

  group('mergeEventIntoOutlineText 写回', () {
    test('按事件序号定位：同名事件不会改错行', () {
      final content = [
        '══ 大事件1：甲 ══',
        '概述A',
        '',
        '○ 小事件4：以点破面',
        '第一个',
        '',
        '○ 小事件2：乙',
        '中间',
        '',
        '○ 小事件4：以点破面',
        '第二个',
      ].join('\n');

      final out = mergeEventIntoOutlineText(
        content,
        oldTitle: '以点破面',
        newTitle: '以点破面（改）',
        newSummary: '新概要',
        eventIndex: 4, // 第二个「以点破面」
      );

      final lines = out.split('\n');
      final firstIdx = lines.indexWhere(
        (l) => l.contains('以点破面') && !l.contains('（改）'),
      );
      expect(firstIdx, greaterThan(0));
      expect(lines[firstIdx + 1], '第一个'); // 第一个仍是原文
      expect(out.contains('以点破面（改）'), isTrue);
      expect(out.contains('新概要'), isTrue);
      expect(out.contains('第二个'), isFalse);
    });

    test('概要区边界不会吃掉下一行标题（裸标题 / markdown 标题）', () {
      final content = [
        '大事件10：黑小飞诞生',
        '旧概述',
        '大事件11：尸巢决战前夜',
        '第二段概述',
        '## ══ 大事件28：小惠养伤 ══',
        '第三段概述',
      ].join('\n');

      final out = mergeEventIntoOutlineText(
        content,
        oldTitle: '黑小飞诞生',
        newTitle: '黑小飞诞生',
        newSummary: '新的概述',
        eventIndex: 1,
      );

      // 这两行标题绝不能被当成概要内容替换掉（旧实现在这里删数据）
      expect(out.contains('大事件11：尸巢决战前夜'), isTrue);
      expect(out.contains('第二段概述'), isTrue);
      expect(out.contains('## ══ 大事件28：小惠养伤 ══'), isTrue);
      expect(out.contains('第三段概述'), isTrue);
      expect(out.contains('旧概述'), isFalse);
      expect(out.contains('新的概述'), isTrue);
    });

    test('概要置空会清掉概要区但保留事件行', () {
      final content = ['══ 大事件1：甲 ══', '旧概述', '', '○ 小事件1：乙', '正文'].join('\n');

      final out = mergeEventIntoOutlineText(
        content,
        oldTitle: '甲',
        newTitle: '甲',
        newSummary: '',
        eventIndex: 1,
      );

      expect(out.contains('旧概述'), isFalse);
      expect(out.contains('══ 大事件1：甲 ══'), isTrue);
      expect(out.contains('○ 小事件1：乙'), isTrue);
      expect(out.contains('正文'), isTrue);
    });

    test('找不到对应事件时原样返回', () {
      const content = '══ 大事件1：甲 ══\n概述';
      expect(
        mergeEventIntoOutlineText(
          content,
          oldTitle: '不存在的事件',
          newTitle: 'x',
          newSummary: 'y',
          eventIndex: 1,
        ),
        content,
      );
      expect(
        mergeEventIntoOutlineText(
          content,
          oldTitle: '',
          newTitle: 'x',
          newSummary: 'y',
        ),
        content,
      );
    });
  });

  group('normalizeOutlineText 生成侧格式统一', () {
    test('══ / 裸标题 / markdown 三种形态统一为规范写法', () {
      final input = [
        '书名：《测试》',
        '',
        '══ 大事件9：企鹅变异 ══',
        '概述A',
        '大事件10：公园兔潮',
        '概述B',
        '## ══ 大事件28：小惠养伤 ══',
        '概述C',
      ].join('\n');

      final out = normalizeOutlineText(input);

      // 按位置重新编号 → 1、2、3，且统一为 ══ 包裹
      expect(out.contains('══ 大事件1：企鹅变异 ══'), isTrue);
      expect(out.contains('══ 大事件2：公园兔潮 ══'), isTrue);
      expect(out.contains('══ 大事件3：小惠养伤 ══'), isTrue);
      expect(out.contains('#'), isFalse);
      // 概要与书名原样保留
      expect(out.contains('书名：《测试》'), isTrue);
      expect(out.contains('概述A'), isTrue);
      expect(out.contains('概述B'), isTrue);
      expect(out.contains('概述C'), isTrue);
    });

    test('跳号与重号被压成连续编号', () {
      final input = [
        '══ 大事件5：甲 ══',
        '概述',
        '══ 大事件7：乙 ══',
        '概述',
        '══ 大事件3：丙 ══',
        '概述',
      ].join('\n');

      final out = normalizeOutlineText(input);
      final numbers = RegExp(
        r'大事件(\d+)：',
      ).allMatches(out).map((m) => m.group(1)).toList();
      expect(numbers, ['1', '2', '3']);
    });

    test('小事件在每个大事件内部从 1 重新编号', () {
      final input = [
        '大事件1：甲',
        '○ 小事件4：一',
        '内容',
        '○ 小事件5：二',
        '内容',
        '大事件2：乙',
        '### ○ 小事件3：三',
        '内容',
      ].join('\n');

      final out = normalizeOutlineText(input);
      expect(out.contains('○ 小事件1：一'), isTrue);
      expect(out.contains('○ 小事件2：二'), isTrue);
      expect(out.contains('○ 小事件1：三'), isTrue);
      expect(out.contains('###'), isFalse);
    });

    test('标题里嵌套的事件前缀被剥掉', () {
      final input = [
        '══ 大事件13：大事件14：唯欣苏醒 ══',
        '概述',
        '══ 大事件14：大事件15：黑火线绑架 ══',
        '概述',
      ].join('\n');

      final out = normalizeOutlineText(input);
      expect(out.contains('══ 大事件1：唯欣苏醒 ══'), isTrue);
      expect(out.contains('══ 大事件2：黑火线绑架 ══'), isTrue);
    });

    test('幕标题规范化但不凭空添加冒号', () {
      final input = [
        '### 第一幕：开端',
        '大事件1：甲',
        '概述',
        '# 第三幕（高潮&结局）详细展开',
        '大事件2：乙',
        '概述',
      ].join('\n');

      final out = normalizeOutlineText(input);
      expect(out.contains('══ 第一幕：开端 ══'), isTrue);
      // 原来没有冒号的写法必须原样保留
      expect(out.contains('══ 第三幕（高潮&结局）详细展开 ══'), isTrue);
      expect(out.contains('第三幕：'), isFalse);
    });

    test('X 占位符与 markdown 幕标题被规范化', () {
      final input = ['## 第二幕：发展', '大事件X：占位标题', '概述'].join('\n');

      final out = normalizeOutlineText(input);
      expect(out.contains('══ 第二幕：发展 ══'), isTrue);
      expect(out.contains('══ 大事件1：占位标题 ══'), isTrue);
    });

    test('概要正文逐字节保留（只动标题行）', () {
      final input = [
        '══ 大事件9：甲 ══',
        '第一段概要',
        '',
        '第二段概要，含 - 短横线与 # 井号',
        '○ 小事件1：乙',
        '正文一行',
        '正文二行',
      ].join('\n');

      final out = normalizeOutlineText(input);
      List<String> bodyLines(String text) => text
          .split('\n')
          .where((l) => !classifyOutlineLine(l).isEvent)
          .toList();
      expect(bodyLines(out), bodyLines(input));
    });

    test('幂等：再执行一次结果完全相同', () {
      final input = [
        '## ══ 大事件28：小惠养伤 ══',
        '概述',
        '### ○ 小事件2：药房',
        '正文',
      ].join('\n');

      final once = normalizeOutlineText(input);
      expect(normalizeOutlineText(once), once);
      expect(normalizeOutlineText(once), same(once));
    });

    test('识别不到事件时原样返回（绝不改写普通文本）', () {
      const plain = '这是一段普通说明\n- 列表项\n大事件概述：不是标题行\n第二行';
      expect(normalizeOutlineText(plain), plain);
    });

    test('规范化不改变解析出的事件结构', () {
      final input = [
        '══ 大事件9：企鹅变异 ══',
        '概述A',
        '○ 小事件1：动物园来客',
        '正文',
        '## ══ 大事件28：小惠养伤 ══',
        '概述B',
        '### ○ 小事件2：心痕',
        '正文',
      ].join('\n');

      List<String> shape(String text) => parseOutlineEvents(
        text,
        outlineId: 1,
      ).map((e) => '${e.eventType}|${e.eventTitle}').toList();

      expect(shape(normalizeOutlineText(input)), shape(input));
      expect(
        parseOutlineEvents(
          normalizeOutlineText(input),
          outlineId: 1,
        )[0].eventSummary,
        '概述A',
      );
    });

    test('规范化覆盖小事件：粗体被剥掉、每个大事件内从 1 重新编号', () {
      final input = [
        '### ══ 大事件28：小惠养伤 ══',
        '**大事件概述**：顾泽从工业区归来后。',
        '○ **小事件4：归来的伤口**',
        '正文A',
        '○ **小事件5：指挥所的清晨**',
        '正文B',
        '### ══ 大事件29：唯欣告白 ══',
        '○ **小事件3：地图上的红圈**',
        '正文C',
      ].join('\n');

      final lines = normalizeOutlineText(input).split('\n');
      expect(lines.contains('══ 大事件1：小惠养伤 ══'), isTrue);
      expect(lines.contains('○ 小事件1：归来的伤口'), isTrue);
      expect(lines.contains('○ 小事件2：指挥所的清晨'), isTrue);
      expect(lines.contains('══ 大事件2：唯欣告白 ══'), isTrue);
      // 换了大事件后小事件重新从 1 开始
      expect(lines.contains('○ 小事件1：地图上的红圈'), isTrue);
      // 只保证「标题行」没有粗体残留；「**大事件概述**：」属于概要与正文，
      // 按约定原样保留（规范化只重写标题行）
      expect(
        lines.where(isOutlineEventHeader).any((l) => l.contains('*')),
        isFalse,
      );
    });

    test('分块阶段只统一小事件写法，大事件编号保持不变', () {
      final input = [
        '══ 大事件28：小惠养伤 ══',
        '**大事件概述**：x',
        '○ **小事件4：归来的伤口**',
        '正文A',
        '══ 大事件29：唯欣告白 ══',
        '○ **小事件2：地图上的红圈**',
        '正文C',
      ].join('\n');

      final lines = normalizeMinorHeaders(input).split('\n');
      // 大事件的全局编号由分块逻辑负责，这里绝不能重新编号
      expect(lines.contains('══ 大事件28：小惠养伤 ══'), isTrue);
      expect(lines.contains('══ 大事件29：唯欣告白 ══'), isTrue);
      expect(lines.contains('○ 小事件1：归来的伤口'), isTrue);
      expect(lines.contains('○ 小事件1：地图上的红圈'), isTrue);
    });

    test('分块阶段：已是规范写法时原样返回', () {
      const canonical = '══ 大事件9：甲 ══\n概述\n○ 小事件1：乙\n正文';
      expect(normalizeMinorHeaders(canonical), canonical);
      expect(normalizeMinorHeaders(canonical), same(canonical));
    });
  });
}
