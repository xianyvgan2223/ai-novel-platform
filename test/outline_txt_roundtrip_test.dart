import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/domain/character_profile.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_syntax.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_transfer.dart';

/// 独立验证「导出大纲 txt → 导入大纲 txt」的往返等价性。
///
/// 覆盖两代格式：
/// - **v2 结构化**（当前导出格式）：正文 + 书名 / 类型 / 主题 / 主角简介 /
///   世界观 / 伏笔清单 / 人物档案，导出→导入→再导出逐字节一致；
/// - **旧版纯正文**（没有 v2 文件头）：仍按纯正文兼容导入。
///
/// 同时覆盖 UTF-8 BOM / 无 BOM / UTF-16LE / UTF-16BE / CRLF / 空文件 /
/// GBK 字节 / 文件名与标题推导 / 事件解析。
///
/// 规格：`reports/outline-txt-transfer-spec.md` 第 2 节。
void main() {
  /// App 规范写法（生成 / 落库后的形态）：normalizeOutlineText 对它幂等，
  /// 因此「导出 → 导入」正文应当逐字节不变。
  const String canonical =
      '书名：《往返测试》\n'
      '\n'
      '══ 第一幕：开端 ══\n'
      '\n'
      '══ 大事件1：初见 ══\n'
      '○ 小事件1：相遇\n'
      '    两人在地铁站相遇\n'
      '- 旧铁条\n'
      '══ 大事件2：冲突 ══\n'
      '○ 小事件1：争执\n'
      '    争执升级\n'
      '○ 小事件2：和解';

  /// 手写 / 模型输出的杂乱写法：事件标题行要被规范化，概要行必须原样保留。
  const String messy =
      '## ══ 大事件28：归来 ══\n'
      '○ **小事件1：伤口**\n'
      '    概要A\n'
      '  - 列表项\n'
      '=== 大事件29：再战 ===\n'
      '- 小事件3：决斗';

  const List<CharacterProfile> characters = <CharacterProfile>[
    CharacterProfile(
      name: '顾泽',
      description: '主角，江城异能管理署署长',
      abilities: '异能「界」，削峰拉平',
      personality: '冷静',
      isProtagonist: true,
    ),
    CharacterProfile(
      name: '林晚',
      description: '第一行描述\n第二行描述\n- 列表项',
      abilities: '',
      personality: '执拗',
    ),
  ];

  String charactersJson() => jsonEncode(<Map<String, dynamic>>[
    for (final c in characters) c.toJson(),
  ]);

  /// 按端序把文本编码成 UTF-16 字节（带 BOM），模拟 Windows 记事本的
  /// 「Unicode / Unicode big endian」另存结果。
  Uint8List utf16Bytes(String text, {required bool littleEndian}) {
    final bytes = <int>[littleEndian ? 0xFF : 0xFE, littleEndian ? 0xFE : 0xFF];
    for (final unit in text.codeUnits) {
      if (littleEndian) {
        bytes.add(unit & 0xFF);
        bytes.add((unit >> 8) & 0xFF);
      } else {
        bytes.add((unit >> 8) & 0xFF);
        bytes.add(unit & 0xFF);
      }
    }
    return Uint8List.fromList(bytes);
  }

  Matcher throwsImportError(String message) => throwsA(
    isA<OutlineTxtImportException>().having(
      (e) => e.message,
      'message',
      message,
    ),
  );

  group('v2 导出：BOM、文件头、设定章节、正文原样', () {
    test('BOM 固定为 EF BB BF，第一行是 v2 文件头', () {
      final bytes = encodeOutlineTxtDocumentBytes(
        title: '斗破苍穹',
        genre: '玄幻',
        theme: '成长',
        protagonist: '萧炎',
        worldview: '斗气大陆',
        foreshadows: '药老',
        charactersJson: charactersJson(),
        content: canonical,
      );
      expect(bytes.sublist(0, 3), kOutlineTxtUtf8Bom);
      final text = utf8.decode(bytes.sublist(3));
      expect(text.split('\n').first, kOutlineTxtMagic);
      expect(text.contains('\uFEFF'), isFalse);
    });

    test('各设定章节都有，且正文原样放在「## 大纲正文」之后', () {
      final text = renderOutlineTxtDocument(
        title: '斗破苍穹',
        genre: '玄幻',
        theme: '成长',
        protagonist: '萧炎',
        worldview: '斗气大陆',
        foreshadows: '药老',
        charactersJson: charactersJson(),
        content: canonical,
      );
      for (final section in <String>[
        '书名',
        '类型',
        '主题',
        '主角简介',
        '世界观',
        '伏笔清单',
        '人物档案',
        '大纲正文',
      ]) {
        expect(text, contains('## $section'), reason: '缺少章节：$section');
      }
      final body = text
          .substring(text.indexOf('## 大纲正文') + '## 大纲正文'.length)
          .trim();
      expect(body, canonical);
    });

    test('空设定章节整节省略（只有正文的旧数据也能导出）', () {
      final text = renderOutlineTxtDocument(title: '只有正文', content: canonical);
      expect(text, isNot(contains('## 类型')));
      expect(text, isNot(contains('## 主题')));
      expect(text, isNot(contains('## 世界观')));
      expect(text, isNot(contains('## 人物档案')));
      expect(text, contains('## 大纲正文'));
    });

    test('人物档案写成可读段落：姓名 / 描述 / 能力 / 性格 / 主角', () {
      final text = renderOutlineTxtDocument(
        title: '人物测试',
        charactersJson: charactersJson(),
        content: '══ 大事件1：开端 ══',
      );
      expect(text, contains('- 姓名：顾泽'));
      expect(text, contains('  描述：主角，江城异能管理署署长'));
      expect(text, contains('  能力：异能「界」，削峰拉平'));
      expect(text, contains('  性格：冷静'));
      expect(text, contains('  主角：是'));
      expect(text, contains('- 姓名：林晚'));
      expect(text, contains('    第二行描述'));
      expect(text, contains('    - 列表项'));
      expect(text, contains('  主角：否'));
    });
  });

  group('v2 导入解析：设定与人物档案还原', () {
    test('书名 / 类型 / 主题 / 主角简介 / 世界观 / 伏笔清单逐字还原', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '斗破苍穹',
          genre: '玄幻',
          theme: '成长',
          protagonist: '萧炎',
          worldview: '斗气大陆',
          foreshadows: '药老',
          charactersJson: charactersJson(),
          content: canonical,
        ),
      );
      expect(doc.structured, isTrue);
      expect(doc.title, '斗破苍穹');
      expect(doc.genre, '玄幻');
      expect(doc.theme, '成长');
      expect(doc.protagonist, '萧炎');
      expect(doc.worldview, '斗气大陆');
      expect(doc.foreshadows, '药老');
      expect(doc.content, canonical);
    });

    test('人物档案逐人物逐字段还原（含多行描述与主角标记）', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '人物测试',
          charactersJson: charactersJson(),
          content: '══ 大事件1：开端 ══',
        ),
      );
      expect(doc.characters, hasLength(2));
      expect(doc.characters[0].name, '顾泽');
      expect(doc.characters[0].description, '主角，江城异能管理署署长');
      expect(doc.characters[0].abilities, '异能「界」，削峰拉平');
      expect(doc.characters[0].personality, '冷静');
      expect(doc.characters[0].isProtagonist, isTrue);
      expect(doc.characters[1].name, '林晚');
      expect(doc.characters[1].description, '第一行描述\n第二行描述\n- 列表项');
      expect(doc.characters[1].personality, '执拗');
      expect(doc.characters[1].isProtagonist, isFalse);
      // 写库 JSON 与出处一一对应
      expect(doc.charactersJson, contains('"is_protagonist":true'));
      expect(doc.charactersJson, contains('"name":"林晚"'));
      // 这个文档只带了人物档案、没有其它设定字段，摘要只列人物
      expect(doc.settingsSummary, '人物档案 2 人');
    });

    test('空设定文件人物列表为空、charactersJson 为空串（不写 [] 污染数据）', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(title: '无设定', content: canonical),
      );
      expect(doc.characters, isEmpty);
      expect(doc.charactersJson, isEmpty);
      expect(doc.hasSettings, isFalse);
      expect(doc.settingsSummary, isEmpty);
    });

    test('人物档案 JSON 坏掉时导出不整本失败（只丢人物档案）', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '坏档案',
          charactersJson: '{不是合法 JSON',
          content: '══ 大事件1：开端 ══',
        ),
      );
      expect(doc.title, '坏档案');
      expect(doc.characters, isEmpty);
      expect(doc.content, '══ 大事件1：开端 ══');
    });

    test('只有设定、正文为空也能解析（不会被当成空文件）', () {
      const raw =
          '$kOutlineTxtMagic\n\n## 书名\n设定书\n\n## 世界观\n九域\n\n## 大纲正文\n\n';
      final doc = parseOutlineTxtDocument(raw);
      expect(doc.structured, isTrue);
      expect(doc.title, '设定书');
      expect(doc.worldview, '九域');
      expect(doc.content, isEmpty);
      expect(doc.hasSettings, isTrue);
    });

    test('旧版纯正文 txt（无 v2 文件头）按纯正文兼容导入', () {
      final doc = parseOutlineTxtDocument(messy);
      expect(doc.structured, isFalse);
      expect(doc.title, isEmpty);
      expect(doc.hasSettings, isFalse);
      expect(doc.content, normalizeOutlineText(messy));
    });
  });

  group('导出 → 导入 → 再导出：字节级一致', () {
    test('v2 结构化文件逐字节往返', () {
      final first = encodeOutlineTxtDocumentBytes(
        title: '往返测试',
        genre: '玄幻',
        theme: '成长',
        protagonist: '顾泽',
        worldview: '九域',
        foreshadows: '旧铁条',
        charactersJson: charactersJson(),
        content: canonical,
      );
      final doc = decodeOutlineTxtDocumentBytes(first);
      final second = encodeOutlineTxtDocumentBytes(
        title: doc.title,
        genre: doc.genre,
        theme: doc.theme,
        protagonist: doc.protagonist,
        worldview: doc.worldview,
        foreshadows: doc.foreshadows,
        charactersJson: doc.charactersJson,
        content: doc.content,
      );
      expect(second, first);
    });

    test('杂乱正文导入规范化后，正文与事件解析都稳定', () {
      final first = encodeOutlineTxtDocumentBytes(
        title: '杂乱正文',
        content: messy,
      );
      final doc = decodeOutlineTxtDocumentBytes(first);
      expect(doc.content, normalizeOutlineText(messy));
      final events = parseOutlineEvents(doc.content, outlineId: 0);
      expect(events.length, 4);
      expect(events.map((e) => e.eventTitle).toList(), <String>[
        '归来',
        '伤口',
        '再战',
        '决斗',
      ]);
    });
  });

  group('导入编码识别（UTF-8 BOM / 无 BOM / UTF-16LE / UTF-16BE）', () {
    test('无 BOM 的 UTF-8（纯文本）', () {
      const String text = '书名：《无 BOM》\n第一行\n第二行';
      expect(decodeOutlineTxtBytes(utf8.encode(text)), text);
    });

    test('v2 文件转成 UTF-16LE / UTF-16BE 后，导入结果与 UTF-8 完全一致', () {
      final text = renderOutlineTxtDocument(
        title: '编码测试',
        worldview: '九域',
        charactersJson: charactersJson(),
        content: canonical,
      );
      final fromUtf8 = parseOutlineTxtDocument(text);
      final fromLe = parseOutlineTxtDocument(
        decodeOutlineTxtBytes(utf16Bytes(text, littleEndian: true)),
      );
      final fromBe = parseOutlineTxtDocument(
        decodeOutlineTxtBytes(utf16Bytes(text, littleEndian: false)),
      );
      for (final doc in <OutlineTxtDocument>[fromLe, fromBe]) {
        expect(doc.title, fromUtf8.title);
        expect(doc.worldview, fromUtf8.worldview);
        expect(doc.content, fromUtf8.content);
        expect(doc.charactersJson, fromUtf8.charactersJson);
      }
    });

    test('CRLF / 单独 CR：解码层保留原文，解析层统一成 LF', () {
      const String mixed = '第一行\r\n第二行\r第三行';
      expect(decodeOutlineTxtBytes(utf8.encode(mixed)), mixed);
      expect(prepareOutlineTxtContent(mixed), '第一行\n第二行\n第三行');
    });
  });

  group('空文件与错误编码给可读错误', () {
    test('空字节：提示 txt 文件是空的', () {
      expect(
        () => decodeOutlineTxtBytes(const <int>[]),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('只有 BOM 的文件：解析时提示空文件', () {
      final decoded = decodeOutlineTxtBytes(kOutlineTxtUtf8Bom);
      expect(decoded, isEmpty);
      expect(
        () => parseOutlineTxtDocument(decoded),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('只有空白字符的正文：提示空文件', () {
      expect(
        () => parseOutlineTxtDocument(' \r\n\t\r\n '),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('GBK 字节：提示改用记事本另存为 UTF-8', () {
      expect(
        () => decodeOutlineTxtBytes(const <int>[0xC4, 0xE3, 0xBA, 0xC3]),
        throwsImportError('文件不是 UTF-8 / UTF-16 编码，请用记事本另存为 UTF-8 后再导入'),
      );
    });
  });

  group('文件名清洗与导入标题推导', () {
    test('导出文件名：书名号 + 大纲.txt', () {
      expect(outlineTxtFileName('斗破苍穹'), '《斗破苍穹》大纲.txt');
      expect(outlineTxtFileName(''), '《未命名大纲》大纲.txt');
      expect(outlineTxtFileName('   '), '《未命名大纲》大纲.txt');
    });

    test('导出文件名：非法字符替换成下划线，内部点保留', () {
      expect(
        outlineTxtFileName(r'a/b:c*d?e"f<g>h|i\j'),
        '《a_b_c_d_e_f_g_h_i_j》大纲.txt',
      );
      expect(outlineTxtFileName('书.名'), '《书.名》大纲.txt');
      expect(outlineTxtFileName('100%完成'), '《100%完成》大纲.txt');
    });

    test('v2 书名章节优先于正文书名行与文件名', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '章节书名',
          content: '书名：《正文里的书名》\n\n══ 大事件1：开端 ══',
        ),
      );
      expect(
        deriveOutlineTxtTitleForDocument(
          document: doc,
          fileName: '《文件名里的书》大纲.txt',
        ),
        '章节书名',
      );
    });

    test('旧版纯正文没有书名章节：正文书名行优先，其次文件名', () {
      final doc = parseOutlineTxtDocument('书名：《正文书名》\n\n══ 大事件1：开端 ══');
      expect(
        deriveOutlineTxtTitleForDocument(
          document: doc,
          fileName: '《文件名里的书》大纲.txt',
        ),
        '正文书名',
      );
    });

    test('文件名回退：去 .txt、书名号与末尾大纲后缀', () {
      expect(
        deriveOutlineTxtTitle(fileName: '《我的小说》大纲.txt', content: '正文'),
        '我的小说',
      );
      expect(
        deriveOutlineTxtTitle(fileName: '我的作品-大纲.txt', content: '正文'),
        '我的作品',
      );
      expect(
        deriveOutlineTxtTitle(fileName: '我的作品大纲正文.txt', content: '正文'),
        '我的作品',
      );
    });

    test('文件名含目录路径时只取文件名部分', () {
      expect(
        deriveOutlineTxtTitle(fileName: r'D:\txt\《盘符路径》大纲.txt', content: '正文'),
        '盘符路径',
      );
    });

    test('完全推不出来时兜底「未命名大纲」', () {
      expect(deriveOutlineTxtTitle(fileName: '大纲.txt', content: '正文'), '未命名大纲');
      expect(deriveOutlineTxtTitle(fileName: '.txt', content: ''), '未命名大纲');
    });
  });

  group('normalizeOutlineText 幂等与概要行逐字节保留', () {
    test('规范化一次后再规范化，结果不变（幂等）', () {
      final once = normalizeOutlineText(messy);
      final twice = normalizeOutlineText(once);
      expect(twice, once);
      expect(normalizeOutlineText(canonical), canonical);
    });

    test('只重写事件标题行，概要行 / 空行 / 行数逐字节不变', () {
      final normalized = normalizeOutlineText(messy);
      expect(normalized.split('\n').length, messy.split('\n').length);
      expect(normalized, contains('\n    概要A\n'));
      expect(normalized, contains('\n  - 列表项\n'));
      expect(normalized, contains('══ 大事件1：归来 ══'));
      expect(normalized, contains('○ 小事件1：伤口'));
      expect(normalized, contains('══ 大事件2：再战 ══'));
      expect(normalized, contains('○ 小事件1：决斗'));
    });

    test('导入正文规范化 = 去 BOM / 统一换行 / trim 后再 normalizeOutlineText', () {
      final windowsStyle = '\uFEFF\r\n${messy.replaceAll('\n', '\r\n')}\r\n';
      expect(
        prepareOutlineTxtContent(windowsStyle),
        normalizeOutlineText(messy),
      );
    });
  });

  group('countOutlineTxtEvents（导入确认弹窗的事件数）', () {
    test('规范正文：2 个大事件 + 3 个小事件 = 5', () {
      expect(countOutlineTxtEvents(canonical), 5);
    });

    test('杂乱写法也按同一规则计数', () {
      expect(countOutlineTxtEvents(messy), 4);
    });

    test('幕标题 / 装饰行 / 普通列表 / 无标题事件行不计入', () {
      const String noEvents =
          '══ 第一幕：开端 ══\n'
          '══════════\n'
          '- 普通列表项\n'
          '大事件：\n'
          '小事件X：\n';
      expect(countOutlineTxtEvents(noEvents), 0);
    });
  });

  group('导入后落库用的事件解析（与手机端 reconcile 一致）', () {
    test('规范正文解析出 5 个事件，eventIndex 从 1 连续递增', () {
      final events = parseOutlineEvents(canonical, outlineId: 0);
      expect(events.length, countOutlineTxtEvents(canonical));
      expect(events.map((e) => e.eventIndex).toList(), <int>[1, 2, 3, 4, 5]);
      expect(events.map((e) => e.eventType).toList(), <String>[
        'major',
        'minor',
        'major',
        'minor',
        'minor',
      ]);
      expect(events.map((e) => e.eventTitle).toList(), <String>[
        '初见',
        '相遇',
        '冲突',
        '争执',
        '和解',
      ]);
    });

    test('概要行去掉首尾空白后换行拼接，缩进不进入库字段', () {
      final events = parseOutlineEvents(canonical, outlineId: 0);
      expect(events[1].eventSummary, '两人在地铁站相遇\n- 旧铁条');
      expect(events[3].eventSummary, '争执升级');
      expect(events[2].eventSummary, isEmpty);
      for (final event in events) {
        for (final line in event.eventSummary.split('\n')) {
          expect(line, line.trim());
        }
      }
    });
  });

  group('导出 → 导入整链（模拟一次真实备份恢复）', () {
    test('书名 / 设定 / 人物档案 / 正文 / 事件数与导出前一致', () {
      const String storedTitle = '往返测试';
      final fileName = outlineTxtFileName(storedTitle);
      final exported = encodeOutlineTxtDocumentBytes(
        title: storedTitle,
        genre: '玄幻',
        worldview: '九域',
        foreshadows: '旧铁条',
        charactersJson: charactersJson(),
        content: canonical,
      );

      final document = decodeOutlineTxtDocumentBytes(exported);
      final title = deriveOutlineTxtTitleForDocument(
        document: document,
        fileName: fileName,
      );

      expect(title, storedTitle);
      expect(document.worldview, '九域');
      expect(document.foreshadows, '旧铁条');
      expect(document.characters, hasLength(2));
      expect(document.content, canonical);
      expect(countOutlineTxtEvents(document.content), 5);
    });
  });
}
