import 'dart:convert';
import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/background/outline_listening_notification.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/controller/outline_listen_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/model/listening_segment.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/name_finder.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/tts_engine.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/service/tts_engine_fake.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/character_profile.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_chapter_sync.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';

/// 「听大纲改名」控制器的行为：**一个事件一张卡片** / 播放推进 / 边听边改 /
/// 撤回 / 一键改名。段落列表里的每一项就是一个事件（V4.8.4 起），
/// 不再是「标题一行、概要一行」。
///
/// 一律用 [FakeTtsEngine]：真机上的连读靠原生朗读完成回调，widget 测试里
/// 既没有原生通道也没有异步音频，用假引擎才能把这条链路测完整。
///
/// `outline.id` 传 null：写库那一步短路，测试不依赖 sqflite
/// （测试环境没有数据库工厂），但内存里的合并逻辑照常验。
void main() {
  OutlineChapter ch(
    int index,
    String type,
    String title,
    String summary, {
    String content = '',
  }) => OutlineChapter(
    id: index,
    outlineId: 1,
    eventIndex: index,
    eventType: type,
    eventTitle: title,
    eventSummary: summary,
    content: content,
  );

  /// 两个事件：大事件 1（两行概要）+ 小事件 2
  List<OutlineChapter> chapters() => [
    ch(1, 'major', '初入江湖', '李云飞在青阳城醒来。\n他失去了记忆。'),
    ch(2, 'minor', '拜师', '李云飞拜入青云宗。', content: '正文一段。'),
  ];

  /// 未入库的章节（id 留空）：走「只更新内存、不写库」那条路，
  /// 于是保存逻辑里的**文本合并**能在没有 sqflite 的测试环境里照常验
  List<OutlineChapter> inMemoryChapters() => [
    OutlineChapter(
      outlineId: 0,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '初入江湖',
      eventSummary: '李云飞在青阳城醒来。\n他失去了记忆。',
    ),
    OutlineChapter(
      outlineId: 0,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '拜师',
      eventSummary: '李云飞拜入青云宗。',
      content: '正文一段。',
    ),
  ];

  OutlineListenController build({FakeTtsEngine? engine}) {
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: engine ?? FakeTtsEngine(),
    );
    ctrl.init(chapters());
    return ctrl;
  }

  /// 不依赖数据库的控制器（章节 id 为空）
  OutlineListenController buildInMemory() {
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: '', protagonist: '李云飞'),
      engine: FakeTtsEngine(),
    );
    ctrl.init(inMemoryChapters());
    return ctrl;
  }

  /// 等控制器里 `unawaited` 的连读 / 通知同步跑完（都是微任务级异步）
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// 反复触发「这一句读完了」，直到**当前事件推进**或朗读停下。
  ///
  /// 逐句朗读之后，一次 [FakeTtsEngine.finishCurrent] 只代表「当前这一句读完」，
  /// 一个事件有几句话就要推几次。上限保护：句子计划坏了也不会死循环。
  Future<void> finishEvent(
    FakeTtsEngine engine,
    OutlineListenController ctrl,
  ) async {
    final startIndex = ctrl.activeIndex;
    for (var i = 0; i < 100; i++) {
      engine.finishCurrent();
      await settle();
      if (!ctrl.playing || ctrl.activeIndex != startIndex) return;
    }
    fail('读了 100 句还没读完当前事件（activeIndex 停在 $startIndex），句子推进可能卡住');
  }

  /// 只推一句：断言「当前句」往后走了一句（句子级朗读的核心链路）。
  Future<void> finishSentence(
    FakeTtsEngine engine,
    OutlineListenController ctrl,
  ) async {
    final before = ctrl.activeSentenceIndex;
    engine.finishCurrent();
    await settle();
    expect(
      ctrl.activeSentenceIndex,
      isNot(before),
      reason: '读完一句后当前句序号必须推进（或事件已读完）',
    );
  }

  group('一个事件一张卡片', () {
    test('两个事件 = 两张卡片，标题与概要都在同一张卡片上', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      expect(ctrl.segments.length, 2);
      expect(ctrl.segments[0].typeLabel, '大事件1');
      expect(ctrl.segments[0].title, '初入江湖');
      // 多行概要在**同一张卡片**里（上一版是逐行拆成多张）
      expect(ctrl.segments[0].summary, '李云飞在青阳城醒来。\n他失去了记忆。');
      // 小事件序号是「所属大事件内部第几个」，不是全篇事件序号（不能显示成 2）
      expect(ctrl.segments[1].typeLabel, '小事件1');
      expect(ctrl.segments[1].title, '拜师');
      expect(ctrl.segments[1].hasContent, isTrue);
    });

    test('标题、概要与事件一一对应（不会串到别的卡片上）', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.segments[0].titleCtrl.text = '初入江湖（改）';
      expect(ctrl.segments[0].title, '初入江湖（改）');
      expect(ctrl.segments[1].title, '拜师');
      expect(ctrl.dirtyCount, 1);
    });

    test('朗读文本 = 类型 + 标题（+ 概要 / 正文，按朗读范围）', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      expect(
        ctrl.segments[0].speechText(OutlineListenMode.titleOnly),
        '大事件1，初入江湖',
      );
      expect(
        ctrl.segments[0].speechText(OutlineListenMode.titleAndSummary),
        '大事件1，初入江湖。李云飞在青阳城醒来。\n他失去了记忆。',
      );
      final full = ctrl.segments[1].speechText(OutlineListenMode.full);
      expect(full, contains('小事件1，拜师'));
      expect(full, contains('李云飞拜入青云宗。'));
      expect(full, contains('正文：正文一段。'));
    });

    test('切换朗读范围不会丢概要（卡片本来就是整段）', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(
        ctrl.settings.copyWith(mode: OutlineListenMode.titleOnly),
      );
      expect(ctrl.segments.length, 2);
      expect(ctrl.segments[0].summary, '李云飞在青阳城醒来。\n他失去了记忆。');

      ctrl.updateSettings(ctrl.settings.copyWith(mode: OutlineListenMode.full));
      expect(ctrl.segments.length, 2);
      expect(ctrl.segments[1].hasContent, isTrue);
    });
  });

  group('序号：与大纲正文的 大事件N / 小事件N 同一套', () {
    /// 事件列表 → 卡片上的类型文案
    List<String> labels(List<OutlineChapter> chapters) {
      final ctrl = OutlineListenController(
        OutlineRecord(title: 'T', content: ''),
        engine: FakeTtsEngine(),
      );
      addTearDown(ctrl.dispose);
      ctrl.init(chapters, reload: false);
      return ctrl.segments.map((s) => s.typeLabel).toList();
    }

    test('大事件只数大事件；小事件在每个大事件内部从 1 重新计数', () {
      // 正文写法：══ 大事件1 / ○ 小事件1 / ○ 小事件2 / ══ 大事件2 / ○ 小事件1 …
      expect(
        labels([
          ch(1, 'major', '甲', ''),
          ch(2, 'minor', '乙', ''),
          ch(3, 'minor', '丙', ''),
          ch(4, 'major', '丁', ''),
          ch(5, 'minor', '戊', ''),
          ch(6, 'major', '己', ''),
        ]),
        ['大事件1', '小事件1', '小事件2', '大事件2', '小事件1', '大事件3'],
      );
    });

    test('不能拿全篇事件序号当卡片序号（会跳号）', () {
      final ctrl = OutlineListenController(
        OutlineRecord(title: 'T', content: ''),
        engine: FakeTtsEngine(),
      );
      addTearDown(ctrl.dispose);
      ctrl.init([
        ch(1, 'major', '甲', ''),
        ch(2, 'minor', '乙', ''),
        ch(3, 'major', '丙', ''),
        ch(4, 'minor', '丁', ''),
      ], reload: false);

      // 第 3 个事件是第 2 个大事件、第 4 个事件是第 2 个大事件名下第 1 个小事件
      expect(ctrl.segments[2].typeLabel, '大事件2');
      expect(ctrl.segments[3].typeLabel, '小事件1');
      expect(ctrl.segments[3].speechText(OutlineListenMode.titleOnly), '小事件1，丁');
    });

    test('开头没有大事件时小事件从 1 起（与正文规范化同一口径）', () {
      expect(
        labels([
          ch(1, 'minor', '序章一', ''),
          ch(2, 'minor', '序章二', ''),
          ch(3, 'major', '甲', ''),
          ch(4, 'minor', '乙', ''),
        ]),
        ['小事件1', '小事件2', '大事件1', '小事件1'],
      );
    });
  });

  group('播放', () {
    test('播放从第一个事件开始，按设置传语速 / 语言给引擎', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(ctrl.settings.copyWith(rate: 1.5, language: 'zh-TW'));
      await ctrl.play();

      expect(ctrl.playing, isTrue);
      expect(ctrl.activeIndex, 0);
      expect(engine.spoken.length, 1);
      expect(engine.spoken.first, startsWith('大事件1，初入江湖'));
      expect(engine.requests.last.rate, 1.5);
      expect(engine.requests.last.language, 'zh-TW');
    });

    test('读完一个事件（逐句推完）自动读下一个', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      // 事件 1 的朗读计划 = 标题句 + 概要 2 句，共 3 句：一次 finishCurrent 只推一句
      expect(ctrl.sentenceCountForIndex(0), 3);
      await finishEvent(engine, ctrl);

      expect(ctrl.activeIndex, 1);
      expect(engine.spoken.last, startsWith('小事件1，拜师'));
      expect(ctrl.spokenCount, 1);
    });

    test('关闭「自动连读」后读完一个事件就停（句子要逐句推完）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(ctrl.settings.copyWith(autoNext: false));
      await ctrl.play();
      await finishEvent(engine, ctrl);

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, 0);
      // 逐句朗读：这个事件有几句就发了几个朗读请求（不是一次读完）
      expect(engine.spoken.length, ctrl.sentenceCountForIndex(0));
      expect(ctrl.activeSentenceIndex, -1);
    });

    test('读到最后一张卡片：不开循环就停并标记读完', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(ctrl.segments.length - 1);
      await finishEvent(engine, ctrl);

      expect(ctrl.playing, isFalse);
      expect(ctrl.finished, isTrue);
    });

    test('开循环后读完最后一张卡片回到第一个事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(ctrl.settings.copyWith(repeat: true));
      await ctrl.playFrom(ctrl.segments.length - 1);
      await finishEvent(engine, ctrl);

      expect(ctrl.activeIndex, 0);
      expect(ctrl.playing, isTrue);
    });

    test('暂停会真的停引擎，并把位置留在当前事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(1);
      await ctrl.pause();

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, 1);
      expect(engine.stopCount, greaterThan(0));
    });

    test('点某张卡片的播放：从这一个事件开始读', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(1);

      expect(ctrl.activeIndex, 1);
      expect(engine.spoken.single, startsWith('小事件1，拜师'));
    });

    test('设备没有语音引擎时如实提示，不假装在播', () async {
      final engine = FakeTtsEngine(available: false);
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();

      expect(ctrl.playing, isFalse);
      expect(ctrl.errorMessage, isNotEmpty);
      expect(engine.spoken, isEmpty);
    });

    test('引擎报错时停下并显示原因', () async {
      final engine = FakeTtsEngine()..failNextSpeak = true;
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();

      expect(ctrl.playing, isFalse);
      expect(ctrl.errorMessage, isNotEmpty);
      ctrl.clearError();
      expect(ctrl.errorMessage, isEmpty);
    });

    test('停止回到开头，进度清零', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(1);
      await ctrl.stop();

      expect(ctrl.activeIndex, -1);
      expect(ctrl.spokenCount, 0);
      expect(ctrl.playing, isFalse);
    });

    test('改语速立即生效：正在读的这一条从头重读一遍', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      expect(engine.spoken.length, 1);

      // 朗读中把语速从 1.0 改到 3.0：应当立刻用新语速重读当前这条，
      // 而不是等这条读完（几十秒）才生效
      ctrl.updateSettings(ctrl.settings.copyWith(rate: 3.0));

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(engine.spoken.length, greaterThan(1));
      expect(engine.requests.last.rate, 3.0);
      expect(ctrl.playing, isTrue);
    });

    test('改音调 / 朗读范围不重读（只有语速改动才立即生效）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      final spokenBefore = engine.spoken.length;

      ctrl.updateSettings(ctrl.settings.copyWith(pitch: 1.4));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spoken.length, spokenBefore);

      ctrl.updateSettings(
        ctrl.settings.copyWith(mode: OutlineListenMode.titleOnly),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spoken.length, spokenBefore);
    });

    test('语速档位最高 4.0x（含 3.0x，本地离线合成上限也放到了 4.0）', () {
      expect(OutlineSpeechSettings.rateOptions, contains(3.0));
      expect(OutlineSpeechSettings.rateOptions, contains(4.0));
      expect(OutlineSpeechSettings.rateOptions.last, 4.0);
      // 档位必须递增，UI 上才好按速度从慢到快排
      final rates = OutlineSpeechSettings.rateOptions;
      for (var i = 1; i < rates.length; i++) {
        expect(rates[i], greaterThan(rates[i - 1]));
      }
    });

    test('重试会先把引擎丢掉重建再读（真机上「重试」无效就是栽在这里）', () async {
      // 真机复现过：引擎初始化失败后，原生侧把失败结果缓存住，用户在系统里
      // 装好 / 启用好引擎再回来点「重试」，只重发一次 init 拿回的还是失败。
      // 所以重试必须走 engine.reset()，让下一次 init 真的重建引擎。
      final engine = FakeTtsEngine(available: false);
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      expect(ctrl.playing, isFalse);
      expect(ctrl.errorMessage, isNotEmpty);
      expect(engine.resetCount, 0);

      // 用户在系统里装好引擎（假引擎里就是 available 变 true），回来点重试
      engine.available = true;
      final started = await ctrl.retryPlay();

      expect(started, isTrue);
      expect(engine.resetCount, 1); // 先丢了旧引擎
      expect(ctrl.playing, isTrue);
      expect(ctrl.errorMessage, isEmpty);
      expect(engine.spoken, isNotEmpty); // 真的读了
    });

    test('重试仍失败时保留新的失败原因，不静默', () async {
      final engine = FakeTtsEngine(available: false);
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      final started = await ctrl.retryPlay();

      expect(started, isFalse);
      expect(engine.resetCount, 1);
      expect(ctrl.playing, isFalse);
      expect(ctrl.errorMessage, isNotEmpty);
    });

    test('进页面体检：本机没有语音引擎时提前给提示', () async {
      final engine = FakeTtsEngine(available: false)
        ..status = const TtsEngineStatus(zhState: 'no_engine');
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      final hint = await ctrl.refreshEngineHint();

      expect(hint, contains('没有可用的「文字转语音」引擎'));
      expect(ctrl.engineHint, isNotEmpty);
    });

    test('进页面体检：引擎正常时不打扰用户', () async {
      final engine = FakeTtsEngine()
        ..status = const TtsEngineStatus(
          engines: ['com.iflytek.speechsuite'],
          defaultEngine: 'com.iflytek.speechsuite',
          zhState: 'ok',
        );
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      final hint = await ctrl.refreshEngineHint();

      expect(hint, isEmpty);
      expect(ctrl.engineHint, isEmpty);
    });

    test('进页面体检：中文支持未知时不误报（真机上误报过「不支持中文」）', () async {
      // 引擎存在、但还没绑定成功时原生侧回 unknown，不能据此说人家不支持中文
      final engine = FakeTtsEngine()
        ..status = const TtsEngineStatus(
          engines: ['com.iflytek.speechsuite'],
          defaultEngine: 'com.iflytek.speechsuite',
          zhState: 'unknown',
        );
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.refreshEngineHint();

      expect(ctrl.engineHint, isEmpty);
    });

    test('引擎起来开始朗读后，进页面留下的体检提示要消失（提示条不能是粘的）', () async {
      final engine = FakeTtsEngine()
        ..status = const TtsEngineStatus(
          engines: ['com.iflytek.speechsuite'],
          defaultEngine: 'com.iflytek.speechsuite',
          zhState: 'missing_data',
        );
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.refreshEngineHint();
      expect(ctrl.engineHint, isNotEmpty); // 缺中文语音包：先说一声

      // 引擎实际能用（这里以「能读起来」为准）→ 提示必须撤掉
      await ctrl.play();

      expect(ctrl.playing, isTrue);
      expect(ctrl.engineHint, isEmpty);
    });
  });

  group('边听边改', () {
    test('改标题只影响「未保存」，不打断正在读的事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      final calls = engine.spoken.length;
      ctrl.segments[0].titleCtrl.text = '初入江湖（改）';
      ctrl.segments[0].markSaved(); // 模拟已保存基线
      await Future<void>.delayed(Duration.zero);

      expect(engine.spoken.length, calls, reason: '打字不该触发重读');
      expect(ctrl.dirtyCount, 0);
    });

    test('改概要后保存：整段概要与标题写回，正文合并回大纲正文', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.segments[0].summaryCtrl.text = '李云飞在青阳城醒来。\n他恢复了记忆。';
      expect(ctrl.dirtyCount, 1);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  他失去了记忆。

○ 小事件2：拜师
  李云飞拜入青云宗。
''';

      final saved = await ctrl.saveAll();
      expect(saved, 1);
      expect(ctrl.dirtyCount, 0);
      expect(ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
      expect(ctrl.outlineContent, contains('他恢复了记忆。'));
      expect(ctrl.outlineContent, isNot(contains('他失去了记忆。')));
      // 另一个事件没被牵连
      expect(ctrl.outlineContent, contains('○ 小事件2：拜师'));
      expect(ctrl.outlineContent, contains('李云飞拜入青云宗。'));
    });

    test('改标题后保存：标题写回大纲正文，其余事件原样保留', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。

○ 小事件2：拜师
  李云飞拜入青云宗。
''';
      ctrl.segments[0].titleCtrl.text = '初入江湖（卷首）';
      expect(await ctrl.saveAll(), 1);

      expect(ctrl.outlineContent, contains('大事件1：初入江湖（卷首）'));
      expect(ctrl.outlineContent, contains('○ 小事件2：拜师'));
      expect(ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
    });

    test('标题被清空时回填原标题（避免正文出现断行事件）', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '══ 大事件1：初入江湖 ══\n  李云飞在青阳城醒来。';
      ctrl.segments[0].titleCtrl.text = '   ';
      ctrl.segments[0].summaryCtrl.text = '换了一段概要。';

      expect(await ctrl.saveAll(), 1);
      expect(ctrl.segments[0].title, '初入江湖');
      expect(ctrl.outlineContent, contains('大事件1：初入江湖'));
    });
  });

  group('撤回 / 取消撤回', () {
    test('改了文本可以撤回，再「取消撤回」能回来', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      expect(ctrl.canUndo, isFalse);
      expect(ctrl.canRedo, isFalse);

      final card = ctrl.segments[0];
      card.titleCtrl.text = '初入江湖（改）';
      expect(ctrl.dirtyCount, 1);
      expect(ctrl.canUndo, isTrue);

      await ctrl.undo();
      expect(card.title, '初入江湖');
      expect(ctrl.canUndo, isFalse);
      expect(ctrl.canRedo, isTrue);

      await ctrl.redo();
      expect(card.title, '初入江湖（改）');
      expect(ctrl.canRedo, isFalse);
      expect(ctrl.canUndo, isTrue);
    });

    test('连续打字合并成一步；两次独立的改动是两步', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      final card = ctrl.segments[0];
      // 模拟连续输入：每次输入后立刻再改（间隔远小于 600ms 的合并窗口）
      card.titleCtrl.text = '初';
      card.titleCtrl.text = '初入';
      card.titleCtrl.text = '初入江湖（改）';

      await ctrl.undo();
      expect(card.title, '初入江湖', reason: '一次连续输入只留一个撤回起点');

      // 第二次独立改动（中间隔开一个提交窗口）
      card.titleCtrl.text = '初入江湖（再改）';
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await ctrl.undo();
      expect(card.title, '初入江湖');
    });

    test('撤回后再改文本会清掉「取消撤回」', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.segments[0].titleCtrl.text = '甲';
      await ctrl.undo();
      expect(ctrl.canRedo, isTrue);

      ctrl.segments[1].summaryCtrl.text = '乙';
      expect(ctrl.canRedo, isFalse, reason: '新的改动让旧的重做分支作废');
    });

    test('撤回改动过的概要：未保存状态一起回到当时', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.segments[0].summaryCtrl.text = '他恢复了记忆。';
      expect(ctrl.dirtyCount, 1);

      await ctrl.undo();
      expect(ctrl.segments[0].summary, '李云飞在青阳城醒来。\n他失去了记忆。');
      expect(ctrl.dirtyCount, 0);
    });

    test('撤回一键改名：卡片文本与候选标签一起改回来', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  李云飞拜入青云宗。
''';
      ctrl.refreshNameCandidates();

      final outcome = await ctrl.applyRenameRules([
        (source: '李云飞', target: '顾长风'),
      ]);
      expect(outcome.count, 2);
      expect(ctrl.outlineContent, isNot(contains('李云飞')));
      expect(ctrl.canUndo, isTrue);

      await ctrl.undo();
      expect(ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
      expect(ctrl.outlineContent, isNot(contains('顾长风')));
      expect(ctrl.segments[0].summary, contains('李云飞'));
      expect(ctrl.nameCandidates.map((c) => c.text), contains('李云飞'));

      // 取消撤回：正文与卡片再改回新名字
      await ctrl.redo();
      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      expect(ctrl.segments[0].summary, contains('顾长风'));
    });

    test('改名后再改文本，撤回两次能一步步退回到最初', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
''';
      await ctrl.applyRenameRules([(source: '李云飞', target: '顾长风')]);
      ctrl.segments[0].titleCtrl.text = '初入江湖（改）';

      // 第一步撤回：退回标题改动（改名还在）
      await ctrl.undo();
      expect(ctrl.segments[0].title, '初入江湖');
      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      expect(ctrl.outlineContent, isNot(contains('李云飞')));

      // 第二步撤回：把改名也退掉
      await ctrl.undo();
      expect(ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
      expect(ctrl.outlineContent, isNot(contains('顾长风')));
      expect(ctrl.canUndo, isFalse);

      // 两步都能「取消撤回」回来
      await ctrl.redo();
      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      await ctrl.redo();
      expect(ctrl.segments[0].title, '初入江湖（改）');
    });

    test('撤回期间不重复记历史（撤回本身不该被撤回）', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      ctrl.segments[0].titleCtrl.text = '甲';
      await ctrl.undo();
      expect(ctrl.canUndo, isFalse);
      expect(ctrl.canRedo, isTrue);

      await ctrl.undo();
      expect(ctrl.segments[0].title, '初入江湖');
      expect(ctrl.canRedo, isTrue);
    });

    test('没有历史时撤回 / 取消撤回都是空操作', () async {
      final ctrl = buildInMemory();
      addTearDown(ctrl.dispose);

      await ctrl.undo();
      await ctrl.redo();
      expect(ctrl.segments[0].title, '初入江湖');
      expect(ctrl.hasUnsaved, isFalse);
    });
  });

  group('事件识别（与「大纲编辑」同一套）', () {
    test('按大纲正文解析出的事件序号与标题，与编辑页看到的一致', () {
      // 页面读库那一步在测试环境跑不了（没有 sqflite），这里直接验共用的解析：
      // 「听大纲改名」与「大纲编辑」最终都走 parseOutlineEvents。
      const content = '''
══ 第一幕：开端 ══

══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。

○ 小事件2：拜师
  ## 李云飞拜入青云宗。
  师父是玄机子。

**大事件3：下山**
  他第一次下山。
''';
      final events = parseOutlineEvents(content, outlineId: 7);
      expect(events.length, 3);
      expect(events.map((e) => e.eventIndex), [1, 2, 3]);
      expect(events.map((e) => e.eventType), ['major', 'minor', 'major']);
      expect(events.map((e) => e.eventTitle), ['初入江湖', '拜师', '下山']);
      // 多行概要归到所属事件，幕标题不污染概要
      expect(events[1].eventSummary, contains('拜入青云宗'));
      expect(events[1].eventSummary, isNot(contains('第一幕')));
      expect(events[0].eventSummary, '李云飞在青阳城醒来。');
    });

    test('解析出来的事件建出的卡片数与序事件一致', () {
      final ctrl = OutlineListenController(
        OutlineRecord(title: 'T', content: ''),
        engine: FakeTtsEngine(),
      );
      addTearDown(ctrl.dispose);
      ctrl.init(
        parseOutlineEvents(
          '══ 大事件1：A ══\n  概要一\n\n○ 小事件2：B\n  概要二',
          outlineId: 0,
        ),
        reload: false,
      );

      expect(ctrl.segments.length, 2);
      expect(ctrl.segments.map((s) => s.title), ['A', 'B']);
      expect(ctrl.segments.map((s) => s.summary), ['概要一', '概要二']);
    });

    test('一条事件都识别不出来时保留一条「正文」占位（不会变成空列表）', () {
      final events = parseOutlineEvents('这里只是随手写的设定文字。', outlineId: 3);
      expect(events.length, 1);
      expect(events.first.eventTitle, '正文');
    });

    test('latestOutlineRecord 在库里取不到时退回传进来的快照', () async {
      // 测试环境没有 sqflite，读库必然失败：必须静默退回快照而不是抛出去
      final snapshot = OutlineRecord(id: 1, title: '测试小说', content: 'AAA');
      final record = await latestOutlineRecord(snapshot);
      expect(record.content, 'AAA');
      expect(record.title, '测试小说');
    });

    test('latestOutlineRecord 对未入库的记录原样返回', () async {
      final snapshot = OutlineRecord(title: '未入库', content: 'BBB');
      final record = await latestOutlineRecord(snapshot);
      expect(identical(record, snapshot), isTrue);
    });
  });

  group('一键改名', () {
    test('替换大纲正文里的人名，并同步卡片上的每一段', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  他失去了记忆。

○ 小事件2：拜师
  李云飞拜入青云宗。
  师父是玄机子。
''';
      ctrl.foreshadows = '李云飞身上的玉佩';

      final result = ctrl.checkName('李云飞');
      // 正文 2 处（两行概要）；设定里主角简介也有 1 处——V4.9.3 起一并参与搜索与预览
      expect(result.outlineCount, 2);
      expect(result.settingCount, 1);
      expect(result.totalCount, 3);
      expect(result.eventCount, 2);

      final outcome = await ctrl.applyRenameRules([
        (source: '李云飞', target: '顾长风'),
      ]);

      expect(outcome.count, 2);
      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      expect(ctrl.outlineContent, isNot(contains('李云飞')));
      // 伏笔清单一起改：AI 提示词注入的那份也要跟着换
      expect(ctrl.foreshadows, '顾长风身上的玉佩');
      // 卡片上的概要已同步，且不算「未保存」（改名是即时落库的）
      expect(ctrl.segments[0].summary, contains('顾长风在青阳城醒来。'));
      expect(ctrl.dirtyCount, 0);
    });

    test('多个规则一次应用：人名与地名一起换', () async {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
''';
      await ctrl.applyRenameRules([
        (source: '李云飞', target: '顾长风'),
        (source: '青阳城', target: '洛水关'),
      ]);

      expect(ctrl.outlineContent, contains('顾长风在洛水关醒来。'));
    });

    test('改名时可选「同时改小说设定」，设定里的名字跟着换', () async {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
''';
      // 设定里的主角与正文同名
      expect(ctrl.outline.protagonist, '李云飞');

      await ctrl.applyRenameRules(
        [(source: '李云飞', target: '顾长风')],
        updateSettings: true,
      );

      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      // 设定改过之后，候选表里就不该再有旧名字了
      // （设定里的名字无视出现次数一直在榜上，不跟着改会一直挂着旧名字）
      expect(ctrl.nameCandidates.map((c) => c.text), isNot(contains('李云飞')));
      expect(ctrl.nameCandidates.map((c) => c.text), contains('顾长风'));
    });

    test('不勾「同时改小说设定」时设定保持原样', () async {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '══ 大事件1：初入江湖 ══\n  李云飞在青阳城醒来。';
      await ctrl.applyRenameRules([(source: '李云飞', target: '顾长风')]);

      expect(ctrl.outlineContent, contains('顾长风在青阳城醒来。'));
      // 设定没动：候选里仍保留设定里的主角（这是「只改大纲」的预期行为）
      expect(ctrl.nameCandidates.map((c) => c.text), contains('李云飞'));
    });

    test('空规则 / 原新同名不改动正文，也不报错', () async {
      final ctrl = build();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：初入江湖 ══\n  李云飞在青阳城醒来。';

      expect((await ctrl.applyRenameRules([])).count, 0);
      expect(
        (await ctrl.applyRenameRules([(source: '李云飞', target: '  ')])).count,
        0,
      );
      expect(
        (await ctrl.applyRenameRules([
          (source: '李云飞', target: '李云飞'),
        ])).count,
        0,
      );
      expect(ctrl.outlineContent, contains('李云飞在青阳城醒来。'));
      // 空操作不该留下历史（点了撤回也不该有什么可撤回的）
      expect(ctrl.canUndo, isFalse);
    });

    test('候选专名：设定里的主角一定在，且排在最前', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      ctrl.outlineContent = '''
══ 大事件1：初入江湖 ══
  李云飞在青阳城醒来。
  李云飞拜入青云宗，师父玄机子看着青阳城的夜色。
''';
      ctrl.refreshNameCandidates();

      expect(ctrl.nameCandidates.map((c) => c.text), contains('李云飞'));
      expect(ctrl.nameCandidates.first.text, '李云飞');
      // 地名候选（带「城 / 宗」后缀且出现两次以上）
      expect(ctrl.nameCandidates.map((c) => c.text), contains('青阳城'));
    });
  });

  group('小说设定也参与改名（类型 / 主题 / 主角简介 / 世界观 / 人物档案）', () {
    String charactersJson() => jsonEncode([
      const CharacterProfile(
        name: '顾泽',
        description: '顾泽在H市醒来，失去了记忆',
        abilities: '低武世界第一的内力',
        personality: '冷静',
        isProtagonist: true,
      ).toJson(),
      const CharacterProfile(
        name: '白小飞',
        description: '白小飞是顾泽的同伴',
        personality: '热血',
      ).toJson(),
    ]);

    OutlineListenController buildWithSettings() {
      final ctrl = OutlineListenController(
        OutlineRecord(
          title: '测试小说',
          content: '',
          // 类型 / 主题 / 主角简介 / 世界观 / 人物档案 / 伏笔都给上
          genre: '都市异能',
          theme: '顾泽寻找身世之谜',
          protagonist: '顾泽，低武世界天下第一',
          worldview: 'H市被尸兄占据，顾泽来自低武世界',
          characters: charactersJson(),
          foreshadows: '顾泽身上的玉佩',
        ),
        engine: FakeTtsEngine(),
      );
      ctrl.init(chapters(), reload: false);
      return ctrl;
    }

    test('搜得到设定里的词（以前这些词搜不到，替换按钮直接是灰的）', () {
      final ctrl = buildWithSettings();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：甲 ══\n  正文里没有目标词。';

      final theme = ctrl.checkName('身世');
      expect(theme.outlineCount, 0);
      expect(theme.settingCount, 1);
      expect(theme.settingHits.single.label, '主题');

      expect(ctrl.checkName('尸兄').settingCount, 1); // 世界观
      expect(ctrl.checkName('醒来').settingCount, 1); // 人物简介（描述）
      expect(ctrl.checkName('热血').settingCount, 1); // 人物档案·性格
      // 伏笔清单不属于「小说设定」字段（替换时仍按原行为纯文本换掉）
      expect(ctrl.checkName('玉佩').settingCount, 0);
    });

    test('勾「同时改小说设定」后：设定五项一起换，人物档案逐字段换', () async {
      final ctrl = buildWithSettings();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：甲 ══\n  顾泽出场。';

      final outcome = await ctrl.applyRenameRules(
        [(source: '顾泽', target: '苏哲')],
        updateSettings: true,
      );
      // 正文 1 处；设定里：主角简介 1 + 主题 1 + 世界观 1 +
      // 顾泽·姓名 1 + 顾泽·描述 1 + 白小飞·描述 1 = 6 处
      expect(outcome.count, 7);

      expect(ctrl.checkName('顾泽').outlineCount, 0);
      expect(ctrl.checkName('顾泽').settingCount, 0);
      expect(ctrl.checkName('苏哲').settingCount, 6);
      expect(ctrl.characterNames, contains('苏哲'));
      expect(ctrl.characterNames, isNot(contains('顾泽')));
      // 伏笔清单一并替换（原有行为）
      expect(ctrl.foreshadows, '苏哲身上的玉佩');
    });

    test('改名后撤回 / 取消撤回：设定也跟着改回来、再改回去', () async {
      final ctrl = buildWithSettings();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：甲 ══\n  顾泽出场。';

      await ctrl.applyRenameRules(
        [(source: '顾泽', target: '苏哲')],
        updateSettings: true,
      );
      await ctrl.undo();
      expect(ctrl.checkName('顾泽').settingCount, 6);
      expect(ctrl.characterNames, contains('顾泽'));
      expect(ctrl.checkName('苏哲').settingCount, 0);

      await ctrl.redo();
      expect(ctrl.checkName('苏哲').settingCount, 6);
      expect(ctrl.characterNames, contains('苏哲'));
      expect(ctrl.checkName('顾泽').settingCount, 0);
    });

    test('不勾时设定保持原样（原有「只改大纲」语义不变）', () async {
      final ctrl = buildWithSettings();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：甲 ══\n  顾泽出场。';

      await ctrl.applyRenameRules([(source: '顾泽', target: '苏哲')]);
      expect(ctrl.checkName('顾泽').settingCount, 6);
      expect(ctrl.characterNames, contains('顾泽'));
    });

    test('init(record:) 采用完整记录：伏笔 / 人物档案不再被摘要覆盖成空', () {
      // 列表页传下来的是「小字段摘要」：content / characters / foreshadows 都没有
      final ctrl = OutlineListenController(
        OutlineRecord(title: '测试小说'),
        engine: FakeTtsEngine(),
      );
      addTearDown(ctrl.dispose);
      final full = OutlineRecord(
        id: 7,
        title: '测试小说',
        content: '══ 大事件1：甲 ══\n  正文',
        genre: '都市异能',
        theme: '主题词',
        protagonist: '顾泽',
        worldview: '世界观词',
        characters: charactersJson(),
        foreshadows: '伏笔清单',
      );
      ctrl.init(chapters(), reload: false, record: full);

      expect(ctrl.outlineContent, contains('正文'));
      expect(ctrl.foreshadows, '伏笔清单'); // 以前是空串，保存时会把库里的清掉
      expect(ctrl.characterNames, containsAll(['顾泽', '白小飞']));
      expect(ctrl.checkName('主题词').settingCount, 1);
      expect(ctrl.checkName('世界观词').settingCount, 1);
    });

    test('候选专名包含人物档案里的名字（人物简介里的角色也能被改名）', () {
      final ctrl = buildWithSettings();
      addTearDown(ctrl.dispose);
      ctrl.outlineContent = '══ 大事件1：甲 ══\n  正文。';
      ctrl.refreshNameCandidates();

      expect(
        ctrl.nameCandidates.map((c) => c.text),
        containsAll(<String>['顾泽', '白小飞']),
      );
    });
  });

  group('候选专名解析', () {
    test('AI 返回的 JSON 数组能被解析（含代码块包装与多余文字）', () {
      final list = parseAiNameCandidates('''
好的，这是结果：
```json
[{"name":"李云飞","type":"人名"},{"名称":"青阳城","类型":"地名"},"青云宗"]
```
''');
      expect(list.map((c) => c.text), ['李云飞', '青阳城', '青云宗']);
      expect(list[0].kind, OutlineNameKind.person);
      expect(list[1].kind, OutlineNameKind.place);
    });

    test('解析失败时返回空列表，不抛异常', () {
      expect(parseAiNameCandidates(''), isEmpty);
      expect(parseAiNameCandidates('没有找到任何名字'), isEmpty);
      expect(parseAiNameCandidates('[{坏掉的 json'), isEmpty);
    });
  });

  // ─── 句子级朗读（逐句 speak / 高亮 / 单事件拖动进度） ─────────────

  /// 四个事件（大 / 小交替），用于朗读范围过滤的用例
  OutlineListenController build4({FakeTtsEngine? engine}) {
    final ctrl = OutlineListenController(
      OutlineRecord(title: '测试小说', content: ''),
      engine: engine ?? FakeTtsEngine(),
    );
    ctrl.init([
      ch(1, 'major', '甲', '概要一。'),
      ch(2, 'minor', '乙', '概要二。'),
      ch(3, 'major', '丙', '概要三。'),
      ch(4, 'minor', '丁', '概要四。'),
    ], reload: false);
    return ctrl;
  }

  group('句子级朗读', () {
    test('播放从标题句开始：activeSentenceIndex / 句数 / 句序号 / 当前句文本', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      // 事件 1：标题 1 句 + 概要「李云飞在青阳城醒来。\n他失去了记忆。」2 句
      expect(ctrl.sentenceCountForIndex(0), 3);
      expect(ctrl.activeSentenceIndex, -1);
      expect(ctrl.activeSentenceCount, 0);

      await ctrl.play();

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 0);
      expect(ctrl.activeSentenceCount, 3);
      expect(ctrl.activeSentenceOrdinal, 1);
      expect(ctrl.activePiece?.part, SpeechPiecePart.title);
      expect(ctrl.activeSentenceText, '大事件1，初入江湖');
      // 一次只把**当前这一句**发给引擎：不是把整个事件一次性读掉
      expect(engine.spoken.single, '大事件1，初入江湖');
      expect(ctrl.playing, isTrue);
    });

    test('读完一句自动接下一句，顺序：标题 → 概要第 1 句 → 概要第 2 句', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);
      await ctrl.play();

      await finishSentence(engine, ctrl);
      expect(ctrl.activeSentenceIndex, 1);
      expect(ctrl.activeSentenceText, '李云飞在青阳城醒来。');
      expect(engine.spoken.last, '李云飞在青阳城醒来。');
      expect(ctrl.playing, isTrue, reason: '同一事件内读完一句不该停');

      await finishSentence(engine, ctrl);
      expect(ctrl.activeSentenceIndex, 2);
      expect(ctrl.activeSentenceText, '他失去了记忆。');
      expect(engine.spoken.last, '他失去了记忆。');

      // 最后一句读完：事件推进到下一个（标题句先读）
      await finishSentence(engine, ctrl);
      expect(ctrl.activeIndex, 1);
      expect(ctrl.activeSentenceIndex, 0);
      expect(engine.spoken.last, '小事件1，拜师');
      expect(ctrl.spokenCount, 1);
    });

    test('每个事件的句数 = 标题句 + 概要句数（空事件为 0，越界为 0）', () {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      expect(ctrl.sentenceCountForIndex(0), 3);
      expect(ctrl.sentenceCountForIndex(1), 2);
      expect(ctrl.sentenceCountForIndex(-1), 0);
      expect(ctrl.sentenceCountForIndex(99), 0);
      // 只读标题时每事件 1 句
      ctrl.updateSettings(
        ctrl.settings.copyWith(mode: OutlineListenMode.titleOnly),
      );
      expect(ctrl.sentenceCountForIndex(0), 1);
      expect(ctrl.sentenceCountForIndex(1), 1);
      // full 模式：中间插一句「正文」提示词 + 正文逐句
      ctrl.updateSettings(ctrl.settings.copyWith(mode: OutlineListenMode.full));
      expect(ctrl.sentenceCountForIndex(1), 4);
    });

    test('暂停后点播放从当前句继续，不回到事件第一句', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await finishSentence(engine, ctrl); // 推进到概要第 1 句
      await ctrl.pause();
      expect(ctrl.playing, isFalse);
      expect(ctrl.activeSentenceIndex, 1, reason: '暂停保留当前句位置');

      final spokeBefore = engine.spoken.length;
      await ctrl.play();

      expect(ctrl.playing, isTrue);
      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 1, reason: '继续播放不能退回标题句');
      expect(engine.spoken.length, spokeBefore + 1);
      expect(engine.spoken.last, '李云飞在青阳城醒来。');
    });

    test('playFromSentence 跳句：从指定句开始读', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFromSentence(0, 2);

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 2);
      expect(ctrl.activeSentenceText, '他失去了记忆。');
      expect(engine.spoken.last, '他失去了记忆。');
      expect(ctrl.playing, isTrue);

      // 从别的卡片跳句同理
      await ctrl.playFromSentence(1, 1);
      expect(ctrl.activeIndex, 1);
      expect(ctrl.activeSentenceIndex, 1);
      expect(engine.spoken.last, '李云飞拜入青云宗。');
    });

    test('playFromSentence 序号越界会被夹到有效范围', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFromSentence(0, 99);
      expect(ctrl.activeSentenceIndex, 2);

      await ctrl.playFromSentence(0, -5);
      expect(ctrl.activeSentenceIndex, 0);
    });

    test('空句子计划的事件不占朗读时间：直接算读完并连读下一个', () async {
      final engine = FakeTtsEngine();
      final ctrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: engine,
      );
      addTearDown(ctrl.dispose);
      // 第 1 个事件标题 / 概要 / 正文全空：朗读计划为空
      ctrl.init(
        [
          ch(1, 'major', '', ''),
          ch(2, 'minor', '拜师', '李云飞拜入青云宗。'),
        ],
        reload: false,
      );
      expect(ctrl.sentenceCountForIndex(0), 0);

      await ctrl.play();
      await settle();

      expect(ctrl.activeIndex, 1, reason: '空事件不该卡在播放');
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.single, '小事件1，拜师');
    });

    test('一个事件读完后 activeSentenceIndex 归 -1，当前句信息清空', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(ctrl.settings.copyWith(autoNext: false));

      await ctrl.play();
      await finishEvent(engine, ctrl);

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, -1);
      expect(ctrl.activePiece, isNull);
      expect(ctrl.activeSentenceText, isEmpty);
      expect(ctrl.activeSentenceOrdinal, 0);
      expect(ctrl.activeSentenceProgress, 0);
      expect(ctrl.playing, isFalse);
    });
  });

  // ─── 媒体通知 seekbar：跳到当前事件内的某一句 ─────────────────────

  group('seekToSentence / seekToFraction（媒体通知拖动跳句）', () {
    test('播放中 seekToSentence：停掉当前句，从目标句重新朗读', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play(); // 当前在标题句
      final spokeBefore = engine.spoken.length;
      final stopBefore = engine.stopCount;

      await ctrl.seekToSentence(2); // 第 3 句（概要第 2 行）

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 2);
      expect(ctrl.activeSentenceText, '他失去了记忆。');
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.length, greaterThan(spokeBefore));
      // 从目标句重新发声：最后一条朗读请求就是目标句
      expect(engine.spoken.last, '他失去了记忆。');
      // 先停掉原来的 utterance 再读，不能两句叠着读
      expect(engine.stopCount, greaterThan(stopBefore));
    });

    test('播放中 seekToSentence 换到事件内其它句同样生效', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(1); // 事件 2：标题句 + 概要 1 句
      await ctrl.seekToSentence(1);

      expect(ctrl.activeIndex, 1);
      expect(ctrl.activeSentenceIndex, 1);
      expect(engine.spoken.last, '李云飞拜入青云宗。');
      expect(ctrl.playing, isTrue);
    });

    test('seekToSentence 序号越界会被夹到有效范围', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);
      await ctrl.play();
      await ctrl.pause();

      await ctrl.seekToSentence(99);
      expect(ctrl.activeSentenceIndex, 2);

      await ctrl.seekToSentence(-5);
      expect(ctrl.activeSentenceIndex, 0);
    });

    test('暂停中 seekToSentence：只移动位置不发声，高亮 / 当前句跟着变', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.pause();
      final spokeBefore = engine.spoken.length;
      final stopBefore = engine.stopCount;

      await ctrl.seekToSentence(1);

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 1);
      expect(ctrl.activeSentenceText, '李云飞在青阳城醒来。');
      // 暂停中只挪位置：不发声、也不去停一个本来就没在播的引擎
      expect(engine.spoken.length, spokeBefore, reason: '暂停中 seek 不该发声');
      expect(engine.stopCount, stopBefore, reason: '暂停中 seek 不该再停引擎');

      // 高亮随位置移动：标题高亮灭、概要句高亮亮
      final piece = ctrl.planForIndex(0).pieces[1];
      final range = ctrl.segments[0].summaryCtrl.highlightRange;
      expect(range, isNotNull);
      expect(range!.start, piece.start);
      expect(range.end, piece.end);
      expect(ctrl.segments[0].titleCtrl.highlightRange, isNull);

      // 再点播放：从跳过去的那一句继续，而不是退回事件开头
      await ctrl.play();
      expect(ctrl.activeSentenceIndex, 1);
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '李云飞在青阳城醒来。');
    });

    test('seekToFraction 边界：0 → 第 1 句、1.0 → 最后一句、中间值按 floor 换算', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.pause();
      expect(ctrl.activeSentenceCount, 3);
      final spokeBefore = engine.spoken.length;

      await ctrl.seekToFraction(0);
      expect(ctrl.activeSentenceIndex, 0, reason: '0 → 第 1 句');

      await ctrl.seekToFraction(1.0);
      expect(ctrl.activeSentenceIndex, 2, reason: '1.0 → 最后一句');

      // 中间值 floor(比例 × 句数)：0.5 × 3 = 1.5 → 下标 1
      await ctrl.seekToFraction(0.5);
      expect(ctrl.activeSentenceIndex, 1);
      // 0.33 × 3 = 0.99 → 下标 0；0.34 × 3 = 1.02 → 下标 1（floor 而不是四舍五入）
      await ctrl.seekToFraction(0.33);
      expect(ctrl.activeSentenceIndex, 0);
      await ctrl.seekToFraction(0.34);
      expect(ctrl.activeSentenceIndex, 1);

      // 比例先 clamp 到 0~1：负数 → 第 1 句，>1 → 最后一句
      await ctrl.seekToFraction(-0.5);
      expect(ctrl.activeSentenceIndex, 0);
      await ctrl.seekToFraction(2.0);
      expect(ctrl.activeSentenceIndex, 2);

      expect(ctrl.playing, isFalse);
      expect(engine.spoken.length, spokeBefore, reason: '暂停中只移动位置');
    });

    test('播放中 seekToFraction：按比例跳句并从该句立即继续朗读', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.seekToFraction(1.0);
      expect(ctrl.activeSentenceIndex, 2);
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '他失去了记忆。');

      await ctrl.seekToFraction(0.5);
      expect(ctrl.activeSentenceIndex, 1);
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '李云飞在青阳城醒来。');
    });

    test('没有朗读位置 / 当前事件没有句子时 seek 是 no-op（不发声也不通知）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      var notified = 0;
      ctrl.addListener(() => notified++);

      await ctrl.seekToSentence(1);
      await ctrl.seekToFraction(0.5);
      expect(ctrl.activeIndex, -1);
      expect(ctrl.activeSentenceIndex, -1);
      expect(ctrl.playing, isFalse);
      expect(engine.spoken, isEmpty);
      expect(notified, 0, reason: '没有朗读位置时 no-op，不该触发页面重建');

      // 当前事件一句都拆不出来（标题 / 概要是空）：同样什么都不做
      final emptyEngine = FakeTtsEngine();
      final emptyCtrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: emptyEngine,
      );
      addTearDown(emptyCtrl.dispose);
      emptyCtrl.init([ch(1, 'major', '', '')], reload: false);
      emptyCtrl.activeIndex = 0; // 直接摆位置（正常连读时空事件会被立刻跳过）
      var emptyNotified = 0;
      emptyCtrl.addListener(() => emptyNotified++);

      await emptyCtrl.seekToSentence(0);
      await emptyCtrl.seekToFraction(0.5);
      expect(emptyCtrl.activeSentenceIndex, -1);
      expect(emptyEngine.spoken, isEmpty);
      expect(emptyNotified, 0);
    });
  });

  // ─── 通知展开视图「退 3 句 / 进 3 句」：事件内相对跳句 ─────────────

  group('seekBy（通知展开视图退 / 进 3 句）', () {
    /// 事件 1 有 5 句概要（+ 标题句 = 6 句），足够验 +3 / -3 的相对移动
    OutlineListenController buildLong({FakeTtsEngine? engine}) {
      final ctrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: engine ?? FakeTtsEngine(),
      );
      ctrl.init([
        ch(1, 'major', '初入江湖', '第一句。第二句。第三句。第四句。第五句。'),
        ch(2, 'minor', '拜师', '只有一句。'),
      ], reload: false);
      return ctrl;
    }

    test('播放中 +3：从目标句继续读（不是整个事件重读）', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);
      expect(ctrl.sentenceCountForIndex(0), 6);

      await ctrl.play(); // 当前在标题句（下标 0）
      await ctrl.seekBy(3);

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 3);
      expect(ctrl.activeSentenceText, '第三句。');
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '第三句。');
    });

    test('播放中 -3：从目标句回退重读', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.seekBy(4); // 先到「第四句。」
      expect(ctrl.activeSentenceIndex, 4);

      await ctrl.seekBy(-3);
      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 1);
      expect(ctrl.activeSentenceText, '第一句。');
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '第一句。');
    });

    test('边界：开头 -3 夹到第 1 句；最后一句 +3 夹到最后一句，不跨事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.seekBy(-3); // 0 - 3 → 夹到 0
      expect(ctrl.activeSentenceIndex, 0);
      expect(ctrl.activeIndex, 0);
      expect(engine.spoken.last, startsWith('大事件1'));

      await ctrl.seekBy(3); // 0 → 3
      await ctrl.seekBy(3); // 3 → 6 → 夹到 5
      expect(ctrl.activeSentenceIndex, 5);
      expect(ctrl.activeSentenceText, '第五句。');

      await ctrl.seekBy(3); // 最后一句再 +3：仍停在最后一句
      expect(ctrl.activeSentenceIndex, 5);
      expect(ctrl.activeIndex, 0, reason: '不跨到下一个事件');
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, '第五句。');
    });

    test('暂停中 seekBy：只移动位置不发声，高亮随动；再播放从该句继续', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await ctrl.pause();
      final spokeBefore = engine.spoken.length;
      final stopBefore = engine.stopCount;

      await ctrl.seekBy(3);

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, 3);
      expect(ctrl.activeSentenceText, '第三句。');
      expect(engine.spoken.length, spokeBefore, reason: '暂停中 seekBy 不该发声');
      expect(engine.stopCount, stopBefore, reason: '暂停中 seekBy 不该再停引擎');

      // 高亮跟着移动到「第三句。」所在的概要区间
      final piece = ctrl.planForIndex(0).pieces[3];
      final range = ctrl.segments[0].summaryCtrl.highlightRange;
      expect(range, isNotNull);
      expect(range!.start, piece.start);
      expect(range.end, piece.end);

      // 再点播放：从跳过去的那一句继续
      await ctrl.play();
      expect(ctrl.activeSentenceIndex, 3);
      expect(engine.spoken.last, '第三句。');
    });

    test('事件读完后 activeSentenceIndex<0：seekBy 是 no-op（不发声不通知）', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(ctrl.settings.copyWith(autoNext: false));

      await ctrl.play();
      await finishEvent(engine, ctrl);
      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, -1);

      final spokeBefore = engine.spoken.length;
      var notified = 0;
      ctrl.addListener(() => notified++);

      await ctrl.seekBy(3);
      await ctrl.seekBy(-3);

      expect(ctrl.activeIndex, 0);
      expect(ctrl.activeSentenceIndex, -1, reason: '读完后不跳回某一句');
      expect(engine.spoken.length, spokeBefore);
      expect(notified, 0);
    });

    test('没有朗读位置 / 当前事件没有句子：seekBy 是 no-op', () async {
      final engine = FakeTtsEngine();
      final ctrl = buildLong(engine: engine);
      addTearDown(ctrl.dispose);

      var notified = 0;
      ctrl.addListener(() => notified++);

      await ctrl.seekBy(3);
      await ctrl.seekBy(-3);
      expect(ctrl.activeIndex, -1);
      expect(ctrl.activeSentenceIndex, -1);
      expect(engine.spoken, isEmpty);
      expect(notified, 0, reason: '没有朗读位置时 no-op，不该触发页面重建');

      // 当前事件一句都拆不出来（标题 / 概要是空）：同样什么都不做
      final emptyEngine = FakeTtsEngine();
      final emptyCtrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: emptyEngine,
      );
      addTearDown(emptyCtrl.dispose);
      emptyCtrl.init([ch(1, 'major', '', '')], reload: false);
      emptyCtrl.activeIndex = 0; // 直接摆位置（正常连读时空事件会被立刻跳过）
      var emptyNotified = 0;
      emptyCtrl.addListener(() => emptyNotified++);

      await emptyCtrl.seekBy(3);
      expect(emptyCtrl.activeSentenceIndex, -1);
      expect(emptyEngine.spoken, isEmpty);
      expect(emptyNotified, 0);
    });
  });

  group('整篇朗读进度 overallProgress', () {
    test('按「范围内事件序号 + 事件内句子占比」推进', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      expect(ctrl.overallProgress, 0);
      await ctrl.play();
      expect(ctrl.overallProgress, 0);

      // 事件 1 共 3 句：听完第 1 句 → (0 + 1/3) / 2
      await finishSentence(engine, ctrl);
      expect(ctrl.overallProgress, closeTo((1 / 3) / 2, 1e-9));
      // 听完第 2 句 → (0 + 2/3) / 2
      await finishSentence(engine, ctrl);
      expect(ctrl.overallProgress, closeTo((2 / 3) / 2, 1e-9));

      // 进入事件 2（共 2 句）→ (1 + 0) / 2
      await finishEvent(engine, ctrl);
      expect(ctrl.activeIndex, 1);
      expect(ctrl.overallProgress, closeTo(0.5, 1e-9));
      await finishSentence(engine, ctrl);
      expect(ctrl.overallProgress, closeTo((1 + 1 / 2) / 2, 1e-9));
    });

    test('事件内句子进度 activeSentenceProgress（0~1，最后一句读满）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      expect(ctrl.activeSentenceProgress, 0);
      await ctrl.play();
      expect(ctrl.activeSentenceProgress, closeTo(1 / 3, 1e-9));
      await finishSentence(engine, ctrl);
      expect(ctrl.activeSentenceProgress, closeTo(2 / 3, 1e-9));
      await finishSentence(engine, ctrl);
      expect(ctrl.activeSentenceProgress, closeTo(1.0, 1e-9));
    });

    test('范围过滤后整篇进度按范围内事件数算（不是全篇）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );
      expect(ctrl.playableCount, 2);

      await ctrl.playFrom(2); // 范围内第 2 个（全篇第 3 个）
      expect(ctrl.activePlayableOrdinal, 2);
      // (1 + 0) / 2，与全篇 4 个事件无关
      expect(ctrl.overallProgress, closeTo(0.5, 1e-9));
    });
  });

  group('朗读事件范围（全部 / 只听大 / 只听小）', () {
    test('scope 过滤出范围内事件；进度文案按范围内数量算', () {
      final ctrl = build4();
      addTearDown(ctrl.dispose);

      expect(ctrl.playableIndices, [0, 1, 2, 3]);
      expect(ctrl.isPlayableAt(2), isTrue);
      expect(ctrl.progressLabel, '共 4 个事件');

      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );
      expect(ctrl.playableIndices, [0, 2]);
      expect(ctrl.playableCount, 2);
      expect(ctrl.isPlayableAt(1), isFalse);
      expect(ctrl.progressLabel, '共 2 个事件 · 只听大事件');

      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.minorOnly),
      );
      expect(ctrl.playableIndices, [1, 3]);
      expect(ctrl.playableCount, 2);
    });

    test('播放 / 下一个 / 上一个都只在范围内事件上走', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.minorOnly),
      );

      await ctrl.play();
      expect(ctrl.activeIndex, 1, reason: '只听小事件时从第 2 个事件（首个小的）开始');
      expect(ctrl.activePlayableOrdinal, 1);
      expect(engine.spoken.single, startsWith('小事件1，乙'));

      await ctrl.next();
      expect(ctrl.activeIndex, 3, reason: '下一个跳到范围内下一条（大事件被跳过）');
      expect(engine.spoken.last, startsWith('小事件1，丁'));
      expect(ctrl.activePlayableOrdinal, 2);

      await ctrl.previous();
      expect(ctrl.activeIndex, 1);
      expect(engine.spoken.last, startsWith('小事件1，乙'));
    });

    test('自动连读只走范围内事件：大事件读完后跳过中间的小事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );

      await ctrl.playFrom(0); // 大事件甲
      await finishEvent(engine, ctrl); // 读完整事件，自动连读下一条

      // 事件 1（小事件乙）不在范围内：直接跳到事件 2（大事件丙）
      expect(ctrl.activeIndex, 2);
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, startsWith('大事件2，丙'));
    });

    test('范围最后一个事件：不开循环就停并标记读完', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );

      await ctrl.playFrom(2); // 范围内最后一个
      await ctrl.next();

      expect(ctrl.playing, isFalse);
      expect(ctrl.finished, isTrue);
      expect(ctrl.activeIndex, 2);
      expect(ctrl.activeSentenceIndex, -1);
    });

    test('开了循环后范围最后一个读完回到范围内第一个（不是全篇第一个）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(
          scope: OutlineListenScope.minorOnly,
          repeat: true,
        ),
      );

      await ctrl.playFrom(3); // 范围最后一个（全篇第 4 个）
      await finishEvent(engine, ctrl);

      expect(ctrl.activeIndex, 1, reason: '循环回到范围内第一个（第 2 个事件）');
      expect(ctrl.playing, isTrue);
    });

    test('playFrom 点到范围外的事件：从它后面最近的可读事件开始', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );

      await ctrl.playFrom(1); // 小事件，范围外 → 后面最近的大事件是 2
      expect(ctrl.activeIndex, 2);
      expect(engine.spoken.single, startsWith('大事件2，丙'));

      // 最后一个事件是范围外的：后面没有了，回到范围内第一个
      await ctrl.playFrom(3);
      expect(ctrl.activeIndex, 0);
    });

    test('朗读中切换范围、当前事件被排除：跳到范围内下一个继续读', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(1); // 小事件，正在读
      expect(ctrl.playing, isTrue);

      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );
      await settle();
      await settle();

      expect(ctrl.activeIndex, 2);
      expect(ctrl.playing, isTrue);
      expect(engine.spoken.last, startsWith('大事件2，丙'));
    });

    test('朗读中切换范围、当前事件仍在范围内：继续读，不跳', () async {
      final engine = FakeTtsEngine();
      final ctrl = build4(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(0); // 大事件，正在读
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.majorOnly),
      );
      await settle();

      expect(ctrl.activeIndex, 0);
      expect(ctrl.playing, isTrue);
    });

    test('范围内一个事件都没有时：不假播，如实提示', () async {
      final engine = FakeTtsEngine();
      final ctrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: engine,
      );
      addTearDown(ctrl.dispose);
      ctrl.init(
        [ch(1, 'major', '甲', '概要一。'), ch(2, 'major', '乙', '概要二。')],
        reload: false,
      );
      ctrl.updateSettings(
        ctrl.settings.copyWith(scope: OutlineListenScope.minorOnly),
      );

      expect(ctrl.playableCount, 0);
      expect(ctrl.progressLabel, '当前范围内没有可朗读的事件');

      await ctrl.play();

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, -1);
      expect(ctrl.errorMessage, contains('当前朗读范围内没有可播放的事件'));
      expect(engine.spoken, isEmpty);
    });
  });

  group('当前句高亮（标题 / 概要输入框）', () {
    test('播放时高亮标题整段；概要与其他卡片都不高亮', () async {
      final ctrl = build();
      addTearDown(ctrl.dispose);

      await ctrl.play();

      expect(
        ctrl.segments[0].titleCtrl.highlightRange,
        const TextRange(start: 0, end: 4),
      );
      expect(ctrl.segments[0].summaryCtrl.highlightRange, isNull);
      expect(ctrl.segments[1].titleCtrl.highlightRange, isNull);
      expect(ctrl.segments[1].summaryCtrl.highlightRange, isNull);
    });

    test('推进到概要句时高亮对应区间，标题高亮清掉', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await finishSentence(engine, ctrl);

      final piece = ctrl.planForIndex(0).pieces[1];
      final range = ctrl.segments[0].summaryCtrl.highlightRange;
      expect(range, isNotNull);
      expect(range!.start, piece.start);
      expect(range.end, piece.end);
      expect(
        ctrl.segments[0].summaryCtrl.text.substring(range.start, range.end),
        piece.text,
      );
      expect(ctrl.segments[0].titleCtrl.highlightRange, isNull);
    });

    test('切换到另一个事件后旧卡片高亮全部清除', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await finishSentence(engine, ctrl);
      await ctrl.playFrom(1);

      expect(ctrl.segments[0].titleCtrl.highlightRange, isNull);
      expect(ctrl.segments[0].summaryCtrl.highlightRange, isNull);
      expect(ctrl.segments[1].titleCtrl.highlightRange, isNotNull);
    });

    test('停止后所有高亮清除', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      expect(ctrl.segments[0].titleCtrl.highlightRange, isNotNull);

      await ctrl.stop();

      expect(ctrl.segments[0].titleCtrl.highlightRange, isNull);
      expect(ctrl.segments[1].titleCtrl.highlightRange, isNull);
    });
  });

  group('后台朗读通知同步（注入假通知器）', () {
    OutlineListenController buildWith(
      FakeTtsEngine engine,
      FakeListenNotification notification,
    ) {
      final ctrl = OutlineListenController(
        OutlineRecord(title: '测试小说', content: ''),
        engine: engine,
        notification: notification,
      );
      ctrl.init(chapters(), reload: false);
      return ctrl;
    }

    test('播放 start → 句子推进 update → 暂停 paused → 停止 cancel', () async {
      final fake = FakeListenNotification();
      final engine = FakeTtsEngine();
      final ctrl = buildWith(engine, fake);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await settle();
      expect(fake.calls, ['start']);
      expect(fake.lastStart!.kind, ListenNotificationKind.playing);
      expect(fake.lastStart!.content, contains('第1/2个事件'));
      expect(fake.lastStart!.content, contains('第1/3句'));
      expect(fake.lastStart!.subText, contains('大事件1'));
      // 通知进度 = 事件内句子进度：第 1/3 句 → 33（不再是整篇事件百分比 0）
      expect(fake.lastStart!.progress, 33);

      await finishSentence(engine, ctrl);
      await settle();
      expect(fake.calls, contains('update'));
      expect(fake.lastUpdate!.kind, ListenNotificationKind.playing);
      expect(fake.lastUpdate!.content, contains('第2/3句'));
      expect(fake.lastUpdate!.subText, '李云飞在青阳城醒来。');
      expect(fake.lastUpdate!.progress, 67, reason: '第 2/3 句 → 67');

      await ctrl.pause();
      await settle();
      expect(fake.calls.last, 'update');
      expect(fake.lastUpdate!.kind, ListenNotificationKind.paused);
      expect(fake.lastUpdate!.content, contains('停在第1/2个事件'));
      expect(fake.lastUpdate!.progress, 67, reason: '暂停进度与播放中同规则');

      await ctrl.stop();
      await settle();
      expect(fake.calls.last, 'cancel');
    });

    test('整篇读完：finish(success: true) 并带事件数', () async {
      final fake = FakeListenNotification();
      final engine = FakeTtsEngine();
      final ctrl = buildWith(engine, fake);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(ctrl.segments.length - 1);
      await finishEvent(engine, ctrl);
      await settle();

      expect(ctrl.finished, isTrue);
      expect(fake.calls.last, 'finish');
      expect(fake.lastSuccess, isTrue);
      expect(fake.lastFinish!.kind, ListenNotificationKind.finished);
      expect(fake.lastFinish!.content, contains('共 2 个事件'));
      expect(fake.lastFinish!.progress, 100);
    });

    test('引擎报错：通知切到暂停态并带上错误原因', () async {
      final fake = FakeListenNotification();
      final engine = FakeTtsEngine();
      final ctrl = buildWith(engine, fake);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      await settle();
      engine.failCurrent('朗读通道异常');
      await settle();

      expect(ctrl.playing, isFalse);
      expect(ctrl.errorMessage, isNotEmpty);
      expect(fake.calls.last, 'update');
      expect(fake.lastUpdate!.kind, ListenNotificationKind.paused);
      expect(fake.lastUpdate!.subText, contains('朗读通道异常'));
    });
  });

  group('后台继续朗读开关 setBackgroundPlayback', () {
    test('播放打开、暂停 / 停止关闭', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      expect(engine.backgroundPlayback, isNull);
      await ctrl.play();
      expect(engine.backgroundPlayback, isTrue);

      await ctrl.pause();
      expect(engine.backgroundPlayback, isFalse);

      await ctrl.play();
      expect(engine.backgroundPlayback, isTrue);

      await ctrl.stop();
      expect(engine.backgroundPlayback, isFalse);
    });

    test('整篇读完 / 引擎出错时也会关掉（避免退后台还在读）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(ctrl.segments.length - 1);
      expect(engine.backgroundPlayback, isTrue);
      await finishEvent(engine, ctrl);
      expect(engine.backgroundPlayback, isFalse);

      final engine2 = FakeTtsEngine()..failNextSpeak = true;
      final ctrl2 = build(engine: engine2);
      addTearDown(ctrl2.dispose);
      await ctrl2.play();
      expect(ctrl2.playing, isFalse);
      expect(engine2.backgroundPlayback, isFalse);
    });
  });

  group('会话保留判定 isSessionNeeded', () {
    test('有朗读位置（含暂停）为 true；停止后为 false', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      expect(ctrl.isSessionNeeded, isFalse);
      await ctrl.play();
      expect(ctrl.isSessionNeeded, isTrue);
      await ctrl.pause();
      expect(ctrl.isSessionNeeded, isTrue, reason: '暂停位置要保留给后台会话');
      await ctrl.stop();
      expect(ctrl.isSessionNeeded, isFalse);
    });

    test('整篇听完仍保留位置（页面关闭时才释放）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(ctrl.segments.length - 1);
      await finishEvent(engine, ctrl);

      expect(ctrl.finished, isTrue);
      expect(ctrl.isSessionNeeded, isTrue);
    });
  });
}

/// 假通知器：只记录控制器发来的通知调用，不做任何平台交互。
///
/// `supported: false` 让基类自身的逻辑保持 no-op；所有会触发原生调用的方法
/// 都被重写为纯记录，因此单测里不会碰 MethodChannel。
class FakeListenNotification extends OutlineListeningNotification {
  FakeListenNotification() : super(supported: false);

  final List<String> calls = [];
  OutlineListeningNotificationContent? lastStart;
  OutlineListeningNotificationContent? lastUpdate;
  OutlineListeningNotificationContent? lastFinish;
  bool? lastSuccess;

  @override
  Future<bool> ensurePermission() async => false;

  @override
  Future<void> start(OutlineListeningNotificationContent c) async {
    calls.add('start');
    lastStart = c;
  }

  @override
  void update(OutlineListeningNotificationContent c) {
    calls.add('update');
    lastUpdate = c;
  }

  @override
  Future<void> finish(
    OutlineListeningNotificationContent c, {
    required bool success,
  }) async {
    calls.add('finish');
    lastFinish = c;
    lastSuccess = success;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
  }
}
