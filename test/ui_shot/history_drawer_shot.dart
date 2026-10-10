import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/history_controller.dart';
import 'package:deepseekapp/features/chat/domain/chat_session.dart';
import 'package:deepseekapp/features/chat/presentation/history_page.dart';

/// 「历史会话」抽屉的**截图工具**：文件名不以 `_test` 结尾，`flutter test`
/// 不会自动跑它。改动抽屉样式后用它生成 PNG 肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/history_drawer_shot.dart
///
/// 输出在 test/ui_shot/shots/：1 空列表、2 有历史会话（抽屉宽度都应是屏幕的 80%）、
/// 3 三个字号都放大到 12 的对比图。
/// 屏幕逻辑宽度（物理像素 / 缩放 = 390，配 844 的逻辑高度）
const logicalScreenWidth = 390.0;

void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 自带图标字体
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    if (flutterRoot.isNotEmpty) {
      await _loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf',
      );
    }
  });

  testWidgets('历史会话抽屉截图（空列表）', (tester) async {
    await _pumpDrawerScene(tester, sessions: const []);
    await _openDrawerAndShoot(tester, 'shots/1_history_drawer_empty.png');
  });

  testWidgets('历史会话抽屉截图（有会话）', (tester) async {
    await _pumpDrawerScene(
      tester,
      sessions: [
        ChatSession(
          id: 3,
          title: 'Flutter 抽屉菜单怎么改成 80% 宽？',
          createTime: '2026-02-18T09:24:00',
          lastMessage: '把 Drawer 的 width 设成屏幕宽度的 0.8 就行，记得处理安全区。',
        ),
        ChatSession(
          id: 2,
          title: '写小说：第一章 世界观设定',
          createTime: '2026-02-17T21:03:00',
          lastMessage: '主角在一座会呼吸的城市里醒来……',
        ),
        ChatSession(
          id: 1,
          title: '新对话',
          createTime: '2026-02-16T08:11:00',
          lastMessage: '',
        ),
      ],
    );
    await _openDrawerAndShoot(tester, 'shots/2_history_drawer_sessions.png');
  });

  testWidgets('历史会话抽屉截图（会话标题字号对比）', (tester) async {
    await _pumpDrawerScene(
      tester,
      sessions: [
        ChatSession(
          id: 2,
          title: '写小说：第一章 世界观设定',
          createTime: '2026-02-17T21:03:00',
          lastMessage: '主角在一座会呼吸的城市里醒来……',
        ),
      ],
      // 对比用：三处都放大到 12，看「整块字都偏大」是什么观感
      sessionTitleFontSize: 12,
      sessionPreviewFontSize: 12,
      sessionTimeFontSize: 12,
    );
    await _openDrawerAndShoot(tester, 'shots/3_history_drawer_all12.png');
  });
}

/// 挂载一个「聊天页 + 历史会话抽屉」的场景，历史会话数据由 [sessions] 提供
Future<void> _pumpDrawerScene(
  WidgetTester tester, {
  required List<ChatSession> sessions,
  double sessionTitleFontSize = HistoryDrawer.defaultSessionTitleFontSize,
  double sessionPreviewFontSize = HistoryDrawer.defaultSessionPreviewFontSize,
  double sessionTimeFontSize = HistoryDrawer.defaultSessionTimeFontSize,
}) async {
  tester.view.physicalSize = const Size(
    logicalScreenWidth * 3,
    844 * 3,
  );
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final scaffoldKey = GlobalKey<ScaffoldState>();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        historyProvider.overrideWith((ref) => _FakeHistoryController(sessions)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4D6BFE),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'SimHei',
        ),
        home: Scaffold(
          key: scaffoldKey,
          backgroundColor: Colors.white,
          drawer: HistoryDrawer(
            sessionTitleFontSize: sessionTitleFontSize,
            sessionPreviewFontSize: sessionPreviewFontSize,
            sessionTimeFontSize: sessionTimeFontSize,
          ),
          body: const Center(
            child: Text(
              '聊天页面',
              style: TextStyle(fontSize: 16, color: Color(0xFF333333)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  scaffoldKey.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

/// 校验抽屉宽度正好是屏幕宽度的 80%，然后截图
Future<void> _openDrawerAndShoot(WidgetTester tester, String golden) async {
  final drawerWidth = tester.getSize(find.byType(HistoryDrawer)).width;
  expect(
    drawerWidth,
    closeTo(logicalScreenWidth * HistoryDrawer.widthFactor, 0.5),
  );

  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile(golden),
  );
}

/// 假的历史会话控制器：直接给出内存数据，避免截图工具去碰数据库
class _FakeHistoryController extends HistoryController {
  _FakeHistoryController(this._fakeSessions);

  final List<ChatSession> _fakeSessions;

  @override
  List<ChatSession> get sessions => _fakeSessions;

  @override
  bool get isLoaded => true;

  @override
  Future<void> loadSessions() async {}
}

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}
