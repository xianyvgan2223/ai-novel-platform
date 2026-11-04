import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_syntax.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_transfer.dart';

/// 独立验证「导出大纲 txt → 导入大纲 txt」的往返等价性。
///
/// 与 `test/outline_txt_transfer_test.dart` 的分工：那个文件测单点行为；
/// 这里把「导出字节 → 导入解码 → 规范化 → 标题推导 / 事件计数 / 事件解析」
/// 串成完整链路逐字节断言，重点验证**两端导入同一份 txt 得到同一结果**的
/// 依据（编码、换行、标题、事件数），并覆盖 UTF-8 BOM / 无 BOM / UTF-16LE /
/// UTF-16BE / CRLF / 空文件 / GBK 字节 / 含点与空格的文件名。
///
/// 规格：`reports/outline-txt-transfer-spec.md` 第 2 节。
void main() {
  /// App 规范写法（生成 / 落库后的形态）：normalizeOutlineText 对它幂等，
  /// 因此「导出 → 导入」应当逐字节不变。
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

  /// 完整导入链路：导出字节 → 导入解码 → 规范化
  String importAfterExport(String content) => prepareOutlineTxtContent(
    decodeOutlineTxtBytes(encodeOutlineTxtBytes(content)),
  );

  Matcher throwsImportError(String message) => throwsA(
    isA<OutlineTxtImportException>().having(
      (e) => e.message,
      'message',
      message,
    ),
  );

  group('导出字节（UTF-8 + BOM、正文逐字节原样）', () {
    test('BOM 固定为 EF BB BF，正文是 UTF-8 原文且不裁剪', () {
      const String content = '\n\n  开头空格\n\n书名：《原样保留》\n正文末尾有空格  \n\n';
      final bytes = encodeOutlineTxtBytes(content);

      expect(bytes.sublist(0, 3), kOutlineTxtUtf8Bom);
      expect(bytes.sublist(3), utf8.encode(content));
      // 导出端不 trim、不删空行（只有内容全空时才禁止导出）
      expect(utf8.decode(bytes.sublist(3)), content);
      expect(content.trim(), isNot(content));
    });

    test('CRLF 原样导出，不做 LF 转换', () {
      const String content = '书名：《换行》\r\n══ 大事件1：起点 ══\r\n核心事件\r\n';
      final payload = utf8.decode(encodeOutlineTxtBytes(content).sublist(3));
      expect(payload, content);
      expect(payload.contains('\r\n'), isTrue);
    });

    test('导出 → 导入：已规范化正文逐字节不变，重新导出字节完全相同', () {
      final firstExport = encodeOutlineTxtBytes(canonical);
      final imported = prepareOutlineTxtContent(
        decodeOutlineTxtBytes(firstExport),
      );

      expect(imported, canonical);
      // 等价性最强断言：导出→导入→再导出，字节级一致
      expect(encodeOutlineTxtBytes(imported), firstExport);
    });
  });

  group('导入编码识别（UTF-8 BOM / 无 BOM / UTF-16LE / UTF-16BE）', () {
    test('无 BOM 的 UTF-8', () {
      const String text = '书名：《无 BOM》\n第一行\n第二行';
      expect(decodeOutlineTxtBytes(utf8.encode(text)), text);
    });

    test('UTF-8 BOM 被剥掉，结果不含 U+FEFF', () {
      final decoded = decodeOutlineTxtBytes(encodeOutlineTxtBytes('中文正文'));
      expect(decoded, '中文正文');
      expect(decoded.contains('\uFEFF'), isFalse);
    });

    test('UTF-16LE（FF FE）带 BOM，含非 BMP 字符', () {
      const String text = '第一幕：开端\n大事件1：初见 🚀\n    概要';
      final decoded = decodeOutlineTxtBytes(
        utf16Bytes(text, littleEndian: true),
      );
      expect(decoded, text);
      expect(decoded.contains('\uFEFF'), isFalse);
    });

    test('UTF-16BE（FE FF）带 BOM，含非 BMP 字符', () {
      const String text = '第一幕：开端\n大事件1：初见 🚀\n    概要';
      final decoded = decodeOutlineTxtBytes(
        utf16Bytes(text, littleEndian: false),
      );
      expect(decoded, text);
      expect(decoded.contains('\uFEFF'), isFalse);
    });

    test('导出字节转存成 UTF-16LE / UTF-16BE 后，导入结果仍与原文一致', () {
      final legacy = decodeOutlineTxtBytes(
        utf16Bytes(canonical, littleEndian: true),
      );
      expect(prepareOutlineTxtContent(legacy), canonical);

      final bigEndian = decodeOutlineTxtBytes(
        utf16Bytes(canonical, littleEndian: false),
      );
      expect(prepareOutlineTxtContent(bigEndian), canonical);
    });

    test('CRLF / 单独 CR：解码层保留原文，规范化层统一成 LF', () {
      const String mixed = '第一行\r\n第二行\r第三行';
      // 解码不做换行转换（规格：读取端统一按原文处理，规范化是下一步）
      expect(decodeOutlineTxtBytes(utf8.encode(mixed)), mixed);
      expect(prepareOutlineTxtContent(mixed), '第一行\n第二行\n第三行');
      // 导出→导入：CRLF 正文导入后统一成 LF
      expect(importAfterExport(mixed), '第一行\n第二行\n第三行');
    });
  });

  group('空文件与错误编码给可读错误', () {
    test('空字节：提示 txt 文件是空的', () {
      expect(
        () => decodeOutlineTxtBytes(const <int>[]),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('只有 BOM 的文件：解码为空串，规范化时提示空文件', () {
      final decoded = decodeOutlineTxtBytes(kOutlineTxtUtf8Bom);
      expect(decoded, isEmpty);
      expect(
        () => prepareOutlineTxtContent(decoded),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('只有空白字符的正文：提示空文件', () {
      expect(
        () => prepareOutlineTxtContent(' \r\n\t\r\n '),
        throwsImportError('txt 文件是空的'),
      );
    });

    test('GBK 字节：提示改用记事本另存为 UTF-8', () {
      // 「你好」的 GBK 字节，UTF-8 严格解码必然失败
      expect(
        () => decodeOutlineTxtBytes(const <int>[0xC4, 0xE3, 0xBA, 0xC3]),
        throwsImportError('文件不是 UTF-8 / UTF-16 编码，请用记事本另存为 UTF-8 后再导入'),
      );
    });

    test('带 UTF-8 BOM 但正文不是合法 UTF-8：同样给可读错误', () {
      expect(
        () => decodeOutlineTxtBytes(const <int>[
          0xEF,
          0xBB,
          0xBF,
          0xC4,
          0xE3,
          0xBA,
          0xC3,
        ]),
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

    test('导出文件名：非法字符替换成下划线', () {
      expect(
        outlineTxtFileName(r'a/b:c*d?e"f<g>h|i\j'),
        '《a_b_c_d_e_f_g_h_i_j》大纲.txt',
      );
    });

    test('导出文件名：去首尾空白与结尾的点，内部点保留', () {
      expect(outlineTxtFileName('  书名.  '), '《书名》大纲.txt');
      expect(outlineTxtFileName('书.名'), '《书.名》大纲.txt');
      expect(outlineTxtFileName('100%完成'), '《100%完成》大纲.txt');
    });

    test('导出文件名 → 导入标题：书名往返一致', () {
      const titles = <String>['斗破苍穹', '书.名', 'a b', '测试作品'];
      for (final title in titles) {
        expect(
          deriveOutlineTxtTitle(
            fileName: outlineTxtFileName(title),
            content: '没有书名行的普通正文',
          ),
          title,
          reason: '书名「$title」导出文件名后再导入应还原',
        );
      }
    });

    test('正文书名行优先于文件名，且不在第一行也能识别', () {
      expect(
        deriveOutlineTxtTitle(
          fileName: '《文件名里的书》大纲.txt',
          content: '══ 第一幕：开端 ══\n书名：《第二行的书》\n正文',
        ),
        '第二行的书',
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

    test('文件名里含空格时保留空格', () {
      expect(
        deriveOutlineTxtTitle(fileName: '《书 名》大纲.txt', content: '正文'),
        '书 名',
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

      // 对已规范化正文同样幂等
      expect(normalizeOutlineText(canonical), canonical);
    });

    test('只重写事件标题行，概要行 / 空行 / 行数逐字节不变', () {
      final normalized = normalizeOutlineText(messy);
      expect(normalized.split('\n').length, messy.split('\n').length);
      // 概要行（含缩进与列表符号）逐字节保留
      expect(normalized, contains('\n    概要A\n'));
      expect(normalized, contains('\n  - 列表项\n'));
      // 事件标题统一成 App 规范写法
      expect(normalized, contains('══ 大事件1：归来 ══'));
      expect(normalized, contains('○ 小事件1：伤口'));
      expect(normalized, contains('══ 大事件2：再战 ══'));
      expect(normalized, contains('○ 小事件1：决斗'));
    });

    test('导入规范化 = 去 BOM / 统一换行 / trim 后再 normalizeOutlineText', () {
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

    test('杂乱写法也按同一规则计数（含 markdown / 强调 / 多位编号）', () {
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

    test('导出 → 导入不改变事件数', () {
      expect(countOutlineTxtEvents(importAfterExport(messy)), 4);
      expect(countOutlineTxtEvents(importAfterExport(canonical)), 5);
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
      // 与网页端 parseOutlineEvents 的 trim() 规则一致：不能把缩进带进概要
      for (final event in events) {
        for (final line in event.eventSummary.split('\n')) {
          expect(line, line.trim());
        }
      }
    });

    test('杂乱正文导入规范化后同样解析出 4 个事件', () {
      final imported = importAfterExport(messy);
      final events = parseOutlineEvents(imported, outlineId: 0);
      expect(events.length, 4);
      expect(events.map((e) => e.eventTitle).toList(), <String>[
        '归来',
        '伤口',
        '再战',
        '决斗',
      ]);
      expect(events[1].eventSummary, '概要A\n- 列表项');
    });
  });

  group('导出 → 导入整链（模拟一次真实备份恢复）', () {
    test('标题 / 正文 / 事件数与导出前一致', () {
      // 库里的记录
      const String storedTitle = '往返测试';
      const String storedContent = canonical;

      // 导出：文件名 + 字节
      final fileName = outlineTxtFileName(storedTitle);
      final exported = encodeOutlineTxtBytes(storedContent);

      // 导入：解码 → 规范化 → 标题推导 → 事件数
      final content = prepareOutlineTxtContent(decodeOutlineTxtBytes(exported));
      final title = deriveOutlineTxtTitle(fileName: fileName, content: content);
      final eventCount = countOutlineTxtEvents(content);

      expect(title, storedTitle);
      expect(content, storedContent);
      expect(eventCount, 5);
    });
  });
}
