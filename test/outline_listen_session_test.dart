import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/background/outline_listen_session.dart';
import 'package:deepseekapp/features/novel_writing/outline_listening/controller/outline_listen_controller.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 进程级「听大纲」朗读会话：[OutlineListenSession]。
///
/// 这个类的意义是「页面关掉后朗读还在」：页面只是视图，controller 归会话所有；
/// 从通知点回来 / 再次进入同一条大纲要挂回同一个 controller（位置与高亮不丢）。
/// 因此测试重点全部在**所有权与生命周期**：
/// - 什么时候新建、什么时候挂回、什么时候释放；
/// - 页面 detach 时 playing / 暂停位置要保留，停止 / 听完才释放；
/// - 通知栏操作按钮要转给当前 controller。
///
/// 不初始化真引擎：需要「有朗读位置」时直接给 [OutlineListenController.activeIndex]
/// 赋值（它就是 isSessionNeeded 的判定依据），避免测试依赖 TTS 通道。
/// 原生通道统一用 mock handler 兜住，测试不会真的发出平台调用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const localTtsChannel = MethodChannel('deepseek_app/local_tts');
  const listenChannel = MethodChannel('deepseek_app/outline_listening');

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 会话自己 new 的 controller 用 FallbackTtsEngine（系统 TTS + 内置语音）。
    // 测试环境下系统 TTS 是 Unsupported，只剩内置语音通道会发平台调用：全部兜住。
    messenger.setMockMethodCallHandler(localTtsChannel, (_) async => null);
    messenger.setMockMethodCallHandler(listenChannel, (_) async => null);
    OutlineListenSession.instance.resetForTest();
  });

  tearDown(() {
    OutlineListenSession.instance.resetForTest();
  });

  OutlineRecord outline({int id = 1, String title = '测试小说'}) =>
      OutlineRecord(id: id, title: title, content: '');

  List<OutlineChapter> chapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 1,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '初入江湖',
      eventSummary: '李云飞在青阳城醒来。',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 1,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '拜师',
      eventSummary: '李云飞拜入青云宗。',
    ),
    OutlineChapter(
      id: 3,
      outlineId: 1,
      eventIndex: 3,
      eventType: 'major',
      eventTitle: '下山',
      eventSummary: '他第一次下山。',
    ),
  ];

  /// 一个事件里含 5 句概要的章节表：用于「退 / 进 3 句」这类相对跳句用例
  List<OutlineChapter> longChapters() => [
    OutlineChapter(
      id: 1,
      outlineId: 1,
      eventIndex: 1,
      eventType: 'major',
      eventTitle: '初入江湖',
      eventSummary: '第一句。第二句。第三句。第四句。第五句。',
    ),
    OutlineChapter(
      id: 2,
      outlineId: 1,
      eventIndex: 2,
      eventType: 'minor',
      eventTitle: '拜师',
      eventSummary: '只有一句。',
    ),
  ];

  /// 建会话并把卡片装好（不播放：位置由测试直接摆）
  ({OutlineListenController ctrl, bool attachedExisting}) attach(
    OutlineRecord record, {
    bool preferExisting = true,
    List<OutlineChapter>? withChapters,
  }) {
    final list = withChapters ?? chapters();
    final result = OutlineListenSession.instance.acquire(
      record,
      list,
      preferExisting: preferExisting,
    );
    // 挂回已有会话时不能再 init：那会把正在读的位置与卡片文本冲掉
    if (!result.attachedExisting) {
      result.controller.init(list, reload: false);
    }
    return (ctrl: result.controller, attachedExisting: result.attachedExisting);
  }

  /// 等会话的「微任务后自动释放」跑完
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('acquire：新建 / 挂回 / 重建', () {
    test('没有会话时新建 controller，并记住对应的大纲记录', () {
      final record = outline();
      final attachResult = OutlineListenSession.instance.acquire(record, chapters());

      expect(attachResult.attachedExisting, isFalse);
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
      expect(
        identical(OutlineListenSession.instance.controller, attachResult.controller),
        isTrue,
      );
      expect(OutlineListenSession.instance.activeRecord?.id, 1);
      expect(attachResult.controller.outline.title, '测试小说');
    });

    test('同一条大纲且还有朗读位置：挂回原 controller（位置 / 高亮都不丢）', () {
      final first = attach(outline());
      first.ctrl.activeIndex = 1; // 暂停在第二个事件
      first.ctrl.activeSentenceIndex = 0;

      final second = attach(outline());

      expect(second.attachedExisting, isTrue);
      expect(identical(second.ctrl, first.ctrl), isTrue);
      expect(second.ctrl.activeIndex, 1);
    });

    test('同一条大纲但已经没有朗读位置（停止 / 从未播放）：重建 controller', () {
      final first = attach(outline());
      expect(first.ctrl.activeIndex, -1);

      final second = attach(outline());

      expect(second.attachedExisting, isFalse);
      expect(identical(second.ctrl, first.ctrl), isFalse);
      // 旧 controller 已释放：卡片表清空
      expect(first.ctrl.segments, isEmpty);
    });

    test('不同大纲：释放旧会话，按新大纲重建', () {
      final first = attach(outline(id: 1, title: '第一本'));
      first.ctrl.activeIndex = 2; // 有位置，但大纲换了也必须重建

      final second = attach(outline(id: 2, title: '第二本'));

      expect(second.attachedExisting, isFalse);
      expect(identical(second.ctrl, first.ctrl), isFalse);
      expect(first.ctrl.segments, isEmpty);
      expect(second.ctrl.outline.title, '第二本');
      expect(OutlineListenSession.instance.activeRecord?.id, 2);
    });

    test('preferExisting: false（例如从书库「重新进入」）时即使同大纲也重建', () {
      final first = attach(outline());
      first.ctrl.activeIndex = 1;

      final second = attach(outline(), preferExisting: false);

      expect(second.attachedExisting, isFalse);
      expect(identical(second.ctrl, first.ctrl), isFalse);
    });
  });

  group('detachPage：页面关闭后的去留', () {
    test('还在读 / 暂停在某个位置：保留 controller（后台继续）', () {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      a.ctrl.playing = true;

      OutlineListenSession.instance.detachPage(a.ctrl);

      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
      expect(
        identical(OutlineListenSession.instance.controller, a.ctrl),
        isTrue,
      );
      expect(OutlineListenSession.instance.activeRecord, isNotNull);
    });

    test('已经停止（没有朗读位置）：detach 后直接释放', () {
      final a = attach(outline());
      a.ctrl.activeIndex = -1;

      OutlineListenSession.instance.detachPage(a.ctrl);

      expect(OutlineListenSession.instance.hasActiveSession, isFalse);
      expect(OutlineListenSession.instance.controller, isNull);
      expect(OutlineListenSession.instance.activeRecord, isNull);
      expect(a.ctrl.segments, isEmpty);
    });

    test('整篇听完（finished）时页面关闭 → 释放（听完保留到用户看过页面为止）', () {
      final a = attach(outline());
      a.ctrl.activeIndex = 2;
      a.ctrl.finished = true;

      OutlineListenSession.instance.detachPage(a.ctrl);

      expect(OutlineListenSession.instance.hasActiveSession, isFalse);
    });

    test('页面已关闭后 controller 才停止：微任务后自动释放，不常驻内存', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      OutlineListenSession.instance.detachPage(a.ctrl);
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);

      // 用户点通知栏「停止」：controller 回到无位置状态并发出通知
      a.ctrl.activeIndex = -1;
      a.ctrl.notifyListeners();
      await settle();

      expect(OutlineListenSession.instance.hasActiveSession, isFalse);
    });

    test('多页面挂载同一会话：还有一个页面时 detach 不触发释放判定', () {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      // 第二个页面挂回同一会话
      final b = OutlineListenSession.instance.acquire(outline(), null);
      expect(b.attachedExisting, isTrue);
      expect(identical(b.controller, a.ctrl), isTrue);

      // 第一个页面关闭：还有页面挂着，即使 controller 已停止也不释放
      a.ctrl.activeIndex = -1;
      a.ctrl.notifyListeners();
      OutlineListenSession.instance.detachPage(a.ctrl);
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);

      // 最后一个页面也关了：按「无位置」释放
      OutlineListenSession.instance.detachPage(b.controller);
      expect(OutlineListenSession.instance.hasActiveSession, isFalse);
    });

    test('detach 不属于当前会话的 controller 是空操作', () {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      final other = OutlineListenController(
        outline(id: 9, title: '别的书'),
      );
      addTearDown(other.dispose);

      OutlineListenSession.instance.detachPage(other);

      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
      expect(
        identical(OutlineListenSession.instance.controller, a.ctrl),
        isTrue,
      );
    });
  });

  group('通知栏操作按钮 → 当前 controller', () {
    test('stop：停止朗读并清空位置（页面已关闭时会话随后释放）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 2;
      a.ctrl.activeSentenceIndex = 0;
      OutlineListenSession.instance.detachPage(a.ctrl); // 页面先在后台
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('stop');
      await settle();

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, -1);
      expect(a.ctrl.playing, isFalse);
      expect(OutlineListenSession.instance.hasActiveSession, isFalse);
    });

    test('toggle：播放中转暂停，位置保留；会话继续保留', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      a.ctrl.playing = true;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('toggle');

      expect(handled, isTrue);
      expect(a.ctrl.playing, isFalse, reason: '播放中点「暂停继续」应暂停');
      expect(a.ctrl.activeIndex, 1, reason: '暂停保留位置');
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
    });

    test('prev：跳到上一个事件（转给 controller.previous）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 2;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('prev');

      expect(handled, isTrue);
      // 转给了 controller：位置从第 3 个事件退到第 2 个
      expect(a.ctrl.activeIndex, 1);
    });

    test('next：跳到下一个事件（转给 controller.next）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1; // 暂停在第二个事件

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('next');

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, 2, reason: 'next 转给了 controller.next');
      // 测试环境没有可用语音引擎：位置前进了，但不假装在播
      expect(a.ctrl.playing, isFalse);
    });

    test('next：已经在最后一个事件且不循环 → 标记听完', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 2;
      a.ctrl.activeSentenceIndex = 0;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('next');

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, 2);
      expect(a.ctrl.finished, isTrue);
      expect(a.ctrl.playing, isFalse);
      expect(a.ctrl.activeSentenceIndex, -1);
    });

    test('play：已播放时不再重复 play（避免当前句从头重读）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      a.ctrl.activeSentenceIndex = 0;
      a.ctrl.playing = true;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('play');

      expect(handled, isTrue);
      // 状态原样保留：没有被 play 打断成「从头重读当前事件」
      expect(a.ctrl.playing, isTrue);
      expect(a.ctrl.activeIndex, 1);
      expect(a.ctrl.activeSentenceIndex, 0);
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
    });

    test('play：未播放时转给 controller.play（从当前位置开始）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = -1;
      a.ctrl.playing = false;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('play');

      expect(handled, isTrue);
      // 转给了 controller.play：没有位置时会从范围内第一个事件开始；
      // 测试环境引擎起不来，所以位置到了、但不假装在播
      expect(a.ctrl.activeIndex, 0, reason: 'play 分支转给了 controller.play');
      expect(a.ctrl.playing, isFalse);
    });

    test('pause：播放中暂停；已暂停时再发 pause 也是幂等成功', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      a.ctrl.playing = true;

      expect(
        await OutlineListenSession.instance.handleNotificationAction('pause'),
        isTrue,
      );
      expect(a.ctrl.playing, isFalse);
      expect(a.ctrl.activeIndex, 1, reason: '暂停保留位置');

      // 已经是暂停态：再发 pause 不改变任何东西，但仍算处理成功（幂等）
      expect(
        await OutlineListenSession.instance.handleNotificationAction('pause'),
        isTrue,
      );
      expect(a.ctrl.playing, isFalse);
      expect(a.ctrl.activeIndex, 1);
    });

    test('未知 action / 没有会话时返回 false（不抛异常）', () async {
      expect(
        await OutlineListenSession.instance.handleNotificationAction('toggle'),
        isFalse,
      );

      final a = attach(outline());
      a.ctrl.activeIndex = 1;
      expect(
        await OutlineListenSession.instance.handleNotificationAction('unknown'),
        isFalse,
      );
      expect(OutlineListenSession.instance.hasActiveSession, isTrue);
    });
  });

  group('媒体通知 seekbar：seekToFraction → controller', () {
    test('有会话：返回 true 并转给 controller（暂停中只移动位置）', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1; // 暂停在第二个事件（未播放）
      a.ctrl.activeSentenceIndex = 0;

      final handled = await OutlineListenSession.instance.seekToFraction(1.0);

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, 1);
      // 事件 2 = 标题句 + 概要句：1.0 → 最后一句（下标 1）
      expect(a.ctrl.activeSentenceIndex, 1);
      expect(a.ctrl.playing, isFalse, reason: '暂停中只挪位置，不开始朗读');
      // 高亮跟着移动：标题高亮灭、概要句高亮亮
      expect(a.ctrl.segments[1].titleCtrl.highlightRange, isNull);
      expect(a.ctrl.segments[1].summaryCtrl.highlightRange, isNotNull);
    });

    test('比例会先 clamp：负数 → 第 1 句，>1 → 最后一句', () async {
      final a = attach(outline());
      a.ctrl.activeIndex = 1;

      await OutlineListenSession.instance.seekToFraction(-0.5);
      expect(a.ctrl.activeSentenceIndex, 0);

      await OutlineListenSession.instance.seekToFraction(2.0);
      expect(a.ctrl.activeSentenceIndex, 1);
      expect(a.ctrl.playing, isFalse);
    });

    test('无会话：返回 false（拖动事件有时效，不排队等会话恢复）', () async {
      expect(await OutlineListenSession.instance.seekToFraction(0.5), isFalse);
    });

    test('会话在但 controller 没有朗读位置：返回 true（已处理），位置不变', () async {
      final a = attach(outline());
      expect(a.ctrl.activeIndex, -1);

      final handled = await OutlineListenSession.instance.seekToFraction(0.5);

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, -1);
      expect(a.ctrl.activeSentenceIndex, -1);
      expect(a.ctrl.playing, isFalse);
    });
  });

  group('通知展开视图：rewind / forward（退 / 进 3 句）', () {
    test('forward：转发到 controller.seekBy(+3)，当前事件内前进 3 句', () async {
      final a = attach(outline(), withChapters: longChapters());
      a.ctrl.activeIndex = 0;
      a.ctrl.activeSentenceIndex = 1; // 暂停在事件 1 的第 2 句

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('forward');

      expect(handled, isTrue);
      expect(a.ctrl.activeSentenceIndex, 4, reason: '1 + 3 = 4（暂停中只挪位置）');
      expect(a.ctrl.activeIndex, 0, reason: '不跨事件');
      expect(a.ctrl.playing, isFalse);
    });

    test('rewind：转发到 controller.seekBy(-3)，当前事件内后退 3 句', () async {
      final a = attach(outline(), withChapters: longChapters());
      a.ctrl.activeIndex = 0;
      a.ctrl.activeSentenceIndex = 4;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('rewind');

      expect(handled, isTrue);
      expect(a.ctrl.activeSentenceIndex, 1, reason: '4 - 3 = 1');
      expect(a.ctrl.activeIndex, 0);
      expect(a.ctrl.playing, isFalse);
    });

    test('rewind 在事件开头：夹到第 1 句，不跨到上一个事件', () async {
      final a = attach(outline(), withChapters: longChapters());
      a.ctrl.activeIndex = 1;
      a.ctrl.activeSentenceIndex = 0;

      final handled = await OutlineListenSession.instance
          .handleNotificationAction('rewind');

      expect(handled, isTrue);
      expect(a.ctrl.activeIndex, 1, reason: '仍停在当前事件');
      expect(a.ctrl.activeSentenceIndex, 0);
    });

    test('activeSentenceIndex<0（事件已读完）时返回 true 但位置不动', () async {
      final a = attach(outline(), withChapters: longChapters());
      a.ctrl.activeIndex = 0;
      a.ctrl.activeSentenceIndex = -1;

      expect(
        await OutlineListenSession.instance.handleNotificationAction('forward'),
        isTrue,
      );
      expect(
        await OutlineListenSession.instance.handleNotificationAction('rewind'),
        isTrue,
      );
      expect(a.ctrl.activeIndex, 0);
      expect(a.ctrl.activeSentenceIndex, -1);
      expect(a.ctrl.playing, isFalse);
    });

    test('无会话：rewind / forward 都返回 false', () async {
      expect(
        await OutlineListenSession.instance.handleNotificationAction('rewind'),
        isFalse,
      );
      expect(
        await OutlineListenSession.instance.handleNotificationAction('forward'),
        isFalse,
      );
    });
  });
}
