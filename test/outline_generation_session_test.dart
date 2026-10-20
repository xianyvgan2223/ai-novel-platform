import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/background/outline_background_notification.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/background/outline_generation_session.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';

/// 进程级生成会话（[OutlineGenerationSession]）的生命周期测试。
///
/// 后台生成的核心承诺是「页面关了，生成继续」：
/// - 生成中 / 检查点等待中 detach → 保留 controller、不能被 dispose；
/// - 空闲（完成 / 取消 / 失败）detach → dispose 并清空，避免常驻内存；
/// - 重新进入页面 acquire → 拿回同一实例（进度、检查点编辑都不丢）；
/// - `preferExisting: false`（历史大纲重新生成）只在旧会话空闲时新建，
///   旧会话还在生成中则必须复用，防止并发出两份生成。
///
/// 这里用 `debugControllerFactory` 注入带假通知器的 controller，
/// 只摆状态、不发起网络请求，也不触碰 Android MethodChannel。
void main() {
  final session = OutlineGenerationSession.instance;

  // 单例是进程级的，测试之间必须清干净，否则会串状态。
  setUp(session.resetForTest);
  tearDown(session.resetForTest);

  test('首次 acquire 新建会话；再次 acquire 复用同一 controller', () {
    final first = session.acquireForPage(
      debugControllerFactory: _newController,
    );

    expect(first.attachedExisting, isFalse);
    expect(session.current, same(first.controller));

    // 空闲时再次 acquire：优先复用已有会话（进度条/输入内容都还在）
    final second = session.acquireForPage();

    expect(second.attachedExisting, isTrue);
    expect(second.controller, same(first.controller));
  });

  test('生成中 detach：会话保留 controller 且不被 dispose，生成可继续', () async {
    final fake = _FakeNotification();
    final attach = session.acquireForPage(
      debugControllerFactory: () => _newController(fake),
    );
    final controller = attach.controller;
    controller.debugSetRunStateForTest(
      loading: true,
      title: '测试书',
      totalSteps: 4,
    );
    await _flushMicrotasks();

    expect(controller.isRunning, isTrue);
    expect(controller.debugBackgroundTaskActiveForTest, isTrue);
    expect(fake.calls, contains('start'));

    session.detachFromPage(controller);

    // 关键：会话没有被清空，controller 也没有被 dispose
    expect(session.current, same(controller));
    expect(session.isBusy, isTrue);
    expect(controller.debugBackgroundTaskActiveForTest, isTrue);

    // controller 仍然可用：还能收监听、还能更新状态（后台生成继续在跑）
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.debugSetRunStateForTest(currentStep: 1);
    expect(notifications, 1);
  });

  test('空闲时 detach：dispose 并清空会话', () {
    final attach = session.acquireForPage(
      debugControllerFactory: _newController,
    );
    final controller = attach.controller;
    // 新建的 controller 默认就是空闲态（loading=false、paused=false）
    expect(controller.isRunning, isFalse);

    session.detachFromPage(controller);

    expect(session.current, isNull);
    expect(session.isBusy, isFalse);
    // dispose 之后的 ChangeNotifier 再被使用时能观察到「已销毁」
    expect(() => controller.addListener(() {}), throwsA(isA<FlutterError>()));
  });

  test('检查点暂停时 detach：会话保留，等待用户确认后继续', () async {
    final fake = _FakeNotification();
    final attach = session.acquireForPage(
      debugControllerFactory: () => _newController(fake),
    );
    final controller = attach.controller;
    controller.debugSetRunStateForTest(
      loading: false,
      paused: true,
      title: '测试书',
      currentStep: 1,
      totalSteps: 4,
      checkpointKind: 'skeleton',
    );
    await _flushMicrotasks();

    expect(controller.isRunning, isTrue, reason: '暂停态也属于「生成活动中」');
    expect(fake.lastStart!.kind, OutlineNotificationKind.paused);
    expect(fake.lastStart!.content, contains('粗骨架'));

    session.detachFromPage(controller);

    // 暂停态用户会点通知回来，会话必须保留（不能把草稿/检查点丢了）
    expect(session.current, same(controller));
    expect(session.isBusy, isTrue);
  });

  test('preferExisting:false 且旧会话空闲：销毁旧 controller，新建不同实例', () {
    final oldController = session
        .acquireForPage(debugControllerFactory: _newController)
        .controller;

    final fresh = session.acquireForPage(
      preferExisting: false,
      debugControllerFactory: _newController,
    );

    expect(fresh.attachedExisting, isFalse);
    expect(fresh.controller, isNot(same(oldController)));
    expect(session.current, same(fresh.controller));
    // 旧实例已被 dispose，不能再挂监听
    expect(
      () => oldController.addListener(() {}),
      throwsA(isA<FlutterError>()),
    );
  });

  test('preferExisting:false 但旧会话生成中：仍复用旧 controller，避免并发两份生成', () {
    final oldController = session
        .acquireForPage(debugControllerFactory: _newController)
        .controller;
    oldController.debugSetRunStateForTest(
      loading: true,
      title: '测试书',
      totalSteps: 4,
    );

    final attached = session.acquireForPage(preferExisting: false);

    expect(attached.attachedExisting, isTrue);
    expect(attached.controller, same(oldController));
  });
}

/// 带假通知器的新 controller：不触发 MethodChannel / 网络请求。
OutlineController _newController([_FakeNotification? notification]) =>
    OutlineController(
      backgroundNotification: notification ?? _FakeNotification(),
    );

/// 假通知器：只记录控制器发来的通知调用，不做任何平台交互。
class _FakeNotification extends OutlineBackgroundNotification {
  _FakeNotification() : super(supported: false);

  final List<String> calls = [];
  OutlineNotificationContent? lastStart;

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
  }

  @override
  Future<void> finish(
    OutlineNotificationContent c, {
    required bool success,
  }) async {
    calls.add('finish');
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
  }
}

/// 等待控制器里 `unawaited` 的通知调用（fake 的 async 方法）执行完。
Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);
