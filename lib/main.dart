/// lib/main.dart
/// 应用入口 — 挂载 Riverpod ProviderScope，启动主对话页面

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/chat/presentation/chat_page.dart';
import 'features/chat/presentation/widgets/chat_floating_ball.dart';
import 'features/sync/application/sync_poller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installDiagnostics();
  // 请求设备最高刷新率（如 120Hz），降低帧延迟
  await FlutterDisplayMode.setHighRefreshRate();
  // 前台轮询：电脑（网页）点「同步手机」后自动执行，不用碰手机
  SyncPoller.instance.start();
  runApp(const ProviderScope(child: MyApp()));
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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final FloatingChatRouteObserver _routeObserver = FloatingChatRouteObserver();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepSeek',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: [_routeObserver],
      // 让后台轮询也能弹提示（电脑请求的同步完成/失败）
      scaffoldMessengerKey: SyncPoller.instance.messengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D6BFE),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
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
