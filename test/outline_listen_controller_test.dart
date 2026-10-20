import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

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

    test('读完一个事件自动读下一个（真机上由原生朗读完成回调驱动）', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.play();
      engine.finishCurrent();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.activeIndex, 1);
      expect(engine.spoken.length, 2);
      expect(engine.spoken.last, startsWith('小事件1，拜师'));
      expect(ctrl.spokenCount, 1);
    });

    test('关闭「自动连读」后读完一个事件就停', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(ctrl.settings.copyWith(autoNext: false));
      await ctrl.play();
      engine.finishCurrent();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.playing, isFalse);
      expect(ctrl.activeIndex, 0);
      expect(engine.spoken.length, 1);
    });

    test('读到最后一张卡片：不开循环就停并标记读完', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      await ctrl.playFrom(ctrl.segments.length - 1);
      await Future<void>.delayed(Duration.zero);
      engine.finishCurrent();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.playing, isFalse);
      expect(ctrl.finished, isTrue);
    });

    test('开循环后读完最后一张卡片回到第一个事件', () async {
      final engine = FakeTtsEngine();
      final ctrl = build(engine: engine);
      addTearDown(ctrl.dispose);

      ctrl.updateSettings(ctrl.settings.copyWith(repeat: true));
      await ctrl.playFrom(ctrl.segments.length - 1);
      engine.finishCurrent();
      await Future<void>.delayed(Duration.zero);

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
}
