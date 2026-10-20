import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/background/outline_background_notification.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';

/// 后台生成进度通知的测试（不触碰 Android 原生通道）。
///
/// 分三层验证：
/// 1. 通知文案是纯数据工厂（[OutlineNotificationContent]），直接断言字符串规则；
/// 2. 通知节流 / 去重逻辑用 `testWidgets` 的假时钟推进 400ms 窗口，
///    用 `debugInvokeOverride` 记录「发往原生」的调用，不真的走 MethodChannel；
/// 3. 控制器状态 → 通知阶段的同步（生成中 / 检查点暂停 / 完成 / 错误中断 / 取消），
///    用假通知器注入，不发起任何网络请求。
///
/// 为什么这些行为要测：通知是「退到后台后用户唯一能看到的进度」，
/// 文案错、节流失效（IPC 刷屏）或阶段切换漏掉（完成后还挂着「生成中」）
/// 都会直接让用户误以为生成卡死。
void main() {
  group('通知文案 · 生成中', () {
    test('还没生成出书名时，标题只说「正在生成大纲」', () {
      final content = OutlineNotificationContent.running(
        bookTitle: '   ',
        progressText: '正在准备生成...',
        progress: 5,
      );

      expect(content.kind, OutlineNotificationKind.running);
      expect(content.title, '正在生成大纲');
      expect(content.content, '正在准备生成...');
      // 没有任何步骤统计时，副文本引导用户点通知回详情页
      expect(content.subText, '点按查看生成详情');
    });

    test('已有书名时标题用中文书名号包住书名', () {
      final content = OutlineNotificationContent.running(
        bookTitle: '测试书',
        progressText: '定调 (1/4)',
        progress: 25,
      );

      expect(content.title, '正在生成大纲：《测试书》');
      expect(content.title, contains('《测试书》'));
      expect(content.content, '定调 (1/4)');
      expect(content.progress, 25);
    });

    test('progress 越界会被 clamp 到 0~100，避免通知进度条画错', () {
      expect(
        OutlineNotificationContent.running(
          bookTitle: '测试书',
          progressText: '',
          progress: 150,
        ).progress,
        100,
      );
      expect(
        OutlineNotificationContent.running(
          bookTitle: '测试书',
          progressText: '',
          progress: -20,
        ).progress,
        0,
      );
    });

    test('progressText / lastStepSummary 为空时有兜底文案，非空时展示统计', () {
      final empty = OutlineNotificationContent.running(
        bookTitle: '测试书',
        progressText: '  ',
        progress: 10,
        lastStepSummary: '   ',
      );
      expect(empty.content, '正在生成...');
      expect(empty.subText, '点按查看生成详情');

      final withSummary = OutlineNotificationContent.running(
        bookTitle: '测试书',
        progressText: '展开 (2/4)',
        progress: 50,
        lastStepSummary: ' 已完成 2/4 · 12s ',
      );
      expect(withSummary.content, '展开 (2/4)');
      expect(withSummary.subText, '最近完成：已完成 2/4 · 12s');
    });
  });

  group('通知文案 · 检查点暂停', () {
    test('标题/正文体现「暂停、等待确认」，并带上检查点中文名', () {
      final content = OutlineNotificationContent.paused(
        bookTitle: '测试书',
        checkpointLabel: '粗骨架',
        progress: 50,
      );

      expect(content.kind, OutlineNotificationKind.paused);
      expect(content.title, contains('暂停'));
      expect(content.title, contains('《测试书》'));
      expect(content.content, contains('粗骨架'));
      expect(content.content, contains('等待你确认'));
      expect(content.subText, contains('继续'));
      expect(content.progress, 50);
    });

    test('空书名 / 空检查点名有兜底文案，progress 同样 clamp', () {
      final content = OutlineNotificationContent.paused(
        bookTitle: '  ',
        checkpointLabel: '',
        progress: 130,
      );

      expect(content.title, '大纲生成已暂停 · 等待确认');
      expect(content.content, '生成内容已生成，等待你确认后继续');
      expect(content.progress, 100);

      expect(
        OutlineNotificationContent.paused(
          bookTitle: '',
          checkpointLabel: '大事件',
          progress: -1,
        ).progress,
        0,
      );
    });
  });

  group('通知文案 · 完成 / 中断', () {
    test('完成：标题含「完成」，正文含保存提示与字数，success 为 true', () {
      final content = OutlineNotificationContent.finished(
        bookTitle: '测试书',
        success: true,
        charCount: 1234,
      );

      expect(content.kind, OutlineNotificationKind.finished);
      expect(content.success, isTrue);
      expect(content.title, contains('完成'));
      expect(content.title, contains('《测试书》'));
      expect(content.content, contains('已保存到历史大纲'));
      expect(content.content, contains('1234'));
      expect(content.progress, 100);
    });

    test('完成：字数为 0 时不显示「0 字」；message 覆盖默认正文', () {
      final noCount = OutlineNotificationContent.finished(
        bookTitle: '测试书',
        success: true,
      );
      expect(noCount.content, '已保存到历史大纲');

      final withMessage = OutlineNotificationContent.finished(
        bookTitle: '测试书',
        success: true,
        message: '已保存并可以继续精修',
      );
      expect(withMessage.content, '已保存并可以继续精修');
    });

    test('中断：标题含「中断」，长 message 截断到 60 字加省略号', () {
      final longMessage = '网' * 100; // 100 字，超过 60 字上限
      final content = OutlineNotificationContent.finished(
        bookTitle: '测试书',
        success: false,
        message: longMessage,
        charCount: 999,
      );

      expect(content.kind, OutlineNotificationKind.finished);
      expect(content.success, isFalse);
      expect(content.title, contains('中断'));
      expect(content.content, '${longMessage.substring(0, 60)}…');
      expect(content.content.length, 61);
      expect(content.content, endsWith('…'));
      // 中断态不展示字数（只有成功分支才拼 charCount）
      expect(content.content, isNot(contains('999')));
      expect(content.progress, 100);
    });

    test('中断：短 message 原样展示；空书名/无 message 都有兜底文案', () {
      expect(
        OutlineNotificationContent.finished(
          bookTitle: '测试书',
          success: false,
          message: '网络错误',
        ).content,
        '网络错误',
      );

      final fallback = OutlineNotificationContent.finished(
        bookTitle: '',
        success: false,
      );
      expect(fallback.title, '大纲生成中断');
      expect(fallback.content, '生成中断，可回到页面继续上次进度');
      expect(fallback.success, isFalse);
    });
  });

  group('通知更新节流 / 去重', () {
    testWidgets('start 立即发出，不进入 400ms 节流窗口', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(_running('测试书', '启动中', 5));

      expect(recorder.methods, ['start']);
      expect(recorder.calls.single.$2!['title'], contains('测试书'));
      expect(recorder.calls.single.$2!['progress'], 5);
    });

    testWidgets('连续 update 在 400ms 内只发一次，且内容是最后那次', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(_running('测试书', '启动', 5));
      notification.update(_running('测试书', '第一步', 10));
      notification.update(_running('测试书', '第二步', 20));
      notification.update(_running('测试书', '第三步', 30));

      // 窗口内先攒着，不逐条发 IPC
      expect(recorder.methods, ['start']);

      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.methods, ['start'], reason: '400ms 窗口内不应发出 update');

      await tester.pump(const Duration(milliseconds: 400));
      expect(recorder.methods, ['start', 'update'], reason: '窗口结束后只补发一次');
      expect(
        recorder.calls.last.$2!['content'],
        '第三步',
        reason: '被合并的中间进度要丢掉，只发最新内容',
      );

      // 之后再没有第三次 update（否则说明定时器重复触发）
      await tester.pump(const Duration(seconds: 2));
      expect(recorder.methods.length, 2);
    });

    testWidgets('finish 立即发出，并丢弃尚未发出的 pending update', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(_running('测试书', '启动', 5));
      notification.update(_running('测试书', '待发进度', 40)); // 进了节流窗口
      await notification.finish(_finished('测试书'), success: true);

      expect(recorder.methods, ['start', 'finish']);
      expect(recorder.calls.last.$2!['success'], true);

      // 完成态是终态：之前攒的进度 update 不能再冒出来覆盖它
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.methods, ['start', 'finish']);
    });

    testWidgets('cancel 立即发出，并清掉 pending update', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(_running('测试书', '启动', 5));
      notification.update(_running('测试书', '待发进度', 40));
      await notification.cancel();

      expect(recorder.methods, ['start', 'cancel']);
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.methods, ['start', 'cancel']);
    });

    testWidgets('相同内容去重：同一份进度不会重复发 update', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      final same = _running('测试书', '同一进度', 50);
      await notification.start(same);
      // 与刚 start 的内容相同 → 完全不排队
      notification.update(same);
      await tester.pump(const Duration(milliseconds: 500));
      expect(recorder.methods, ['start']);

      // 内容变化才发一次；同一内容排队两次也只发一次
      final changed = _running('测试书', '新进度', 60);
      notification.update(changed);
      notification.update(changed);
      await tester.pump(const Duration(milliseconds: 500));
      expect(recorder.methods, ['start', 'update']);
      expect(recorder.calls.last.$2!['content'], '新进度');

      // 已经发出去的内容再次 update，仍然不重发
      notification.update(changed);
      await tester.pump(const Duration(milliseconds: 500));
      expect(recorder.methods, ['start', 'update']);
    });

    test('非 Android / 原生不可用时全部 no-op，不触碰通道', () async {
      final recorder = _InvokeRecorder();
      final notification = OutlineBackgroundNotification(
        supported: false,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(_running('测试书', '启动', 5));
      notification.update(_running('测试书', '进度', 50));
      await notification.finish(_finished('测试书'), success: true);
      await notification.cancel();

      expect(notification.supported, isFalse);
      expect(recorder.calls, isEmpty);
    });
  });

  group('控制器状态 → 通知同步', () {
    test('生成中 start（25%）→ 更新（75%）→ 检查点暂停 → 完成', () async {
      final fake = _FakeNotification();
      final controller = OutlineController(backgroundNotification: fake);
      addTearDown(controller.dispose);

      controller.debugSetRunStateForTest(
        loading: true,
        title: '测试书',
        currentStep: 0,
        totalSteps: 4,
      );
      await _flushMicrotasks();

      expect(fake.calls, ['start']);
      expect(fake.lastStart!.kind, OutlineNotificationKind.running);
      expect(fake.lastStart!.title, contains('测试书'));
      expect(fake.lastStart!.progress, 25, reason: '第 1/4 步 → 25%');
      expect(controller.debugBackgroundTaskActiveForTest, isTrue);

      controller.debugSetRunStateForTest(currentStep: 2);
      await _flushMicrotasks();

      expect(fake.calls, contains('update'));
      expect(fake.lastUpdate!.kind, OutlineNotificationKind.running);
      expect(fake.lastUpdate!.progress, 75, reason: '第 3/4 步 → 75%');

      controller.debugSetRunStateForTest(
        loading: false,
        paused: true,
        checkpointKind: 'skeleton',
      );
      await _flushMicrotasks();

      expect(fake.lastUpdate!.kind, OutlineNotificationKind.paused);
      expect(fake.lastUpdate!.content, contains('粗骨架'));

      controller.debugSetRunStateForTest(loading: false, paused: false);
      await _flushMicrotasks();

      expect(fake.calls.last, 'finish');
      expect(fake.lastFinish!.kind, OutlineNotificationKind.finished);
      expect(fake.lastSuccess, isTrue);
      expect(fake.lastFinish!.title, contains('完成'));
      expect(controller.debugBackgroundTaskActiveForTest, isFalse);
      expect(controller.debugBackgroundTaskNotifiedForTest, isTrue);
    });

    test('错误中断：finish 用 success=false，正文带错误信息', () async {
      final fake = _FakeNotification();
      final controller = OutlineController(backgroundNotification: fake);
      addTearDown(controller.dispose);

      controller.debugSetRunStateForTest(
        loading: true,
        title: '测试书',
        totalSteps: 4,
      );
      await _flushMicrotasks();

      controller.debugSetRunStateForTest(
        loading: false,
        paused: false,
        error: '网络错误',
      );
      await _flushMicrotasks();

      expect(fake.calls.last, 'finish');
      expect(fake.lastSuccess, isFalse);
      expect(fake.lastFinish!.kind, OutlineNotificationKind.finished);
      expect(fake.lastFinish!.title, contains('中断'));
      expect(fake.lastFinish!.content, contains('网络错误'));
    });

    test('用户主动取消：通知走 cancel，而不是 finish', () async {
      final fake = _FakeNotification();
      final controller = OutlineController(backgroundNotification: fake);
      addTearDown(controller.dispose);

      controller.debugSetRunStateForTest(
        loading: true,
        title: '测试书',
        totalSteps: 4,
      );
      await _flushMicrotasks();
      expect(fake.calls, ['start']);

      await controller.cancel();
      await _flushMicrotasks();

      expect(fake.calls, ['start', 'cancel']);
      expect(fake.calls, isNot(contains('finish')));
      expect(controller.debugBackgroundTaskActiveForTest, isFalse);
    });
  });
}

/// 记录「发往原生」的方法名与参数，替代真实 MethodChannel。
class _InvokeRecorder {
  final List<(String, Map<String, dynamic>?)> calls = [];

  Future<Object?> handle(String method, Map<String, dynamic>? args) async {
    calls.add((method, args));
    return null;
  }

  List<String> get methods => [for (final call in calls) call.$1];
}

/// 假通知器：只记录控制器发来的通知调用，不做任何平台交互。
///
/// `supported: false` 让它自身的基类逻辑保持 no-op；所有会触发原生调用的方法
/// 都被重写为纯记录，因此单测里不会碰 MethodChannel。
class _FakeNotification extends OutlineBackgroundNotification {
  _FakeNotification() : super(supported: false);

  final List<String> calls = [];
  OutlineNotificationContent? lastStart;
  OutlineNotificationContent? lastUpdate;
  OutlineNotificationContent? lastFinish;
  bool? lastSuccess;

  @override
  Future<bool> ensurePermission() async => false;

  @override
  Future<void> start(OutlineNotificationContent c) async {
    calls.add('start');
    lastStart = c;
  }

  @override
  void update(OutlineNotificationContent c) {
    calls.add('update');
    lastUpdate = c;
  }

  @override
  Future<void> finish(
    OutlineNotificationContent c, {
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

/// 等待控制器里 `unawaited` 的通知调用（fake 的 async 方法）执行完。
Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

OutlineNotificationContent _running(
  String bookTitle,
  String progressText,
  int progress,
) => OutlineNotificationContent.running(
  bookTitle: bookTitle,
  progressText: progressText,
  progress: progress,
);

OutlineNotificationContent _finished(String bookTitle) =>
    OutlineNotificationContent.finished(
      bookTitle: bookTitle,
      success: true,
      charCount: 1200,
    );
