/// lib/main.dart
/// 应用入口 — 挂载 Riverpod ProviderScope，启动主对话页面

import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'views/chat_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 请求设备最高刷新率（如 120Hz），降低帧延迟
  await FlutterDisplayMode.setHighRefreshRate();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepSeek',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4D6BFE),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}
