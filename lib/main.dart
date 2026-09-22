/// lib/main.dart
/// 应用入口 — 挂载 Riverpod ProviderScope，启动主对话页面

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/chat/presentation/chat_page.dart';
import 'features/chat/presentation/widgets/chat_floating_ball.dart';
import 'features/sync/application/sync_poller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 请求设备最高刷新率（如 120Hz），降低帧延迟
  await FlutterDisplayMode.setHighRefreshRate();
  // 前台轮询：电脑（网页）点「同步手机」后自动执行，不用碰手机
  SyncPoller.instance.start();
  runApp(const ProviderScope(child: MyApp()));
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
