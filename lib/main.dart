/// lib/main.dart
/// 应用入口 — 挂载 Riverpod ProviderScope，启动主对话页面

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/config/app_preferences.dart';
import 'core/config/app_version.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_controller.dart';
import 'features/chat/presentation/chat_page.dart';
import 'features/chat/presentation/widgets/chat_floating_ball.dart';
import 'features/novel_writing/outline_generation/background/outline_background_notification.dart';
import 'features/novel_writing/outline_generation/view/page/outline_generation_page.dart';
import 'features/novel_writing/outline_listening/background/outline_listen_session.dart';
import 'features/novel_writing/outline_listening/background/outline_listening_notification.dart';
import 'features/novel_writing/outline_listening/view/page/outline_listen_page.dart';
import 'features/sync/application/sync_poller.dart';
import 'features/update/data/app_update_service.dart';
import 'features/update/data/update_announcement.dart';
import 'features/update/presentation/update_announcement_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installDiagnostics();
  // 请求设备最高刷新率（如 120Hz），降低帧延迟
  await FlutterDisplayMode.setHighRefreshRate();
  // 前台轮询：电脑（网页）点「同步手机」后自动执行，不用碰手机
  SyncPoller.instance.start();
  // 先读一次本机主题偏好再启动，避免首帧亮色闪一下再切到深色
  String? themeRaw;
  try {
    themeRaw = await AppPreferences.get(AppPreferences.themeModeKey);
  } catch (_) {
    themeRaw = null;
  }
  runApp(
    ProviderScope(
      overrides: <Override>[
        themeModeProvider.overrideWith(
          (ref) => ThemeModeController(initialRaw: themeRaw),
        ),
      ],
      child: const MyApp(),
    ),
  );
  // 首帧后再清理：只删已经装上的旧更新包，避免安装器还在读文件时误删。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(AppUpdateService().cleanupInstalledUpdates());
  });
}

/// 掉帧排查开关（默认全关，release 直接跳过，不影响正常运行）。
///
/// 用来定位「键盘弹出 / 切页时掉帧」这类**逐帧开销**，两个开关各管一半：
///
/// ```powershell
/// # ① 哪些帧超支了、超在 UI 线程还是光栅线程（建议配 --profile）
/// flutter run --profile --dart-define=FRAME_LOG=true
///
/// # ② 每帧都在重建的 widget 叫什么（只能在 debug 下用）
/// flutter run --dart-define=REBUILD_LOG=true
/// ```
///
/// 判读方式：120Hz 的帧预算是 8.33ms（60Hz 是 16.6ms）。
/// `build` 大 = UI 线程忙（build / layout）；`raster` 大 = 绘制合成忙。
/// 两者都不大却仍然肉眼掉帧，那就不是 Flutter 线程的问题（多半是刷新率或输入法）。
void _installDiagnostics() {
  if (kReleaseMode) return;

  if (const bool.fromEnvironment('FRAME_LOG')) {
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final timing in timings) {
        final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
        final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
        if (buildMs > 8.33 || rasterMs > 8.33) {
          debugPrint(
            '[SLOW] build=${buildMs.toStringAsFixed(1)}ms '
            'raster=${rasterMs.toStringAsFixed(1)}ms',
          );
        }
      }
    });
  }

  if (const bool.fromEnvironment('REBUILD_LOG')) {
    // 只对 debug 构建有效：控制台里反复刷屏的那几个名字就是元凶
    debugPrintRebuildDirtyWidgets = true;
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final FloatingChatRouteObserver _routeObserver = FloatingChatRouteObserver();

  /// 「大纲生成进度」通知点击的订阅（App 生命周期内常驻）。
  StreamSubscription<void>? _outlineTapSubscription;

  /// 防止冷启动 pending 标记 + 点击事件同时到达时 push 出两个生成页。
  bool _openingOutlinePage = false;

  /// 「听大纲」后台朗读通知的点击 / 操作按钮 / 媒体 seekbar 拖动订阅。
  StreamSubscription<void>? _listenTapSubscription;
  StreamSubscription<String>? _listenActionSubscription;
  StreamSubscription<double>? _listenSeekSubscription;

  /// 防止重复 push 朗读页（点通知与冷启动 pending 可能同时到达）。
  bool _openingListenPage = false;

  @override
  void initState() {
    super.initState();
    _installOutlineNotificationHandler();
    _installListenNotificationHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowUpdateAnnouncement();
    });
  }

  /// 首次打开某个新版本时显示一次更新公告；同一 releaseId 不再重复。
  Future<void> _maybeShowUpdateAnnouncement() async {
    try {
      final seen = await AppPreferences.get(
        AppPreferences.updateAnnouncementKey,
      );
      if (seen == kAppReleaseId) return;
      if (currentUpdateAnnouncement.releaseId != kAppReleaseId) {
        await AppPreferences.set(
          AppPreferences.updateAnnouncementKey,
          kAppReleaseId,
        );
        return;
      }
      // 先标记已读，避免 App 在公告打开期间被杀后反复弹出。
      await AppPreferences.set(
        AppPreferences.updateAnnouncementKey,
        kAppReleaseId,
      );
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final context = _navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      await showUpdateAnnouncementDialog(context, currentUpdateAnnouncement);
    } catch (e) {
      debugPrint('[update] 更新公告显示失败：$e');
    }
  }

  /// 通知栏「大纲生成进度」点击 → 回到「一键生成大纲」页面查看当前生成详情。
  ///
  /// 两条路径都要处理：
  /// - App 还活着：原生通过 EventChannel 实时发 tap 事件；
  /// - App 被杀后点通知冷启动：原生保留 pending 标记，由 [consumeLaunchTap] 取走。
  /// 生成状态本身在进程级会话里（OutlineGenerationPage 打开时自动挂回），
  /// 所以这里只负责导航，不传递任何生成数据。
  Future<void> _installOutlineNotificationHandler() async {
    _outlineTapSubscription = OutlineBackgroundNotification.instance.onTap.listen(
      (_) => _openOutlineGenerationPage(),
    );
    final launchedByTap = await OutlineBackgroundNotification.instance
        .consumeLaunchTap();
    if (launchedByTap) _openOutlineGenerationPage();
  }

  void _openOutlineGenerationPage() {
    if (_openingOutlinePage) return;
    // 生成页已经在前台：不重复 push（原生通知已在点击时 autoCancel 掉）
    if (OutlineGenerationPage.openInstanceCount > 0) return;
    _openingOutlinePage = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void push() {
        if (!mounted) {
          _openingOutlinePage = false;
          return;
        }
        final navigator = _navigatorKey.currentState;
        if (navigator == null) {
          // 首帧还没建好导航栈：下一帧再试
          WidgetsBinding.instance.addPostFrameCallback((_) => push());
          return;
        }
        navigator.push(
          MaterialPageRoute(
            builder: (_) => const OutlineGenerationPage(fromNotification: true),
          ),
        );
        _openingOutlinePage = false;
      }

      push();
    });
  }

  /// 通知栏「听大纲」的点击与操作按钮。
  ///
  /// 与大纲生成的差异：朗读通知上带「上一个 / 暂停继续 / 停止」三个操作，
  /// 这些动作不需要打开页面，直接转给后台会话里的 controller；点击通知主体
  /// 才导航回朗读页（页面会挂回同一个 controller，当前句/高亮/进度都还在）。
  Future<void> _installListenNotificationHandler() async {
    final notification = OutlineListeningNotification.instance;
    _listenTapSubscription = notification.onTap.listen(
      (_) => _openOutlineListenPage(),
    );
    _listenActionSubscription = notification.onAction.listen(
      (action) => OutlineListenSession.instance.handleNotificationAction(action),
    );
    // 媒体样式通知的系统 seekbar 被拖动后：按当前事件内相对进度跳到对应句子。
    // 这个动作不需要打开页面，直接转给后台会话里的 controller，手机在兜里也能调。
    _listenSeekSubscription = notification.onSeek.listen(
      (fraction) => OutlineListenSession.instance.seekToFraction(fraction),
    );
    final launchedByTap = await notification.consumeLaunchTap();
    if (launchedByTap) _openOutlineListenPage();
  }

  /// 点「听大纲」通知 → 回到正在朗读的那条大纲（会话里有记录才可能导航）。
  void _openOutlineListenPage() {
    if (_openingListenPage) return;
    // 朗读页已经在前台：只把 App 拉到前面，不重复 push
    if (OutlineListenPage.openInstanceCount > 0) return;
    final record = OutlineListenSession.instance.activeRecord;
    if (record == null) return; // 没有会话（例如进程被杀后）：通知不该存在
    _openingListenPage = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void push() {
        if (!mounted) {
          _openingListenPage = false;
          return;
        }
        final navigator = _navigatorKey.currentState;
        if (navigator == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => push());
          return;
        }
        navigator.push(
          MaterialPageRoute(
            builder: (_) => OutlineListenPage(
              outline: record,
              fromNotification: true,
            ),
          ),
        );
        _openingListenPage = false;
      }

      push();
    });
  }

  @override
  void dispose() {
    _outlineTapSubscription?.cancel();
    _listenTapSubscription?.cancel();
    _listenActionSubscription?.cancel();
    _listenSeekSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider).mode;
    return MaterialApp(
      title: 'DeepSeek',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: [_routeObserver],
      // 让后台轮询也能弹提示（电脑请求的同步完成/失败）
      scaffoldMessengerKey: SyncPoller.instance.messengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      themeAnimationDuration: const Duration(milliseconds: 240),
      themeAnimationCurve: Curves.easeOutCubic,
      home: const ChatPage(),
      // 全局挂载悬浮聊天球：离开主聊天页后显示，点击可展开迷你聊天面板
      builder: (context, child) => ChatFloatingBallHost(
        navigatorKey: _navigatorKey,
        observer: _routeObserver,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
