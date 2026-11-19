import 'package:deepseekapp/features/chat/application/chat_controller.dart';
import 'package:deepseekapp/features/chat/application/setting_controller.dart';
import 'package:deepseekapp/features/chat/domain/chat_message.dart';
import 'package:deepseekapp/features/chat/domain/chat_session.dart';
import 'package:deepseekapp/features/chat/presentation/chat_page.dart';
import 'package:deepseekapp/features/chat/presentation/widgets/search_sources_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天页的两个交互：
///   1. 停在底部时，流式回答变长会继续跟随到底部；用户上翻后不再抢滚动。
///   2. 设置页关掉「显示缓存命中」后，输入框上方的缓存数字消失。
void main() {
  testWidgets('停在底部时流式生成自动跟随，上翻后不抢滚动', (tester) async {
    final env = await _pumpChat(tester);
    final list = tester.widget<ListView>(find.byType(ListView));
    final ctrl = list.controller!;

    // 初始定位到底部
    expect(ctrl.position.pixels, closeTo(ctrl.position.maxScrollExtent, 1));

    // 用户翻到顶部：开始生成也不应该被拽回底部
    ctrl.jumpTo(0);
    await tester.pump();
    env.chat.emit(loading: true, streamingText: _longText(60));
    await tester.pump();
    await tester.pump();
    expect(ctrl.position.pixels, closeTo(0, 1));

    // 用户自己回到底部：之后每个分片都跟着向下
    ctrl.jumpTo(ctrl.position.maxScrollExtent);
    await tester.pump();
    env.chat.emit(streamingText: _longText(140));
    await tester.pump();
    await tester.pump();
    expect(ctrl.position.pixels, closeTo(ctrl.position.maxScrollExtent, 1));
  });

  testWidgets('搜索过程中不显示来源气泡，回答结束后才显示', (tester) async {
    final env = await _pumpChat(tester);
    final results = <Map<String, dynamic>>[
      {'name': '官方文档', 'url': 'https://example.com/doc', 'snippet': '示例摘要'},
    ];

    // 搜索进行中：流式气泡只显示正文 / 加载状态，不提前弹来源卡片
    env.chat.emit(
      loading: true,
      streamingText: '正在搜索…',
      searchResults: results,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(SearchSourcesCard), findsNothing);

    // 回答结束、落库成正式消息：来源入口跟着最终消息一起出现
    env.chat.finishWithSearch(results);
    await tester.pumpAndSettle();
    expect(find.byType(SearchSourcesCard), findsOneWidget);

    // 入口是一枚小胶囊，点开才弹出中性色的来源列表
    await tester.tap(find.text('参考 1 篇资料'));
    await tester.pumpAndSettle();
    expect(find.text('参考来源'), findsOneWidget);
    expect(find.text('官方文档'), findsOneWidget);
  });

  testWidgets('关闭「显示缓存命中」后不再显示缓存数字', (tester) async {
    final env = await _pumpChat(tester);
    final contextPill = find.byKey(const ValueKey('chat_usage_context'));
    final cachePill = find.byKey(const ValueKey('chat_usage_cache'));
    expect(contextPill, findsOneWidget);
    expect(
      find.descendant(of: contextPill, matching: find.text('10%')),
      findsOneWidget,
    );
    expect(cachePill, findsOneWidget);
    expect(
      find.descendant(of: cachePill, matching: find.text('75%')),
      findsOneWidget,
    );

    env.setting.setShowCacheHit(false);
    await tester.pumpAndSettle();

    expect(cachePill, findsNothing);
    // 上下文占用与 token 统计不受该开关影响
    expect(contextPill, findsOneWidget);
    expect(
      find.descendant(of: contextPill, matching: find.text('10%')),
      findsOneWidget,
    );
  });

  testWidgets('上下文 / 缓存条可收起，右端按钮再展开', (tester) async {
    await _pumpChat(tester);
    final toggle = find.byKey(const ValueKey('chat_usage_toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byKey(const ValueKey('chat_usage_context')), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_usage_context')), findsNothing);
    expect(find.byKey(const ValueKey('chat_usage_cache')), findsNothing);
    expect(toggle, findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_usage_context')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_usage_cache')), findsOneWidget);
  });

  testWidgets('在最底上滑会立即解锁，流式继续增长不再拉回底部', (tester) async {
    final env = await _pumpChat(tester);
    final list = tester.widget<ListView>(find.byType(ListView));
    final ctrl = list.controller!;

    env.chat.emit(streamingText: _longText(80));
    await tester.pump();
    await tester.pump();
    expect(ctrl.position.pixels, closeTo(ctrl.position.maxScrollExtent, 1));

    // 只上滑 40px（仍在旧的 80px「贴底区」内），旧逻辑下一帧会被拉回去。
    await tester.drag(find.byType(ListView), const Offset(0, 40));
    await tester.pumpAndSettle();
    final before = ctrl.position.pixels;
    final maxBefore = ctrl.position.maxScrollExtent;
    expect(maxBefore - before, greaterThan(1));

    env.chat.emit(streamingText: _longText(160));
    await tester.pump();
    await tester.pump();
    expect(ctrl.position.pixels, closeTo(before, 1));
    expect(ctrl.position.maxScrollExtent, greaterThan(maxBefore));
  });
}

String _longText(int lines) =>
    List<String>.generate(lines, (i) => '第 $i 行流式回答内容').join('\n');

Future<({_FakeChatController chat, _FakeSettingController setting})> _pumpChat(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final chat = _FakeChatController(
    List<ChatMessage>.generate(
      20,
      (i) => ChatMessage(
        role: i.isEven ? MessageRole.user : MessageRole.assistant,
        content: '第 $i 条消息 ${'内容' * 40}',
        timestamp: '2026-11-17T12:00:00',
      ),
    ),
  );
  final setting = _FakeSettingController();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatProvider.overrideWith((ref) => chat),
        settingProvider.overrideWith((ref) => setting),
      ],
      child: const MaterialApp(home: ChatPage()),
    ),
  );
  await tester.pumpAndSettle();
  return (chat: chat, setting: setting);
}

class _FakeChatController extends ChatController {
  _FakeChatController(this._messages);

  final List<ChatMessage> _messages;
  bool _loading = false;
  String _streaming = '';
  List<Map<String, dynamic>>? _searchResults;

  @override
  List<Map<String, dynamic>>? get streamingSearchResults => _searchResults;

  static const ChatSession _session = ChatSession(
    title: '测试会话',
    createTime: '2026-11-17T12:00:00',
  );

  @override
  List<ChatMessage> get messages => _messages;

  @override
  bool get isLoading => _loading;

  @override
  String get streamingText => _streaming;

  @override
  bool get isStreamingEmpty => _streaming.isEmpty;

  @override
  ChatSession? get currentSession => _session;

  @override
  int get displayContextTokens => 100;

  @override
  int get contextWindow => 1000;

  @override
  int? get cachePercent => 75;

  /// 模拟一次流式分片 / loading 状态变化（真实控制器里由 API 回调触发）
  void emit({
    bool? loading,
    String? streamingText,
    List<Map<String, dynamic>>? searchResults,
  }) {
    if (loading != null) _loading = loading;
    if (streamingText != null) _streaming = streamingText;
    if (searchResults != null) _searchResults = searchResults;
    notifyListeners();
  }

  /// 模拟回答结束：流式状态清空，带搜索来源的正式助手消息落库
  void finishWithSearch(List<Map<String, dynamic>> searchResults) {
    _messages.add(
      ChatMessage(
        role: MessageRole.assistant,
        content: '搜索完成后的最终回答',
        timestamp: '2026-11-17T12:00:01',
        searchResults: searchResults,
      ),
    );
    _loading = false;
    _streaming = '';
    _searchResults = null;
    notifyListeners();
  }
}

class _FakeSettingController extends SettingController {
  bool _showCacheHit = true;

  @override
  bool get isLoaded => true;

  @override
  Future<void> loadSettings() async {}

  @override
  bool get showCacheHit => _showCacheHit;

  @override
  void setShowCacheHit(bool v) {
    _showCacheHit = v;
    notifyListeners();
  }
}
