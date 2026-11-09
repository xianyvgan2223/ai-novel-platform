import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/novel_writing_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_export_sheet.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_import_dialog.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_txt_transfer.dart';

/// 「一键导出 / 导入大纲 txt」的纯逻辑测试。
///
/// 覆盖规格 `reports/outline-txt-transfer-spec.md` 第 2 节：
/// 文件名清洗、标题推导、UTF-8/UTF-16 编解码、BOM、CRLF、空文件与错误编码，
/// 以及导出 → 导入的往返一致性。
void main() {
  /// 按指定端序把文本编码成 UTF-16 字节（默认带 BOM），供解码测试用
  Uint8List utf16Bytes(
    String text, {
    required bool littleEndian,
    bool withBom = true,
  }) {
    final bytes = <int>[];
    if (withBom) {
      bytes.addAll(littleEndian ? const [0xFF, 0xFE] : const [0xFE, 0xFF]);
    }
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

  group('导出格式（v2 结构化：正文 + 小说设定 + 人物档案）', () {
    const charactersJson =
        '[{"name":"顾泽","description":"主角，江城异能署署长",'
        '"abilities":"异能「界」，削峰拉平","personality":"冷静",'
        '"is_protagonist":true}]';
    const content = '══ 大事件1：初见 ══\n\n○ 小事件1：相遇\n    两人在地铁站相遇';

    test('UTF-8 + BOM，带 v2 文件头、设定章节与正文', () {
      final bytes = encodeOutlineTxtDocumentBytes(
        title: '测试书',
        genre: '玄幻',
        theme: '成长',
        protagonist: '顾泽',
        worldview: '九域',
        foreshadows: '旧铁条',
        charactersJson: charactersJson,
        content: content,
      );
      expect(bytes.sublist(0, 3), kOutlineTxtUtf8Bom);
      final text = utf8.decode(bytes.sublist(3));
      expect(text.split('\n').first, kOutlineTxtMagic);
      expect(text, contains('## 书名\n测试书'));
      expect(text, contains('## 类型\n玄幻'));
      expect(text, contains('## 主题\n成长'));
      expect(text, contains('## 主角简介\n顾泽'));
      expect(text, contains('## 世界观\n九域'));
      expect(text, contains('## 伏笔清单\n旧铁条'));
      expect(text, contains('## 人物档案\n- 姓名：顾泽'));
      expect(text, contains('  描述：主角，江城异能署署长'));
      expect(text, contains('  主角：是'));
      // 正文原样放在「## 大纲正文」之后（只允许尾部多一个换行）
      final body = text
          .substring(text.indexOf('## 大纲正文') + '## 大纲正文'.length)
          .trim();
      expect(body, content);
    });

    test('空字段整节省略，正文照常导出', () {
      final text = renderOutlineTxtDocument(
        title: '只有正文',
        content: '══ 大事件1：开端 ══',
      );
      expect(text, isNot(contains('## 类型')));
      expect(text, isNot(contains('## 世界观')));
      expect(text, isNot(contains('## 人物档案')));
      expect(text, contains('## 大纲正文'));
    });

    test('导出文本与网页端逐字节一致（固定夹具，防止两端格式漂移）', () {
      // 该期望值同时由网页端 `renderOutlineTxtDocument` 生成并校验（Node 直跑，
      // 见 reports/outline-txt-transfer-verify.md 的 v2 格式交叉校验）
      const expected =
          '# DeepSeek 大纲导出 v2\n'
          '\n'
          '## 书名\n'
          '格式夹具\n'
          '\n'
          '## 类型\n'
          '玄幻\n'
          '\n'
          '## 大纲正文\n'
          '\n'
          '══ 大事件1：开端 ══\n';
      expect(
        renderOutlineTxtDocument(
          title: '格式夹具',
          genre: '玄幻',
          content: '══ 大事件1：开端 ══',
        ),
        expected,
      );
    });

    test('导入解析：v2 还原书名 / 设定 / 人物档案 / 正文', () {
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '测试书',
          genre: '玄幻',
          theme: '成长',
          protagonist: '顾泽',
          worldview: '九域',
          foreshadows: '旧铁条',
          charactersJson: charactersJson,
          content: content,
        ),
      );
      expect(doc.structured, isTrue);
      expect(doc.title, '测试书');
      expect(doc.genre, '玄幻');
      expect(doc.theme, '成长');
      expect(doc.protagonist, '顾泽');
      expect(doc.worldview, '九域');
      expect(doc.foreshadows, '旧铁条');
      expect(doc.characters, hasLength(1));
      expect(doc.characters.single.name, '顾泽');
      expect(doc.characters.single.abilities, '异能「界」，削峰拉平');
      expect(doc.characters.single.isProtagonist, isTrue);
      expect(doc.charactersJson, contains('"is_protagonist":true'));
      expect(doc.content, content);
      expect(doc.hasSettings, isTrue);
      expect(doc.settingsSummary, '类型、主题、主角简介、世界观、伏笔清单 · 人物档案 1 人');
      expect(
        deriveOutlineTxtTitleForDocument(document: doc, fileName: '随便.txt'),
        '测试书',
      );
    });

    test('人物档案多行描述往返一致（含以 - 开头的行与缩进行）', () {
      const multiLine =
          '[{"name":"顾泽","description":"第一行\\n- 列表项\\n  缩进行",'
          '"abilities":"","personality":"冷静","is_protagonist":false}]';
      final doc = decodeOutlineTxtDocumentBytes(
        encodeOutlineTxtDocumentBytes(
          title: '多行人物',
          charactersJson: multiLine,
          content: '══ 大事件1：开端 ══',
        ),
      );
      expect(doc.characters.single.description, '第一行\n- 列表项\n  缩进行');
      expect(doc.characters.single.isProtagonist, isFalse);
    });

    test('旧版纯正文 txt（无 v2 文件头）仍按纯正文导入', () {
      const raw = '大事件1：开端\n○ **小事件1：初遇**\n概要';
      final doc = parseOutlineTxtDocument(raw);
      expect(doc.structured, isFalse);
      expect(doc.title, isEmpty);
      expect(doc.hasSettings, isFalse);
      expect(doc.content, contains('══ 大事件1：开端 ══'));
      expect(doc.content, contains('○ 小事件1：初遇'));
    });

    test('v2 文件只有设定、正文为空也能导入（不会当空文件）', () {
      const raw =
          '$kOutlineTxtMagic\n\n## 书名\n设定书\n\n## 世界观\n九域\n\n## 大纲正文\n\n';
      final doc = parseOutlineTxtDocument(raw);
      expect(doc.structured, isTrue);
      expect(doc.title, '设定书');
      expect(doc.worldview, '九域');
      expect(doc.content, isEmpty);
      expect(doc.hasSettings, isTrue);
    });

    test('导出 → 导入 → 再导出：字节完全相同', () {
      final first = encodeOutlineTxtDocumentBytes(
        title: '测试书',
        genre: '玄幻',
        protagonist: '顾泽',
        charactersJson: charactersJson,
        content: content,
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
  });

  group('导出文件名', () {
    test('正常书名', () {
      expect(outlineTxtFileName('斗破苍穹'), '《斗破苍穹》大纲.txt');
    });

    test('空书名 / 全空白用未命名大纲', () {
      expect(outlineTxtFileName(''), '《未命名大纲》大纲.txt');
      expect(outlineTxtFileName('   '), '《未命名大纲》大纲.txt');
    });

    test('非法字符替换成下划线', () {
      expect(
        outlineTxtFileName('a/b:c*d?e"f<g>h|i'),
        '《a_b_c_d_e_f_g_h_i》大纲.txt',
      );
    });

    test('去掉结尾的点与空格（Windows 不允许）', () {
      expect(outlineTxtFileName('  书名.  '), '《书名》大纲.txt');
    });

    test('超长书名截断到 60 字，文件名不超长', () {
      final fileName = outlineTxtFileName('长' * 100);
      expect(fileName, startsWith('《长'));
      expect(fileName, endsWith('》大纲.txt'));
      final stem = fileName.substring(1, fileName.indexOf('》'));
      expect(stem.length, 60);
    });
  });

  group('导入标题推导', () {
    test('正文书名行优先于文件名', () {
      expect(
        deriveOutlineTxtTitle(
          fileName: '随便起的名字.txt',
          content: '书名：《真正的书名》\n\n══ 大事件1：开端 ══',
        ),
        '真正的书名',
      );
    });

    test('书名行不在第一行也能识别', () {
      expect(
        deriveOutlineTxtTitle(
          fileName: 'a.txt',
          content: '══ 第一幕：开端 ══\n书名：《第二行的书名》',
        ),
        '第二行的书名',
      );
    });

    test('文件名回退：去书名号与「大纲」后缀', () {
      expect(
        deriveOutlineTxtTitle(
          fileName: '《我的小说》大纲.txt',
          content: '══ 大事件1：开端 ══',
        ),
        '我的小说',
      );
    });

    test('文件名带目录路径时只取文件名', () {
      expect(
        deriveOutlineTxtTitle(
          fileName: r'C:\Users\someone\我的作品 大纲.txt',
          content: '没有书名行',
        ),
        '我的作品',
      );
    });

    test('手写「书名：xxx」（无书名号）也能识别', () {
      expect(
        deriveOutlineTxtTitle(fileName: 'x.txt', content: '书名：手写书\n正文'),
        '手写书',
      );
    });

    test('完全识别不出时用未命名大纲', () {
      expect(
        deriveOutlineTxtTitle(fileName: '大纲.txt', content: '一些普通文字'),
        '未命名大纲',
      );
    });
  });

  group('导入解码', () {
    test('带 BOM 的 UTF-8（结构化导出字节）', () {
      final bytes = encodeOutlineTxtDocumentBytes(
        title: '中文大纲',
        content: '中文大纲',
      );
      expect(decodeOutlineTxtBytes(bytes), contains(kOutlineTxtMagic));
      expect(decodeOutlineTxtDocumentBytes(bytes).title, '中文大纲');
    });

    test('不带 BOM 的 UTF-8', () {
      expect(decodeOutlineTxtBytes(utf8.encode('中文大纲')), '中文大纲');
    });

    test('UTF-16LE（带 BOM）', () {
      final bytes = utf16Bytes('中文大纲\n第二行', littleEndian: true);
      expect(decodeOutlineTxtBytes(bytes), '中文大纲\n第二行');
    });

    test('UTF-16BE（带 BOM）', () {
      final bytes = utf16Bytes('中文大纲\n第二行', littleEndian: false);
      expect(decodeOutlineTxtBytes(bytes), '中文大纲\n第二行');
    });

    test('空文件抛可读异常', () {
      expect(
        () => decodeOutlineTxtBytes(const <int>[]),
        throwsA(
          isA<OutlineTxtImportException>().having(
            (e) => e.message,
            'message',
            'txt 文件是空的',
          ),
        ),
      );
    });

    test('GBK 等非 UTF-8 编码抛可读异常', () {
      // 「你好」的 GBK 字节；UTF-8 严格解码必然失败
      expect(
        () => decodeOutlineTxtBytes(const <int>[0xC4, 0xE3, 0xBA, 0xC3]),
        throwsA(isA<OutlineTxtImportException>()),
      );
    });
  });

  group('导入正文规范化', () {
    test('CRLF / CR 统一为 LF 并去首尾空白', () {
      expect(
        prepareOutlineTxtContent('\r\n  第一行\r\n第二行\r第三行  \r\n'),
        '第一行\n第二行\n第三行',
      );
    });

    test('残留 BOM 字符被剥掉', () {
      expect(prepareOutlineTxtContent('\uFEFF══ 大事件1：开端 ══'), '══ 大事件1：开端 ══');
    });

    test('事件行规范成 App 写法，概要行逐字节保留', () {
      const raw = '大事件1：开端\n○ **小事件1：初遇**\n    概要一\n\n大事件2：发展';
      final content = prepareOutlineTxtContent(raw);
      expect(content, contains('══ 大事件1：开端 ══'));
      expect(content, contains('○ 小事件1：初遇'));
      expect(content, contains('══ 大事件2：发展 ══'));
      expect(content, contains('\n    概要一\n'));
    });

    test('空白内容抛空文件异常', () {
      expect(
        () => prepareOutlineTxtContent('  \r\n  '),
        throwsA(isA<OutlineTxtImportException>()),
      );
    });
  });

  group('写小说主页入口', () {
    testWidgets('导出 / 导入两行直接接在功能列表末尾（没有独立分区标题）', (tester) async {
      tester.view.physicalSize = const Size(420 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: NovelWritingPage()));
      await tester.pumpAndSettle();

      expect(find.text('导出大纲 txt'), findsOneWidget);
      expect(find.text('导入大纲 txt'), findsOneWidget);
      // 用户要求：去掉「大纲文件」分区标题，两行直接接在功能选择下方
      expect(find.text('大纲文件'), findsNothing);
      // 原有功能入口不受影响
      expect(find.text('一键生成大纲'), findsOneWidget);
      expect(find.text('匹配大纲格式'), findsOneWidget);
      // 顺序：导出 / 导入在「匹配大纲格式」之后（同一张卡片里往下接）
      final lastFeatureY = tester.getTopLeft(find.text('匹配大纲格式')).dy;
      expect(
        tester.getTopLeft(find.text('导出大纲 txt')).dy,
        greaterThan(lastFeatureY),
      );
      expect(
        tester.getTopLeft(find.text('导入大纲 txt')).dy,
        greaterThan(tester.getTopLeft(find.text('导出大纲 txt')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('提示字号已缩小：错误提示为 12.5', (tester) async {
      tester.view.physicalSize = const Size(420 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: NovelWritingPage()));
      await tester.pumpAndSettle();

      // 测试环境没有 sqflite，点导出会在「读取作品列表」处失败并弹错误提示，
      // 正好用来校验提示字号（用户反馈提示字太大）。
      await tester.tap(find.text('导出大纲 txt'));
      await tester.pump();
      await tester.pumpAndSettle();

      final errorText = find.textContaining('读取作品列表失败');
      expect(errorText, findsOneWidget);
      expect(tester.widget<Text>(errorText).style?.fontSize, 12.5);
    });

    testWidgets('切换页面时本页提示自动收起（不跟到新页面）', (tester) async {
      tester.view.physicalSize = const Size(420 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: NovelWritingPage()));
      await tester.pumpAndSettle();

      // 借 MaterialApp 自带的根 ScaffoldMessenger 摆一条长提示（模拟导入成功）
      final messengerFinder = find.byType(ScaffoldMessenger);
      expect(messengerFinder, findsOneWidget);
      final messenger = tester.state<ScaffoldMessengerState>(messengerFinder);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已导入《示例》，共 3 个事件'),
          duration: Duration(seconds: 30),
        ),
      );
      await tester.pump();
      expect(find.text('已导入《示例》，共 3 个事件'), findsOneWidget);

      // 点功能入口切页：提示应先被收掉，而不是跟着显示到下一页
      await tester.tap(find.text('匹配大纲格式'));
      await tester.pumpAndSettle();
      expect(find.text('已导入《示例》，共 3 个事件'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('返回上一页时本页提示也自动收起', (tester) async {
      tester.view.physicalSize = const Size(420 * 3, 1600 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 用一个占位首页把写小说页 push 出来，才能验证「返回时收提示」
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NovelWritingPage(),
                    ),
                  ),
                  child: const Text('打开写小说'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开写小说'));
      await tester.pumpAndSettle();

      final messengerFinder = find.byType(ScaffoldMessenger);
      final messenger = tester.state<ScaffoldMessengerState>(messengerFinder);
      messenger.showSnackBar(
        const SnackBar(content: Text('返回前提示'), duration: Duration(seconds: 30)),
      );
      await tester.pump();
      expect(find.text('返回前提示'), findsOneWidget);

      // 顶栏返回：页面销毁时应把提示收掉（不跟到聊天页 / 上一个页面）
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.text('返回前提示'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('选作品弹层', () {
    testWidgets('列出作品并返回点中的一部', (tester) async {
      final novels = <OutlineRecord>[
        OutlineRecord(id: 1, title: '第一部', genre: '玄幻'),
        OutlineRecord(id: 2, title: '第二部'),
      ];
      OutlineRecord? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showOutlineTxtExportSheet(context, novels);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('选择要导出的作品'), findsOneWidget);
      expect(find.text('第一部'), findsOneWidget);
      expect(find.text('第二部'), findsOneWidget);

      await tester.tap(find.text('第二部'));
      await tester.pumpAndSettle();
      expect(picked?.id, 2);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('导入确认弹窗', () {
    testWidgets('显示文件信息 / 预览，改书名后返回新书名', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showOutlineTxtImportDialog(
                  context,
                  fileName: '我的大纲.txt',
                  initialTitle: '默认书名',
                  charCount: 100,
                  eventCount: 3,
                  preview: '══ 大事件1：开端 ══',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('导入大纲 txt'), findsOneWidget);
      expect(find.text('我的大纲.txt'), findsOneWidget);
      expect(find.text('共 100 字 · 识别到 3 个事件'), findsOneWidget);
      expect(find.text('没有识别到大纲事件，仍可导入后手动整理'), findsNothing);

      await tester.enterText(find.byType(TextField), '改过的书名');
      await tester.tap(find.widgetWithText(TextButton, '导入'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(result, '改过的书名');
    });

    testWidgets('v2 文件显示已识别的小说设定摘要', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showOutlineTxtImportDialog(
                  context,
                  fileName: '结构化大纲.txt',
                  initialTitle: '结构化书',
                  charCount: 200,
                  eventCount: 6,
                  preview: '══ 大事件1：开端 ══',
                  settingSummary: '类型、世界观 · 人物档案 2 人',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('已识别小说设定：类型、世界观 · 人物档案 2 人'), findsOneWidget);
      // 摘要与事件数提示同时可见
      expect(find.text('共 200 字 · 识别到 6 个事件'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('事件数为 0 时给提示，取消返回 null', (tester) async {
      String? result = '未点击';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showOutlineTxtImportDialog(
                  context,
                  fileName: '没有事件.txt',
                  initialTitle: '默认书名',
                  charCount: 12,
                  eventCount: 0,
                  preview: '一些普通文字',
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('没有识别到大纲事件，仍可导入后手动整理'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
