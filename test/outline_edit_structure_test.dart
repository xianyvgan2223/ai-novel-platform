import 'package:flutter_test/flutter_test.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';

/// 「大纲编辑」的增删事件：卡片列表与大纲正文**始终一起改**，
/// 两者第 N 个事件必须是同一条；增删也要能撤销 / 反撤销。
void main() {
  /// 三个事件：大事件甲 / 小事件乙 / 大事件丙
  List<OutlineChapter> chapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 7,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '甲',
      eventSummary: '甲的概要',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 7,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '乙',
      eventSummary: '乙的概要',
    ),
    OutlineChapter(
      id: 3,
      outlineId: 7,
      eventIndex: 3,
      eventType: 'major',
      eventTitle: '丙',
      eventSummary: '丙的概要',
    ),
  ];

  final content = [
    '══ 大事件1：甲 ══',
    '甲的概要',
    '',
    '○ 小事件1：乙',
    '乙的概要',
    '',
    '══ 大事件2：丙 ══',
    '丙的概要',
  ].join('\n');

  OutlineEditController build() {
    // outline.id 传 null：本组用例只验证内存里的结构改动与历史，
    // 不落库（落库由 OutlineChapterDbHelper 的方法承担）
    final ctrl = OutlineEditController(OutlineRecord(title: 'T', content: content));
    ctrl.init(chapters());
    return ctrl;
  }

  /// 正文里的第 N 个事件标题
  String textTitle(OutlineEditController c, int n) =>
      parseOutlineEvents(c.outlineContent, outlineId: 7)[n - 1].eventTitle;

  group('添加事件', () {
    test('末尾追加：卡片与大纲正文同步多出一条', () {
      final c = build();
      c.addEvent(index: c.drafts.length, isMajor: true, title: '丁');

      expect(c.drafts.length, 4);
      expect(c.drafts[3].title, '丁');
      expect(c.drafts[3].isMajor, isTrue);
      expect(c.drafts[3].isNew, isTrue);
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 4);
      expect(textTitle(c, 4), '丁');
      expect(textTitle(c, 3), '丙'); // 前面的条目没被动过
      expect(c.hasUnsaved, isTrue);
      expect(c.hasStructureChanges, isTrue);
      c.dispose();
    });

    test('插到中间：第 N 张卡片就是正文里的第 N 个事件', () {
      final c = build();
      c.addEvent(index: 1, isMajor: false, title: '夹心');

      expect(c.drafts.map((d) => d.title).toList(), ['甲', '夹心', '乙', '丙']);
      expect(
        parseOutlineEvents(c.outlineContent, outlineId: 7)
            .map((e) => e.eventTitle)
            .toList(),
        ['甲', '夹心', '乙', '丙'],
      );
      // 序号是重编过的：草稿顺序与正文顺序逐条对齐
      for (var i = 0; i < c.drafts.length; i++) {
        expect(c.drafts[i].eventIndex, i + 1);
        expect(textTitle(c, i + 1), c.drafts[i].title);
      }
      c.dispose();
    });

    test('标题留空时给占位标题，避免写出「大事件3：」这类断行', () {
      final c = build();
      c.addEvent(index: 3, isMajor: true);
      expect(c.drafts[3].title, kNewEventTitle);
      // 占位标题必须真的写进正文，否则重解析时这一条会消失
      expect(textTitle(c, 4), kNewEventTitle);
      c.dispose();
    });

    test('新增大事件后，卡片上的大事件序号按全篇连续重编', () {
      final c = build();
      // 甲 = 大事件1、丙 = 大事件2
      expect(c.majorNumberOfDraft(c.drafts[0]), 1);
      expect(c.majorNumberOfDraft(c.drafts[2]), 2);
      expect(c.majorNumberOfDraft(c.drafts[1]), isNull); // 小事件没有大事件序号

      c.addEvent(index: 1, isMajor: true, title: '新大事件');
      expect(c.majorNumberOfDraft(c.drafts[0]), 1);
      expect(c.majorNumberOfDraft(c.drafts[1]), 2); // 刚加的那条
      expect(c.majorNumberOfDraft(c.drafts[3]), 3); // 丙顺延到 3
      c.dispose();
    });
  });

  group('删除事件', () {
    test('删小事件：卡片与大纲正文同步少一条', () {
      final c = build();
      c.deleteEvent(c.drafts[1]);

      expect(c.drafts.map((d) => d.title).toList(), ['甲', '丙']);
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 2);
      expect(textTitle(c, 1), '甲');
      expect(textTitle(c, 2), '丙');
      expect(c.outlineContent.contains('乙'), isFalse);
      expect(c.hasStructureChanges, isTrue);
      c.dispose();
    });

    test('删大事件：名下小事件不会被连带删掉', () {
      final c = build();
      c.deleteEvent(c.drafts[0]); // 大事件「甲」
      expect(c.drafts.map((d) => d.title).toList(), ['乙', '丙']);
      expect(textTitle(c, 1), '乙');
      c.dispose();
    });

    test('deleteImpact 如实报出正文与名下小事件的数量', () {
      final c = build();
      final impact = c.deleteImpact(c.drafts[0]); // 大事件甲
      expect(impact.hasContent, isFalse);
      expect(impact.childCount, 1); // 名下有小事件乙
      expect(impact.childContentCount, 0);

      final minorImpact = c.deleteImpact(c.drafts[1]);
      expect(minorImpact.childCount, 0); // 小事件名下没有更小的
      expect(minorImpact.hasContent, isFalse);
      c.dispose();
    });
  });

  group('删除事件：序号错位 / 幽灵行也不误删', () {
    // 正文里的顺序固定是 甲(1) / 乙(2) / 丙(3) / 丁(4)
    final text = [
      '══ 大事件1：甲 ══',
      '甲的概要',
      '',
      '○ 小事件1：乙',
      '乙的概要',
      '',
      '○ 小事件2：丙',
      '丙的概要',
      '',
      '══ 大事件2：丁 ══',
      '丁的概要',
    ].join('\n');

    test('库里序号与正文错位：删掉的仍是点的那条小事件，旁边的不动', () {
      // 库里的 event_index 与正文顺序对不上（历史上「章节选择页拿旧快照校正
      // 结构」留下的错位）：界面上第 3 张卡片是「乙」，正文里第 3 个事件却是「丙」。
      // 旧实现按序号硬删，会把「丙」从大纲正文里抹掉——用户看到的就是
      // 「删了乙，乙还在、丙反而没了」。
      final ctrl = OutlineEditController(
        OutlineRecord(title: 'T', content: text),
      );
      ctrl.init([
        OutlineChapter(
          id: 4,
          outlineId: 7,
          eventIndex: 1,
          eventType: 'major',
          eventTitle: '丁',
          eventSummary: '丁的概要',
        ),
        OutlineChapter(
          id: 1,
          outlineId: 7,
          eventIndex: 2,
          eventType: 'major',
          eventTitle: '甲',
          eventSummary: '甲的概要',
        ),
        OutlineChapter(
          id: 2,
          outlineId: 7,
          eventIndex: 3,
          eventType: 'minor',
          eventTitle: '乙',
          eventSummary: '乙的概要',
        ),
        OutlineChapter(
          id: 3,
          outlineId: 7,
          eventIndex: 4,
          eventType: 'minor',
          eventTitle: '丙',
          eventSummary: '丙的概要',
        ),
      ]);

      ctrl.deleteEvent(ctrl.drafts[2]); // 界面上的「乙」

      expect(ctrl.outlineContent.contains('乙'), isFalse, reason: '点的那条要删掉');
      expect(
        parseOutlineEvents(ctrl.outlineContent, outlineId: 7)
            .map((e) => e.eventTitle)
            .toList(),
        ['甲', '丙', '丁'],
        reason: '只该少掉「乙」，别的事件一条都不能少',
      );
      expect(ctrl.drafts.map((d) => d.title).toList(), ['丁', '甲', '丙']);
      ctrl.dispose();
    });

    test('正文里没有这条（幽灵行）：卡片照删，正文不被动', () {
      // 正文里只有 甲 / 乙，库里却多出一条「幽灵」——旧实现按序号删会把
      // 正文里的某一条连带删掉，而且幽灵行本身删不掉（下次校正又回来）
      final ctrl = OutlineEditController(
        OutlineRecord(
          title: 'T',
          content: [
            '══ 大事件1：甲 ══',
            '甲的概要',
            '',
            '○ 小事件1：乙',
            '乙的概要',
          ].join('\n'),
        ),
      );
      ctrl.init([
        OutlineChapter(
          id: 1,
          outlineId: 7,
          eventIndex: 1,
          eventType: 'major',
          eventTitle: '甲',
          eventSummary: '甲的概要',
        ),
        OutlineChapter(
          id: 2,
          outlineId: 7,
          eventIndex: 2,
          eventType: 'minor',
          eventTitle: '乙',
          eventSummary: '乙的概要',
        ),
        OutlineChapter(
          id: 3,
          outlineId: 7,
          eventIndex: 3,
          eventType: 'minor',
          eventTitle: '幽灵',
          eventSummary: '库里多出来的',
        ),
      ]);

      final before = ctrl.outlineContent;
      ctrl.deleteEvent(ctrl.drafts[2]);

      expect(ctrl.outlineContent, before, reason: '正文里没有它，一行都不该动');
      expect(ctrl.drafts.map((d) => d.title).toList(), ['甲', '乙']);
      expect(parseOutlineEvents(ctrl.outlineContent, outlineId: 7).length, 2);
      expect(ctrl.hasStructureChanges, isTrue, reason: '库里那行要在保存时删掉');
      ctrl.dispose();
    });
  });

  group('只勾选其中几章时：增删事件必须按正文里的真实位置', () {
    // 全篇 5 个事件：甲 / 乙 / 丙 / 丁 / 戊；本次只编辑其中的「丁」
    final whole = [
      '══ 大事件1：甲 ══',
      '甲的概要',
      '',
      '○ 小事件1：乙',
      '乙的概要',
      '',
      '══ 大事件2：丙 ══',
      '丙的概要',
      '',
      '○ 小事件2：丁',
      '丁的概要',
      '',
      '══ 大事件3：戊 ══',
      '戊的概要',
    ].join('\n');

    OutlineChapter ch(int id, int index, String type, String title) =>
        OutlineChapter(
          id: id,
          outlineId: 7,
          eventIndex: index,
          eventType: type,
          eventTitle: title,
          eventSummary: '$title的概要',
        );

    /// 只把「丁」交给编辑页（章节列表页的「编辑」按钮就是只传一章）
    OutlineEditController buildSubset() {
      final ctrl = OutlineEditController(
        OutlineRecord(title: 'T', content: whole),
      );
      ctrl.init([ch(4, 4, 'minor', '丁')]);
      return ctrl;
    }

    List<String> titles(OutlineEditController c) => parseOutlineEvents(
      c.outlineContent,
      outlineId: 7,
    ).map((e) => e.eventTitle).toList();

    test('在「丁」上方新增大事件：插在丁前面，而不是整篇大纲的开头', () {
      final c = buildSubset();
      c.addEvent(index: 0, isMajor: true, title: '小鹿'); // 页面上点的是「上方」

      expect(
        titles(c),
        ['甲', '乙', '丙', '小鹿', '丁', '戊'],
        reason: '新事件必须紧挨着它上面那张卡片，前面的甲/乙/丙一条都不能被顶掉',
      );
      // 序号是**全局**的：新事件是第 4 个，丁顺延成第 5 个
      expect(c.drafts[0].eventIndex, 4);
      expect(c.drafts[1].eventIndex, 5);
      c.dispose();
    });

    test('在「丁」下方新增大事件：插在丁后面，戊不受影响', () {
      final c = buildSubset();
      c.addEvent(index: 1, isMajor: true, title: '小鹿'); // 页面上点的是「下方」

      expect(titles(c), ['甲', '乙', '丙', '丁', '小鹿', '戊']);
      expect(c.drafts[0].eventIndex, 4);
      expect(c.drafts[1].eventIndex, 5);
      c.dispose();
    });

    test('只编辑一章时新增的小事件同样落在正确位置', () {
      final c = buildSubset();
      c.addEvent(index: 0, isMajor: false, title: '小鹿');

      expect(titles(c), ['甲', '乙', '丙', '小鹿', '丁', '戊']);
      expect(c.drafts[0].isMajor, isFalse);
      c.dispose();
    });

    test('只编辑一章时删除这张卡片：删的是它自己，前后条目都在', () {
      final c = buildSubset();
      c.deleteEvent(c.drafts[0]); // 「丁」

      expect(titles(c), ['甲', '乙', '丙', '戊']);
      expect(c.outlineContent.contains('丁'), isFalse);
      c.dispose();
    });

    test('只勾选两章（隔很远）时点「下方」：紧接在锚点后面，不是下一张卡片前面', () {
      // 只勾选「丙」（全篇第 3 个）和「戊」（全篇第 5 个），在「丙」下方新增：
      // 位置必须是紧跟丙之后，而不是戊之前（旧实现会算成戊的位置）
      final ctrl = OutlineEditController(
        OutlineRecord(title: 'T', content: whole),
      );
      ctrl.init([ch(3, 3, 'major', '丙'), ch(5, 5, 'major', '戊')]);
      ctrl.addEvent(index: 1, isMajor: false, title: '小鹿', below: true);

      expect(titles(ctrl), ['甲', '乙', '丙', '小鹿', '丁', '戊']);
      expect(ctrl.drafts.map((d) => d.title).toList(), ['丙', '小鹿', '戊']);
      ctrl.dispose();
    });

    test('在第三个大事件上「下方」加小事件：落在大事件3名下，不跑到大事件1', () {
      // 只勾选「戊」（大事件3）：在它下方加一条小事件，
      // 位置必须在它后面（大事件3 名下），而不是整篇大纲的最前面
      final ctrl = OutlineEditController(
        OutlineRecord(title: 'T', content: whole),
      );
      ctrl.init([ch(5, 5, 'major', '戊')]);
      ctrl.addEvent(index: 1, isMajor: false, title: '小鹿', below: true);

      expect(titles(ctrl), ['甲', '乙', '丙', '丁', '戊', '小鹿']);
      expect(ctrl.drafts[1].eventIndex, 6);
      ctrl.dispose();
    });

    test('大事件序号按全篇算，不是按「勾选的这几章」算', () {
      // 只编辑「戊」（全篇第 3 个大事件）：它必须显示「大事件3」，
      // 而不是因为页面上只勾了一章就显示「大事件1」
      final ctrl = OutlineEditController(
        OutlineRecord(title: 'T', content: whole),
      );
      ctrl.init([ch(5, 5, 'major', '戊')]);
      expect(ctrl.majorNumberOfDraft(ctrl.drafts[0]), 3);
      ctrl.dispose();
    });

    test('只编辑一章时新增一个大事件：新卡片的大事件序号也是全局的', () {
      final c = buildSubset();
      c.addEvent(index: 0, isMajor: true, title: '小鹿'); // 插在「丁」上方

      // 全篇：甲(大1) 乙 丙(大2) 小鹿(大3) 丁 戊(大4)
      expect(c.majorNumberOfDraft(c.drafts[0]), 3);
      expect(c.drafts[1].title, '丁');
      expect(c.drafts[1].isMajor, isFalse);
      c.dispose();
    });
  });

  group('增删事件的撤销 / 反撤销', () {
    test('撤销「添加」会把新增的卡片去掉，反撤销再放回来', () {
      final c = build();
      c.addEvent(index: 1, isMajor: false, title: '夹心');
      expect(c.drafts.length, 4);

      c.undo();
      expect(c.drafts.map((d) => d.title).toList(), ['甲', '乙', '丙']);
      expect(c.canRedo, isTrue);

      c.redo();
      expect(c.drafts.map((d) => d.title).toList(), ['甲', '夹心', '乙', '丙']);
      c.dispose();
    });

    test('撤销「删除」会把卡片恢复回来，标题与概要都在', () {
      final c = build();
      c.deleteEvent(c.drafts[1]); // 删掉小事件乙
      expect(c.drafts.length, 2);

      c.undo();
      expect(c.drafts.map((d) => d.title).toList(), ['甲', '乙', '丙']);
      expect(c.drafts[1].summary, '乙的概要');
      expect(c.drafts[1].isDirty, isFalse); // 恢复出来的卡片不该显示「已修改」
      c.dispose();
    });

    test('删除后撤销，再保存时标题与概要都还在', () {
      final c = build();
      c.deleteEvent(c.drafts[1]);
      c.undo();
      c.redo();
      c.undo();
      expect(c.drafts[1].title, '乙');
      expect(c.drafts[1].summary, '乙的概要');
      expect(c.drafts[1].isDirty, isFalse);
      c.dispose();
    });

    // ---- 正文也要跟着撤销：否则「撤销找回」只是把卡片放回来，
    // 正文里那一行仍然缺着，保存时按序号写回会改错行，
    // 下次按正文校正结构时这一条又消失（等于撤销没生效） ----
    test('撤销「删除」：正文里的那一行也放回来，且不影响别的条目', () {
      final c = build();
      c.deleteEvent(c.drafts[1]); // 小事件「乙」
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 2);

      c.undo();
      expect(c.drafts.map((d) => d.title).toList(), ['甲', '乙', '丙']);
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 3);
      expect(textTitle(c, 2), '乙');
      expect(
        parseOutlineEvents(
          c.outlineContent,
          outlineId: 7,
        )[1].eventSummary,
        '乙的概要',
      );
      expect(c.hasStructureChanges, isFalse);
      c.dispose();
    });

    test('撤销「添加」：正文里新增的那一行也去掉', () {
      final c = build();
      c.addEvent(index: 1, isMajor: false, title: '夹心');
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 4);

      c.undo();
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 3);
      expect(c.outlineContent.contains('夹心'), isFalse);
      expect(textTitle(c, 2), '乙');

      c.redo(); // 反撤销把它放回来
      expect(c.drafts.map((d) => d.title).toList(), ['甲', '夹心', '乙', '丙']);
      expect(parseOutlineEvents(c.outlineContent, outlineId: 7).length, 4);
      expect(textTitle(c, 2), '夹心');
      c.dispose();
    });
  });

  testWidgets('文本改动与结构改动可以分别撤销', (tester) async {
    final c = build();

    // 先改一条标题（防抖结束后并入撤销栈）
    c.drafts[0].titleCtrl.text = '甲改';
    await tester.pump(const Duration(milliseconds: 700));
    expect(c.canUndo, isTrue);

    // 再新增一条：这一步不该把上面的文本改动从撤销栈里挤掉
    c.addEvent(index: 3, isMajor: true, title: '丁');
    expect(c.drafts.length, 4);

    c.undo(); // 撤销「新增」
    expect(c.drafts.map((d) => d.title).toList(), ['甲改', '乙', '丙']);
    expect(c.canUndo, isTrue); // 标题改动那一步还在

    c.undo(); // 撤销标题改动
    expect(c.drafts[0].title, '甲');
    expect(c.canRedo, isTrue);

    // 反撤销逐步走回去
    c.redo();
    expect(c.drafts[0].title, '甲改');
    c.redo();
    expect(c.drafts.map((d) => d.title).toList(), ['甲改', '乙', '丙', '丁']);
    c.dispose();
  });

  testWidgets('撤销新增后再保存：结构回到原样，不会误报未保存', (tester) async {
    final c = build();
    c.addEvent(index: 1, isMajor: false, title: '夹心');
    expect(c.hasStructureChanges, isTrue);

    c.undo();
    expect(c.drafts.map((d) => d.title).toList(), ['甲', '乙', '丙']);
    // 结构已经回到已落库的样子：底部不该再显示「有事件增删未保存」
    expect(c.hasStructureChanges, isFalse);
    expect(c.hasUnsaved, isFalse);
    c.dispose();
  });

  test('删除后撤销：保存时不会再删那一行', () {
    final c = build();
    c.deleteEvent(c.drafts[1]);
    expect(c.hasStructureChanges, isTrue);

    c.undo();
    // 卡片回来了，就不该再算作「待删除」（否则保存会把刚恢复的事件删掉）
    expect(c.drafts.map((d) => d.title).toList(), ['甲', '乙', '丙']);
    expect(c.hasStructureChanges, isFalse);
    c.dispose();
  });

  // ---- 真机自检抓出来的两个回归点（单元测试原先漏掉了这两条路径） ----

  group('保存计数：新增的事件也要算进「保存了几章」', () {
    test('只新增事件时 saveAll 不能返回 0', () async {
      // outline.id 为 null，结构落库直接返回 0；这里验证的是
      // 「新增行在 INSERT 时已经写好标题/概要、随后 markSaved 清掉了 isDirty」
      // 这条路径不会让保存结果变成 0（真机上会提示「没有需要保存的修改」）
      final c = build();
      c.addEvent(index: 1, isMajor: false, title: '夹心');
      expect(c.hasStructureChanges, isTrue);

      await c.saveAll();
      expect(c.saveError, isEmpty);
      // 新卡片的标题/概要在插行时就写进去了，保存后不该还是「已修改」
      expect(c.drafts[1].isDirty, isFalse);
      expect(c.hasStructureChanges, isFalse);
      c.dispose();
    });
  });

  group('大事件序号：不依赖「全篇章节是否已读回来」', () {
    test('新增一个大事件后，后面的大事件序号当场顺延', () {
      final c = build();
      // init 之后还没读到全篇章节（outline.id 为 null，_loadContext 直接返回），
      // 此时大事件序号必须按当前草稿顺序现算，不能查旧的 id 映射表
      expect(c.majorNumberOfDraft(c.drafts[0]), 1);
      expect(c.majorNumberOfDraft(c.drafts[2]), 2);

      c.addEvent(index: 1, isMajor: true, title: '插入的大事件');

      expect(c.drafts.map((d) => d.title).toList(), ['甲', '插入的大事件', '乙', '丙']);
      expect(c.majorNumberOfDraft(c.drafts[1]), 2, reason: '刚插入的大事件是第 2 个');
      expect(
        c.majorNumberOfDraft(c.drafts[3]),
        3,
        reason: '后面的丙必须顺延成第 3 个，不能还是 2',
      );
      c.dispose();
    });

    test('删掉最前面的大事件后，序号从 1 重新排', () {
      final c = build();
      c.deleteEvent(c.drafts[0]); // 删掉大事件「甲」
      expect(c.drafts.map((d) => d.title).toList(), ['乙', '丙']);
      expect(c.majorNumberOfDraft(c.drafts[0]), isNull, reason: '小事件没有大事件序号');
      expect(c.majorNumberOfDraft(c.drafts[1]), 1, reason: '丙成了第 1 个大事件');
      c.dispose();
    });
  });
}
