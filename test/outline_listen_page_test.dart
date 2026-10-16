import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/controller/outline_listen_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/tts_engine.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/tts_engine_fake.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/view/page/outline_listen_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「听大纲改名」页面：**一个事件一张卡片** / 播控 / 撤回 / 一键改名面板。
///
/// 一律注入 [FakeTtsEngine]，章节与大纲记录都**不落库**
/// （`outline.id` 为 null、章节 id 为 0）：测试环境没有 sqflite，
/// 这样保存与改名走「只更新内存」那条路，逻辑照样能验。
void main() {
  OutlineChapter ch(int index, String type, String title, String summary) =>
      OutlineChapter(
        outlineId: 0,
        eventIndex: index,
        eventType: type,
        eventTitle: title,
        eventSummary: summary,
      );

  /// 打开听大纲改名页，返回页面在用的控制器
  Future<({OutlineListenController ctrl, FakeTtsEngine engine})> pumpPage(
    WidgetTester tester, {
    String content = '',
    String protagonist = '李云飞',
  }) async {
    final engine = FakeTtsEngine();
    final ctrl = OutlineListenController(
      OutlineRecord(
        title: '测试小说',
        content: content,
        protagonist: protagonist,
        foreshadows: '',
      ),
      engine: engine,
    );
    ctrl.init([
      ch(1, 'major', '初入江湖', '李云飞在青阳城醒来。\n他失去了记忆。'),
      ch(2, 'minor', '拜师', '李云飞拜入青云宗。'),
    ], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (ctrl: ctrl, engine: engine);
  }

  /// 改名面板里的元素（页面本身也有一堆 TextField / Text，必须限定在面板内找）
  Finder inSheet(Finder matching) =>
      find.descendant(of: find.byType(BottomSheet), matching: matching);

  Finder sheetField(int index) => inSheet(find.byType(TextField)).at(index);

  /// 卡片上的播放按钮（播控条上那个没有 tooltip，卡片这个有）
  Finder cardPlay(int index) =>
      find.byTooltip('从这一个事件开始读').at(index);

  testWidgets('一个事件一张卡片：标题与概要在同一张卡片里', (tester) async {
    await pumpPage(tester);

    // 第一张卡片：类型标签、标题、**整段概要**（含换行）都在同一张卡片里
    expect(find.text('初入江湖'), findsOneWidget);
    expect(find.text('李云飞在青阳城醒来。\n他失去了记忆。'), findsOneWidget);
    expect(find.textContaining('大事件1'), findsWidgets);
    // 每张卡片有「标题 + 概要」两个输入框（视口内至少渲染出第一张）
    expect(find.byType(TextField), findsAtLeastNWidgets(2));

    // 第二张卡片在当前视口下方：滚下去也应该是一整张卡片（标题 + 概要）
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('拜师'), findsOneWidget);
    expect(find.text('李云飞拜入青云宗。'), findsOneWidget);
  });

  testWidgets('点某张卡片的播放按钮从这一个事件开始读', (tester) async {
    final env = await pumpPage(tester);

    // 第 2 张卡片的播放按钮
    await tester.tap(cardPlay(1));
    await tester.pumpAndSettle();

    expect(env.engine.spoken.single, startsWith('小事件2，拜师'));
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('朗读中'), findsOneWidget);
  });

  testWidgets('读完一个事件自动读下一个，进度与标记跟着走', (tester) async {
    final env = await pumpPage(tester);

    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    env.engine.finishCurrent();
    await tester.pumpAndSettle();

    expect(env.engine.spoken.length, 2);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('下一个 / 上一个按钮切换事件', (tester) async {
    final env = await pumpPage(tester);

    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一个事件'));
    await tester.pumpAndSettle();
    expect(env.engine.spoken.last, startsWith('小事件2，拜师'));

    await tester.tap(find.byTooltip('上一个事件'));
    await tester.pumpAndSettle();
    expect(env.engine.spoken.last, startsWith('大事件1，初入江湖'));
  });

  testWidgets('就地改一张卡片后底栏显示未保存，点保存后清零', (tester) async {
    final env = await pumpPage(
      tester,
      content: '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  他失去了记忆。

○ 小事件2：拜师
  李云飞拜入青云宗。
''',
    );
    env.ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  他失去了记忆。

○ 小事件2：拜师
  李云飞拜入青云宗。
''';

    expect(find.text('所有改动已保存'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '初入江湖（改）');
    await tester.pumpAndSettle();

    expect(find.text('1 处改动未保存'), findsOneWidget);
    expect(find.text('已改'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('所有改动已保存'), findsOneWidget);
    expect(env.ctrl.outlineContent, contains('大事件1：初入江湖（改）'));
    // 概要没有被标题改动牵连
    expect(env.ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
  });

  testWidgets('朗读出错时给出提示条与重试入口', (tester) async {
    final env = await pumpPage(tester);

    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    env.engine.failCurrent('朗读失败（测试）');
    await tester.pumpAndSettle();

    expect(find.text('朗读失败（测试）'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.text('朗读失败（测试）'), findsNothing);
  });

  testWidgets('朗读出错时点「重试」：先重建引擎再读，不再是空点一下', (tester) async {
    final env = await pumpPage(tester);

    // 引擎暂时不可用 → 报错
    env.engine.available = false;
    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(env.ctrl.playing, isFalse);

    // 用户去系统里装好 / 启用好引擎（假引擎里就是恢复 available），回来点重试
    env.engine.available = true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(env.engine.resetCount, 1); // 「重试」真的把旧引擎丢了重建
    expect(env.engine.spoken, isNotEmpty); // 并且真的读出来了
    expect(env.ctrl.playing, isTrue);
  });

  testWidgets('提示条上有「去系统设置」入口（本机装/换语音引擎都在这）', (tester) async {
    final env = await pumpPage(tester);

    env.engine.available = false;
    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();

    expect(find.text('去系统设置'), findsOneWidget);
    await tester.tap(find.text('去系统设置'));
    await tester.pumpAndSettle();

    expect(env.engine.openSettingsCount, 1); // 按钮真的接到了引擎通道
  });

  testWidgets('本机一个引擎都没有时：给「去商店装引擎」一键路（魅族 18 那种机器）', (tester) async {
    // 真机场景：系统「文字转语音」页里首选引擎是「无」，用户到那儿也没东西可选，
    // 必须先在手机商店里装一个引擎 App —— 所以第一步该是「去商店搜语音引擎」
    final engine = FakeTtsEngine(available: false)
      ..status = const TtsEngineStatus(zhState: 'no_engine');
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: engine,
    );
    ctrl.init([ch(1, 'major', '初入江湖', '李云飞在青阳城醒来。')], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 进页面就有商店入口（体检提示条上）
    expect(find.text('去商店装引擎'), findsOneWidget);
    await tester.tap(find.text('去商店装引擎'));
    await tester.pumpAndSettle();
    expect(engine.openStoreCount, 1);
    expect(engine.lastStoreQuery, '语音引擎');

    // 点播放失败后，错误条上也留着这条路
    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('去商店装引擎'), findsOneWidget);
  });

  testWidgets('进页面就体检：本机没有语音引擎时提前说明，并给「去系统设置」', (tester) async {
    final engine = FakeTtsEngine(available: false)
      ..status = const TtsEngineStatus(zhState: 'no_engine');
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: engine,
    );
    ctrl.init([ch(1, 'major', '初入江湖', '李云飞在青阳城醒来。')], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 还没点播放就把问题说清楚，并给一个能走下去的入口
    expect(find.textContaining('没有可用的「文字转语音」引擎'), findsOneWidget);
    expect(find.text('去系统设置'), findsOneWidget);

    await tester.tap(find.text('去系统设置'));
    await tester.pumpAndSettle();
    expect(engine.openSettingsCount, 1);
  });

  testWidgets('朗读设置面板里能选引擎：默认跟随系统，也能指定内置语音/系统引擎', (tester) async {
    final env = await pumpPage(tester);

    await tester.tap(find.byTooltip('朗读设置'));
    await tester.pumpAndSettle();

    // 面板里有「朗读引擎」这一段，且三个选项都在
    expect(find.text('朗读引擎'), findsOneWidget);
    expect(find.textContaining('跟随系统'), findsOneWidget);
    expect(find.textContaining('内置离线语音'), findsOneWidget);
    expect(find.textContaining('com.reecedunn.espeak'), findsOneWidget);

    // 默认选中的是「跟随系统」
    expect(env.ctrl.selectedEngineId, TtsEngineOption.autoId);

    // 选内置语音 → 控制器记住选择（页面据此把朗读固定到内置引擎）
    await tester.tap(find.textContaining('内置离线语音'));
    await tester.pumpAndSettle();
    expect(env.ctrl.selectedEngineId, TtsEngineOption.builtinId);

    // 再选某个系统引擎（例如装了 eSpeak）→ 同样记下来
    await tester.tap(find.textContaining('com.reecedunn.espeak'));
    await tester.pumpAndSettle();
    expect(env.ctrl.selectedEngineId, 'com.reecedunn.espeak');
  });

  testWidgets('没有可用语音引擎时如实提示，不假装在播', (tester) async {
    final engine = FakeTtsEngine(available: false);
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: engine,
    );
    ctrl.init([ch(1, 'major', '初入江湖', '李云飞在青阳城醒来。')], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();

    // 引擎不可用：播控条上仍是「播放」图标（没有变成暂停），也没读任何内容
    expect(find.byIcon(Icons.play_arrow), findsNWidgets(2)); // 卡片 + 播控条
    expect(find.byIcon(Icons.pause), findsNothing);
    expect(engine.spoken, isEmpty);
    expect(find.textContaining('语音引擎'), findsWidgets);
  });

  testWidgets('朗读设置面板能改语速与朗读范围', (tester) async {
    final env = await pumpPage(tester);

    await tester.tap(find.byTooltip('朗读设置'));
    await tester.pumpAndSettle();

    expect(find.text('朗读设置'), findsOneWidget);
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(env.ctrl.settings.rate, 1.5);

    await tester.tap(find.text('只读标题'));
    await tester.pumpAndSettle();
    expect(env.ctrl.settings.mode.name, 'titleOnly');
    // 换朗读范围不改变卡片数量：一个事件始终一张卡片
    expect(env.ctrl.segments.length, 2);
    expect(find.byType(TextField), findsNWidgets(4));
  });

  testWidgets('没有解析出事件时给出可执行的下一步（不是一片空白）', (tester) async {
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: FakeTtsEngine(),
    );
    // 空章表：页面必须说清「一条都没有」，并指出去哪儿生成
    ctrl.init(<OutlineChapter>[], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这条大纲还没有可朗读的事件'), findsOneWidget);
    expect(find.textContaining('一键生成大纲'), findsOneWidget);
    // 没有内容时不显示底栏（没有可保存的东西）
    expect(find.text('所有改动已保存'), findsNothing);
  });

  testWidgets('上方播控区可以收起与展开（按钮在顶栏，两向切换）', (tester) async {
    final env = await pumpPage(tester);

    // 展开态：一行播控（上一个 / 下一个 / 语速 / 进度都在）
    expect(find.byTooltip('上一个事件'), findsOneWidget);
    expect(find.byTooltip('下一个事件'), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);
    expect(env.ctrl.playerCollapsed, isFalse);

    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    expect(env.engine.spoken, isNotEmpty);

    // 收起：播控条整块只剩一条窄条（按钮在顶栏，同一个位置变成「展开」）
    await tester.tap(find.byTooltip('收起播放控制'));
    await tester.pumpAndSettle();

    expect(env.ctrl.playerCollapsed, isTrue);
    // 「展开」按钮出现两处：顶栏那个（同一个位置切换）与窄条上的箭头
    expect(find.byTooltip('展开播放控制'), findsNWidgets(2));
    expect(find.byTooltip('上一个事件'), findsNothing);
    expect(find.byTooltip('下一个事件'), findsNothing);
    expect(find.text('1.0x'), findsNothing);
    expect(find.byIcon(Icons.pause), findsNothing);
    expect(find.textContaining('个事件'), findsNothing);
    // 卡片上的播放按钮还在（那是「从这一个事件开始读」）
    expect(cardPlay(0), findsOneWidget);

    // 窄条上的箭头放下播控
    await tester.tap(find.byTooltip('展开播放控制').last);
    await tester.pumpAndSettle();
    expect(env.ctrl.playerCollapsed, isFalse);
    expect(find.byTooltip('下一个事件'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);

    // 顶栏的按钮也能再收起来（同一个位置两向切换）
    await tester.tap(find.byTooltip('收起播放控制'));
    await tester.pumpAndSettle();
    expect(env.ctrl.playerCollapsed, isTrue);
  });

  testWidgets('360dp 窄屏下收起态放得下（长事件标题与长概要）', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctrl = OutlineListenController(
      OutlineRecord(
        title: '一个非常非常长的书名用来把播控条这一行撑到极限看会不会溢出',
        content: '',
        protagonist: '',
      ),
      engine: FakeTtsEngine(),
    );
    ctrl.init([
      ch(1, 'major', '一个很长很长的大事件标题用来挤这一行', '概要也写得比较长，用来把这一行撑满看看会不会溢出。'),
    ], reload: false);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineListenPage(
          outline: ctrl.outline,
          chapters: const [],
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(ctrl.segments.length, 1);
    await tester.tap(cardPlay(0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1/1'), findsOneWidget);

    // 收起（顶栏按钮；窄条上也有一个箭头，收起后两处都能展开）
    final arrowAfterCollapse = find.byTooltip('展开播放控制');
    await tester.tap(find.byTooltip('收起播放控制'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(ctrl.playerCollapsed, isTrue);
    expect(arrowAfterCollapse, findsNWidgets(2)); // 顶栏 + 窄条
    expect(find.text('1/1'), findsNothing);

    // 收起后仍不溢出，并且能放下来
    await tester.tap(arrowAfterCollapse.last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(ctrl.playerCollapsed, isFalse);
  });

  testWidgets('顶栏「撤回 / 取消撤回」：无历史时置灰，改完可用，点撤回回到改前', (tester) async {
    final env = await pumpPage(tester);

    IconButton buttonWith(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    // 刚进页面：两个按钮都在，但都是灰的
    expect(env.ctrl.canUndo, isFalse);
    expect(buttonWith(Icons.undo).onPressed, isNull);
    expect(buttonWith(Icons.redo).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '初入江湖（改）');
    await tester.pumpAndSettle();

    // 改完可以撤回，「取消撤回」还是灰的
    expect(buttonWith(Icons.undo).onPressed, isNotNull);
    expect(buttonWith(Icons.redo).onPressed, isNull);

    await tester.tap(find.byTooltip('撤回'));
    await tester.pumpAndSettle();

    expect(env.ctrl.segments[0].title, '初入江湖');
    // 撤回后反过来：「取消撤回」可用、撤回置灰
    expect(buttonWith(Icons.undo).onPressed, isNull);
    expect(buttonWith(Icons.redo).onPressed, isNotNull);

    await tester.tap(find.byTooltip('取消撤回'));
    await tester.pumpAndSettle();

    expect(env.ctrl.segments[0].title, '初入江湖（改）');
    expect(buttonWith(Icons.undo).onPressed, isNotNull);
    expect(buttonWith(Icons.redo).onPressed, isNull);
  });

  testWidgets('底栏不再放「一键改名」（与顶栏重复），改名入口只在顶栏', (tester) async {
    await pumpPage(tester);

    // 底栏只有「未保存状态 + 保存」
    expect(find.text('一键改名'), findsNothing);
    expect(find.text('改名'), findsOneWidget);

    await tester.tap(find.text('改名'));
    await tester.pumpAndSettle();
    expect(find.text('替换表'), findsOneWidget);
  });

  group('一键改名面板', () {
    testWidgets('打开就列出候选专名，点一下加入替换表并显示影响预览', (tester) async {
      final env = await pumpPage(
        tester,
        content: '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  李云飞拜入青云宗。
''',
      );

      await tester.tap(find.text('改名'));
      await tester.pumpAndSettle();

      expect(find.text('替换表'), findsOneWidget);
      expect(find.text('可能的专名'), findsOneWidget);
      expect(find.textContaining('点一下加入替换表'), findsOneWidget);

      // 点候选加入替换表
      await tester.tap(inSheet(find.text('李云飞')));
      await tester.pumpAndSettle();

      // 影响预览实时算出来：会影响 1 个事件、替换 2 处
      expect(find.textContaining('会影响 1 个事件、替换 2 处'), findsOneWidget);
      // 候选已被占用（打勾）
      expect(inSheet(find.byIcon(Icons.check)), findsOneWidget);
      // 没填新名称时不能替换
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '一键替换'))
            .onPressed,
        isNull,
      );

      // 填新名称后按钮可用，点一下确认替换
      await tester.enterText(sheetField(1), '顾长风');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '一键替换'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.widgetWithText(ElevatedButton, '一键替换'));
      await tester.pumpAndSettle();
      expect(find.text('确认一键改名'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, '确认替换'));
      await tester.pumpAndSettle();

      expect(env.ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      expect(env.ctrl.outlineContent, contains('顾长风拜入青云宗。'));
      // 页面上的卡片同步改完，且没有「未保存」残留
      expect(find.text('所有改动已保存'), findsOneWidget);
      expect(env.ctrl.dirtyCount, 0);
    });

    testWidgets('改名后下方的候选标签跟着刷新（旧名字消失、新名字出现）', (tester) async {
      // 回归用例：候选原先只在打开面板时取一次快照，
      // 改完名字后底部标签还挂着旧名字、新名字一个都不出现
      final env = await pumpPage(
        tester,
        // 设定里的主角与实际正文里的名字不同：否则「设定里的名字」会无视出现
        // 次数一直挂在候选里，验不出标签到底刷没刷新
        protagonist: '赵铁柱',
        content: '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  李云飞拜入青云宗。
''',
      );

      await tester.tap(find.text('改名'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('李云飞')), findsOneWidget);

      await tester.tap(inSheet(find.text('李云飞')));
      await tester.pumpAndSettle();
      await tester.enterText(sheetField(1), '顾长风');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '一键替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '确认替换'));
      await tester.pumpAndSettle();

      // 旧名字从候选里消失，新名字（出现 2 次）成为候选
      expect(env.ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      expect(inSheet(find.text('李云飞')), findsNothing);
      expect(inSheet(find.text('顾长风')), findsOneWidget);
      // 替换表已清空（不会留着刚改完的旧规则让人误点第二次）
      expect(tester.widget<TextField>(sheetField(0)).controller?.text, isEmpty);
    });

    testWidgets('候选为空时给出说明与手填入口', (tester) async {
      // 正文为空、也没填主角 → 没有候选；手填仍然可用
      final env = await pumpPage(tester, protagonist: '');

      await tester.tap(find.text('改名'));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有自动挑出候选'), findsOneWidget);
      expect(find.text('替换表'), findsOneWidget);

      // 手填也能替换：先给控制器一份正文
      env.ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
''';
      await tester.enterText(sheetField(0), '李云飞');
      await tester.enterText(sheetField(1), '顾长风');
      await tester.pumpAndSettle();

      expect(find.textContaining('会影响 1 个事件、替换 1 处'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, '一键替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '确认替换'));
      await tester.pumpAndSettle();

      expect(env.ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
    });

    testWidgets('改名面板可以展开看具体改在哪几句', (tester) async {
      await pumpPage(
        tester,
        content: '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  李云飞拜入青云宗。
''',
      );

      await tester.tap(find.text('改名'));
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.text('李云飞')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('会影响 1 个事件、替换 2 处'));
      await tester.pumpAndSettle();

      // 展开后逐处列出「事件定位 + 上下文 + 命中处数」
      // 两行概要各命中一次，因此是同一定位下的两条命中
      expect(find.text('大事件1 · 概要'), findsNWidgets(2));
      expect(find.textContaining('（1 处）'), findsNWidgets(2));
    });
  });
}
