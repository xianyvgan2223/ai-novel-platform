// lib/views/chat_page.dart
// 主对话页面 — 对话消息区域 + 输入框 + 流式实时渲染

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../core/config/route_names.dart';
import '../application/chat_controller.dart';
import '../application/chat_context_budget.dart';
import '../application/setting_controller.dart';
import '../domain/chat_message.dart';
import 'history_page.dart';
import 'settings_page.dart';
import 'session_setting_page.dart';
import 'markdown_cleaner.dart';
import '../../novel_writing/novel_writing_page.dart';
import 'widgets/message_bubble.dart';
import 'widgets/chat_markdown.dart';
import '../../game/game_hub_page.dart';

/// ChatController Riverpod Provider 定义见 chat_controller.dart（全局单例）

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  /// 用于打开/关闭历史会话抽屉
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 编辑模式状态
  bool _isEditMode = false;
  final Set<int> _selectedIndices = {};

  /// 用户是否在聊天底部附近（防自动滚动干扰手动翻阅）
  bool _isNearBottom = true;

  /// 是否允许自动贴底跟随。
  ///
  /// 与 `_isNearBottom` 分开：用户一按下并开始拖动就立即关闭；只有真正
  /// 回到最底部（距离 ≤1px）才重新打开。否则底部附近 80px 的「贴底区」
  /// 会让上滑的前 80px 一直被下一帧拉回底部，表现为「滑不动」。
  bool _followEnabled = true;

  /// 输入框上方的上下文 / 缓存条是否收起（收起后只在右端留一个展开按钮）
  bool _usageBarCollapsed = false;

  /// 自动跟随是否已排队：流式分片每秒可达几十次，同一帧只允许排一次帧回调。
  bool _followScheduled = false;

  /// 路由转场是否已停下（由动画状态监听维护，见 [didChangeDependencies]）。
  bool _routeIdle = true;

  /// 本页所在路由；转场动画的状态变化会更新 [_routeIdle]。
  ModalRoute<dynamic>? _route;

  /// 已滚到底部的会话 id（抽屉切换会话/新建会话后需要重新定位到底部）
  int? _scrolledSessionId;

  /// 当前聊天控制器（在 initState 里取一次）。
  ///
  /// 不在 dispose 里用 `ref.read`：Riverpod 会在 State 卸载时先让 ref 失效，
  /// 那里再读会抛「Cannot use "ref" after the widget was disposed」。监听器
  /// 必须用同一个控制器实例移除，所以保存成字段。
  late final ChatController _chat;

  @override
  void initState() {
    super.initState();
    _chat = ref.read(chatProvider);
    _scrollCtrl.addListener(_onScrollChanged);
    // 监听会话切换：抽屉里选中历史会话后自动定位到最新消息
    _chat.addListener(_onChatChanged);
    // 监听流式分片：停在底部时跟着生成内容继续向下
    _chat.addListener(_onChatUpdated);
    // 预热全局设置（幂等、异步）：设置页推入时首帧就有内容，
    // 不会出现「转圈 → 整页表单」在转场动画中途切换的掉帧。
    ref.read(settingProvider).loadSettings();
    // 进入页面时定位到底部（如从悬浮面板“展开”进入时展示最新消息）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  /// 会话被切换（抽屉里选会话 / 新建对话）时，等消息渲染完成后滚到底部
  void _onChatChanged() {
    final sessionId = _chat.currentSession?.id;
    if (sessionId == _scrolledSessionId) return;
    _scrolledSessionId = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  void _onScrollChanged() {
    if (_scrollCtrl.hasClients) {
      final maxScroll = _scrollCtrl.position.maxScrollExtent;
      final remaining = maxScroll - _scrollCtrl.position.pixels;
      _isNearBottom = remaining < 80;
      // 只有真正回到最底部才恢复跟随；上滑后停在 80px 内也不再拉回去。
      _followEnabled = remaining <= 1;
    }
  }

  /// 用户手指拖动时立即暂停贴底；方向放开后由 [_onScrollChanged] 按位置恢复。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _followEnabled = false;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        (notification.scrollDelta ?? 0) < 0) {
      _followEnabled = false;
    }
    return false;
  }

  /// 流式生成时贴底跟随。
  ///
  /// 以前是在 `_buildMessageList`（build 期间）直接 jumpTo。但 ChatPage 只在
  /// `messages` / `isStreamingEmpty` 变化时重建，流式分片只重建内部的气泡，
  /// 主页面不会重新 build —— 于是只在回答刚开始时跳一次，回答越长底部跑得
  /// 越远。改成监听 ChatController：每次通知后按帧排队，等这一帧布局完成、
  /// maxScrollExtent 更新后再跳过去。生成结束、回答落库成正式消息时也一样，
  /// 保证最后一行和它下面的「···」不会被切在屏幕外。
  ///
  /// 只在「用户停在底部附近」时跟随；用户手动上翻后不再抢滚动。
  void _onChatUpdated() {
    if (!_followEnabled || !_isNearBottom) return;
    _scheduleFollowBottom();
  }

  /// 下一帧布局完成后再贴底。
  ///
  /// 同一帧只排一次：流式分片可能一帧来好几次，逐个排帧回调只会重复同一个
  /// 目标位置。转场动画进行中直接放弃，避免和转场/输入法收起动画抢同一帧
  /// （见 [_computeTransitionIdle]）。
  void _scheduleFollowBottom() {
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scrollCtrl.hasClients) return;
      if (!_followEnabled || !_isNearBottom || !_routeIdle) return;
      final position = _scrollCtrl.position;
      final target = position.maxScrollExtent;
      if (target <= position.pixels + 0.5) return;
      _scrollCtrl.jumpTo(target);
    });
  }

  /// 路由转场（切页 / 返回）是否已经停下。
  ///
  /// 自动跟随如果在转场期间逐帧写滚动位置，就会和转场动画、以及输入法收起
  /// 动画抢同一帧。这里只按路由动画的**状态**判断，不读动画值：在
  /// [didChangeDependencies] 里给两条动画挂状态监听，转场一开始立刻标记为
  /// 「忙」，动画完成后恢复。状态监听只在 forward/reverse/completed 切换时
  /// 触发，开销可以忽略；同时避免在帧回调里调用 `ModalRoute.of`（那会在
  /// 非 build 时机注册 InheritedWidget 依赖）。
  bool _computeTransitionIdle() {
    final route = _route;
    if (route == null) return true;
    for (final animation in <Animation<double>?>[
      route.animation,
      route.secondaryAnimation,
    ]) {
      final status = animation?.status;
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return false;
      }
    }
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onRouteStatusChanged);
      _route?.secondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteStatusChanged);
      _route?.secondaryAnimation?.addStatusListener(_onRouteStatusChanged);
    }
    _routeIdle = _computeTransitionIdle();
  }

  void _onRouteStatusChanged(AnimationStatus status) {
    _routeIdle = _computeTransitionIdle();
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onRouteStatusChanged);
    _route?.secondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    _chat.removeListener(_onChatChanged);
    _chat.removeListener(_onChatUpdated);
    _scrollCtrl.removeListener(_onScrollChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── 编辑模式方法 ──

  void _enterEditMode(int index) {
    setState(() {
      _isEditMode = true;
      _selectedIndices.add(index);
    });
  }

  void _exitEditMode() {
    setState(() {
      _isEditMode = false;
      _selectedIndices.clear();
    });
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
        if (_selectedIndices.isEmpty) {
          _isEditMode = false;
        }
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _selectAll() {
    final chat = ref.read(chatProvider);
    setState(() {
      if (_selectedIndices.length == chat.messages.length) {
        _selectedIndices.clear();
      } else {
        for (int i = 0; i < chat.messages.length; i++) {
          _selectedIndices.add(i);
        }
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIndices.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息', style: TextStyle(fontSize: 14)),
        content: Text(
          '确定删除选中的 ${_selectedIndices.length} 条消息吗？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(fontSize: 13, color: ctx.palette.danger),
            ),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final indices = Set<int>.from(_selectedIndices);
      _exitEditMode();
      await ref.read(chatProvider).deleteMessages(indices);
    }
  }

  void _copySelected() {
    if (_selectedIndices.isEmpty) return;
    final chat = ref.read(chatProvider);
    final buffer = StringBuffer();
    final sorted = _selectedIndices.toList()..sort();
    for (final index in sorted) {
      if (index >= 0 && index < chat.messages.length) {
        final msg = chat.messages[index];
        final prefix = msg.isUser ? '用户：' : '助手：';
        // 与气泡显示保持一致：复制出去的助手内容同样去掉 Markdown 标记
        final content = msg.isUser
            ? msg.content
            : stripMarkdownForChat(msg.content);
        buffer.writeln('$prefix$content');
      }
    }
    Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    _exitEditMode();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板', style: TextStyle(fontSize: 12)),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 复制单条消息（气泡下方「复制」）
  void _copyMessage(int index) {
    final chat = ref.read(chatProvider);
    if (index < 0 || index >= chat.messages.length) return;
    final msg = chat.messages[index];
    final content = msg.isUser
        ? msg.content
        : stripMarkdownForChat(msg.content);
    Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板', style: TextStyle(fontSize: 12)),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 删除单条消息（气泡下方「删除」，需要确认）
  Future<void> _deleteMessageAt(int index) async {
    final chat = ref.read(chatProvider);
    if (index < 0 || index >= chat.messages.length) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息', style: TextStyle(fontSize: 14)),
        content: const Text('确定删除这条消息吗？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: ctx.palette.danger)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await chat.deleteMessages({index});
    }
  }

  /// 「缓存命中」：显示**这条回答**那次请求的缓存命中（不是会话累计）
  void _showCacheStats(int index) {
    final chat = ref.read(chatProvider);
    if (index < 0 || index >= chat.messages.length) return;
    final message = chat.messages[index];
    final percent = message.cachePercent;
    final p = context.palette;
    final lines = <String>[];
    if (percent == null) {
      lines.add('这条回答没有记录缓存数据。');
      lines.add('旧消息或非流式请求不统计；之后的新回答会记录当次的用量。');
    } else {
      lines.add('该条回答缓存命中：$percent%');
      lines.add('输入：${_formatTokenCount(message.promptTokens)} tokens');
      lines.add('命中：${_formatTokenCount(message.cachedTokens)} tokens');
      lines.add('输出：${_formatTokenCount(message.completionTokens)} tokens');
      final sessionPercent = chat.cachePercent;
      lines.add('');
      lines.add(
        sessionPercent == null
            ? '本会话累计：暂无统计'
            : '本会话累计：$sessionPercent%（见输入框上方）',
      );
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.bolt, size: 16, color: p.accent),
            const SizedBox(width: 6),
            const Text('缓存命中', style: TextStyle(fontSize: 14)),
          ],
        ),
        content: Text(
          lines.join('\n'),
          style: TextStyle(fontSize: 12, height: 1.6, color: p.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ── 页面跳转 ──

  /// 切换页面：收输入法 + 立即 push，不做任何等待。
  ///
  /// 曾经的坑：输入框有焦点时点「写小说」，输入法还没收回，新页面正文只剩
  /// 400 出头的高度，内容高度固定的页面就 RenderFlex overflow。当时的修法是
  /// 先 unfocus 再等窗口 inset 归零 —— 结果切页要多等一帧到几帧，手感发涩。
  ///
  /// 现在等待去掉了：目标页自身改成可滚动布局（见 novel_writing_page.dart），
  /// 输入法收起动画与新页面入场动画同时进行也不会有布局溢出，于是切页回到
  /// 「立即响应」。unfocus 仍然保留，否则键盘会挂在新页面上不收。
  /// [routeName] 会写进 MaterialPageRoute.settings，供全局悬浮层判断
  /// 「这个页面上该不该显示悬浮聊天球」（见 chat_floating_ball.dart）。
  Future<void> _pushPage(Widget page, {String? routeName}) {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: routeName),
        builder: (_) => page,
      ),
    );
  }

  /// 打开设置页：先确保设置已加载，再推入页面。
  ///
  /// 若直接推入，页面首帧只能画「转圈」，数据库读完后才在推入动画中途
  /// 一次性建出整页表单（600+ widget / 十余个输入框）——那一帧就是打开
  /// 设置页时肉眼看到的掉帧。正常情况下设置已在启动时预热，这里的 await
  /// 只是一次同步返回。
  Future<void> _openSettings() async {
    await ref.read(settingProvider).loadSettings();
    if (!mounted) return;
    await _pushPage(const SettingsPage(), routeName: kSettingsRouteName);
  }

  // ── 发送消息 ──

  void _onSend() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty || _chat.isLoading) return;

    _inputCtrl.clear();
    // sendMessage 会同步 notifyListeners（isLoading=true），停在底部时由
    // _onChatUpdated 排队贴底；不再用固定 100ms 的 delayed 抢滚动。
    _chat.sendMessage(text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 分别 select 非流式字段，流式文本变更时只重建 _StreamingBubble
    final messages = ref.watch(chatProvider.select((p) => p.messages));
    final isStreamingEmpty = ref.watch(
      chatProvider.select((p) => p.isStreamingEmpty),
    );
    final isLoading = ref.watch(chatProvider.select((p) => p.isLoading));
    final sessionTitle = ref.watch(
      chatProvider.select((p) => p.currentSession?.title ?? '新对话'),
    );
    final hasSession = ref.watch(
      chatProvider.select((p) => p.currentSession != null),
    );
    // 上下文占用 / 缓存命中：合成一条 watch，任一变化都重建输入区
    final usage = ref.watch(
      chatProvider.select(
        (p) => (
          tokens: p.displayContextTokens,
          window: p.contextWindow,
          cache: p.cachePercent,
          compacted: p.lastCompactedCount,
          compacting: p.isCompacting,
        ),
      ),
    );
    // 设置页「显示缓存命中」开关：只影响展示，不影响请求。
    final showCacheHit = ref.watch(
      settingProvider.select((c) => c.showCacheHit),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (_isEditMode) {
          _exitEditMode();
          return;
        }

        // 非根路由（如悬浮面板“展开”进入的完整聊天页）：直接返回上一页
        final isRoot = ModalRoute.of(context)?.isFirst ?? true;
        if (!isRoot) {
          Navigator.of(context).pop();
          return;
        }

        final confirm = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            title: const Text('提示'),
            content: const Text('确定退出应用吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('确定', style: TextStyle(color: ctx.palette.danger)),
              ),
            ],
          ),
        );

        if (confirm == true && context.mounted) {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: p.background,
        drawer: const HistoryDrawer(),
        appBar: _isEditMode
            ? _buildEditAppBar()
            : _buildAppBar(sessionTitle, hasSession),
        body: Column(
          children: [
            Expanded(
              child: _buildMessageList(
                messages,
                isStreamingEmpty,
                showCacheHit,
              ),
            ),
            if (!_isEditMode) ...[
              Divider(height: 1, color: p.border),
              _buildInputArea(isLoading, context, usage, showCacheHit),
            ],
          ],
        ),
        bottomNavigationBar: _isEditMode ? _buildEditBottomBar() : null,
      ),
    );
  }

  /// 普通模式 AppBar
  PreferredSizeWidget _buildAppBar(String title, bool hasSession) {
    final p = context.palette;
    // 非根路由（悬浮面板展开进入的聊天页）显示返回按钮
    final isRoot = ModalRoute.of(context)?.isFirst ?? true;
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: p.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: isRoot
          ? IconButton(
              icon: Icon(Icons.menu, color: p.textPrimary, size: 20),
              constraints: BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: '历史会话',
              // 打开历史抽屉前先收起输入法：抽屉只是覆盖在聊天页之上、
              // 不经过 _pushPage，不收的话键盘会一直挂在抽屉下方，
              // 关掉抽屉回到聊天页时它仍然是展开的。
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                _scaffoldKey.currentState?.openDrawer();
              },
            )
          : BackButton(
              color: p.textPrimary,
              onPressed: () => Navigator.of(context).pop(),
            ),
      title: GestureDetector(
        onTap: () {
          // 点击标题打开当前会话的设置页
          if (hasSession) {
            // 命名路由：会话设置页右上角全是控件，全局悬浮球要在这页隐藏。
            _pushPage(
              const SessionSettingsPage(),
              routeName: kSessionSettingsRouteName,
            );
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: p.textTertiary),
          ],
        ),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: Icon(Icons.auto_stories, color: p.textPrimary, size: 20),
          constraints: BoxConstraints(minWidth: 36, minHeight: 36),
          tooltip: '写小说',
          onPressed: () => _pushPage(const NovelWritingPage()),
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_horiz, color: p.textPrimary, size: 20),
          constraints: BoxConstraints(minWidth: 36, minHeight: 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 2,
          onSelected: (value) {
            switch (value) {
              case 'settings':
                // 带名字推入：设置页右上角全是控件，全局悬浮球要在这页隐藏。
                _openSettings();
              case 'game':
                _pushPage(const GameHubPage());
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'settings',
              child: Row(
                children: [
                  Icon(Icons.settings, size: 18, color: p.textSecondary),
                  SizedBox(width: 8),
                  Text('设置', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'game',
              child: Row(
                children: [
                  Icon(Icons.videogame_asset, size: 18, color: p.textSecondary),
                  SizedBox(width: 8),
                  Text('游戏', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ],
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: p.border),
      ),
    );
  }

  /// 编辑模式 AppBar（仅保留取消和标题）
  PreferredSizeWidget _buildEditAppBar() {
    final p = context.palette;
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: p.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: GestureDetector(
        onTap: _exitEditMode,
        child: Container(
          alignment: Alignment.center,
          child: Text('取消', style: TextStyle(fontSize: 13, color: p.accent)),
        ),
      ),
      title: Text(
        '选择消息 (${_selectedIndices.length})',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
      ),
      centerTitle: true,
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: p.border),
      ),
    );
  }

  /// 编辑模式底部操作栏
  Widget _buildEditBottomBar() {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              // 全选
              Expanded(
                child: GestureDetector(
                  onTap: _selectAll,
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(
                      '全选',
                      style: TextStyle(
                        fontSize: 14,
                        color: p.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: p.border),
              // 复制
              Expanded(
                child: GestureDetector(
                  onTap: _selectedIndices.isEmpty ? null : _copySelected,
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(
                      '复制',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _selectedIndices.isEmpty
                            ? p.textTertiary
                            : p.accent,
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: p.border),
              // 删除
              Expanded(
                child: GestureDetector(
                  onTap: _selectedIndices.isEmpty ? null : _deleteSelected,
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(
                      '删除',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _selectedIndices.isEmpty
                            ? p.textTertiary
                            : p.danger,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(
    List<ChatMessage> messages,
    bool isStreamingEmpty,
    bool showCacheHit,
  ) {
    return NotificationListener<ScrollNotification>(
      // 用户开始拖动 / 上滑时立即暂停自动贴底，避免底部附近被下一帧拉回去。
      onNotification: _onScrollNotification,
      child: NotificationListener<ScrollMetricsNotification>(
        // 内容变高 / 键盘弹出改变视口时 maxScrollExtent 会变化，但 ChatController
        // 不一定发通知（例如输入法收起、字体加载、图片解码）。这里兜底一次：
        // 只有用户仍停在底部且没有手动上翻时才重新贴底。
        onNotification: (notification) {
          if (notification.depth == 0 &&
              axisDirectionToAxis(notification.metrics.axisDirection) ==
                  Axis.vertical &&
              _followEnabled &&
              _isNearBottom) {
            _scheduleFollowBottom();
          }
          return false;
        },
        child: CupertinoScrollbar(
          controller: _scrollCtrl,
          // 只在滑动时显示：thumbVisibility 保持默认 false（不传 true）。
          // 常显的滚动条在聊天页会一直压着消息列表右侧，很扎眼；默认行为是
          // 开始滚动时淡入、停止滚动后自动淡出，内容不足一屏时不会出现。
          thickness: 6,
          radius: const Radius.circular(3),
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: messages.length + (isStreamingEmpty ? 0 : 1),
            itemBuilder: (context, index) {
              if (index < messages.length) {
                return RepaintBoundary(
                  child: MessageBubble(
                    key: ValueKey(messages[index].hashCode),
                    message: messages[index],
                    showCacheHit: showCacheHit,
                    isEditMode: _isEditMode,
                    isSelected: _selectedIndices.contains(index),
                    onEditRequested: () => _enterEditMode(index),
                    onCopy: () => _copyMessage(index),
                    onDelete: () => _deleteMessageAt(index),
                    onShowCache: () => _showCacheStats(index),
                    onToggleSelection: _isEditMode
                        ? () => _toggleSelection(index)
                        : null,
                  ),
                );
              }
              // 流式实时渲染
              return RepaintBoundary(child: const _StreamingBubble());
            },
          ),
        ),
      ),
    );
  }

  /// 放大输入弹窗
  void _showExpandInputDialog(BuildContext context) {
    final ctrl = TextEditingController(text: _inputCtrl.text);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final p = ctx.palette;
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 20,
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          titlePadding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '编辑输入',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: Icon(Icons.close, size: 16, color: p.textTertiary),
              ),
            ],
          ),
          content: Scrollbar(
            thumbVisibility: true,
            trackVisibility: true,
            thickness: 6,
            radius: const Radius.circular(3),
            child: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.sizeOf(ctx).height * 0.55,
              child: TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(fontSize: 12, color: p.textPrimary),
                decoration: InputDecoration(
                  hintText: '输入问题或指令...',
                  hintStyle: TextStyle(color: p.textTertiary, fontSize: 12),
                  filled: true,
                  fillColor: p.surfaceMuted,
                  contentPadding: const EdgeInsets.all(8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          actions: [
            SizedBox(
              width: 56,
              height: 26,
              child: OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(
                  '取消',
                  style: TextStyle(fontSize: 12, color: p.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 56,
              height: 26,
              child: ElevatedButton(
                onPressed: () {
                  _inputCtrl.text = ctrl.text;
                  Navigator.of(ctx).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: p.onAccent,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('确定', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInputArea(
    bool isLoading,
    BuildContext context,
    ({int tokens, int window, int? cache, int compacted, bool compacting})
    usage,
    bool showCacheHit,
  ) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: p.surface,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildUsageBar(context, usage, showCacheHit),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    style: TextStyle(fontSize: 12, color: p.textPrimary),
                    decoration: InputDecoration(
                      hintText: '输入问题或指令...',
                      hintStyle: TextStyle(color: p.textTertiary, fontSize: 12),
                      filled: true,
                      fillColor: p.surfaceMuted,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: GestureDetector(
                          onTap: () => _showExpandInputDialog(context),
                          child: Icon(
                            Icons.fullscreen,
                            size: 14,
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    onSubmitted: (_) => _onSend(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: isLoading ? () => _chat.cancelRequest() : _onSend,
                  icon: Icon(
                    isLoading ? Icons.stop : Icons.arrow_upward,
                    size: 16,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: isLoading ? p.danger : p.accent,
                    foregroundColor: p.onAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    minimumSize: const Size(32, 32),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 输入框上方的上下文占用 / 缓存命中条。
  ///
  /// 数值来自 API usage；还没拿到时显示发送前估算的占用。DSH 式压缩发生时
  /// 会提示压缩了多少条历史。
  Widget _buildUsageBar(
    BuildContext context,
    ({int tokens, int window, int? cache, int compacted, bool compacting})
    usage,
    bool showCacheHit,
  ) {
    if (usage.tokens <= 0 && usage.window <= 0 && usage.compacted == 0) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final window = usage.window > 0
        ? usage.window
        : ChatContextBudget.defaultWindow;
    final percent = window > 0
        ? (usage.tokens * 100 / window).clamp(0.0, 100.0)
        : 0.0;
    final percentText = percent > 0 && percent < 10
        ? percent.toStringAsFixed(1)
        : percent.round().toString();
    final cache = usage.cache;

    // 统一中性色：上下文 / 缓存只做信息展示，不用颜色区分高低。
    final neutralForeground = p.textSecondary;
    final neutralBackground = p.surfaceMuted;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: _usageBarCollapsed
          ? Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: _usageBarToggle(collapsed: true),
              ),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _usagePill(
                        context,
                        key: const ValueKey('chat_usage_context'),
                        icon: Icons.data_usage_rounded,
                        label: '上下文',
                        value: '$percentText%',
                        foreground: neutralForeground,
                        background: neutralBackground,
                      ),
                      if (showCacheHit) ...[
                        const SizedBox(width: 6),
                        _usagePill(
                          context,
                          key: const ValueKey('chat_usage_cache'),
                          icon: Icons.bolt_rounded,
                          label: '缓存',
                          value: cache == null ? '—' : '$cache%',
                          foreground: neutralForeground,
                          background: neutralBackground,
                        ),
                      ],
                      if (usage.compacting) ...[
                        const SizedBox(width: 6),
                        _usagePill(
                          context,
                          leading: SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: p.textTertiary,
                            ),
                          ),
                          label: '压缩中',
                          value: '',
                          foreground: neutralForeground,
                          background: neutralBackground,
                        ),
                      ] else if (usage.compacted > 0) ...[
                        const SizedBox(width: 6),
                        _usagePill(
                          context,
                          icon: Icons.compress,
                          label: '已压缩',
                          value: '${usage.compacted} 条',
                          foreground: neutralForeground,
                          background: neutralBackground,
                        ),
                      ],
                      const Spacer(),
                      if (usage.tokens > 0)
                        Flexible(
                          child: Text(
                            '${_formatTokenCount(usage.tokens)} / ${_formatTokenCount(window)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: p.textTertiary,
                              height: 1.2,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(width: 2),
                      _usageBarToggle(collapsed: false),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // 细进度条：只表达占用比例，同样保持中性色
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: percent / 100,
                      minHeight: 3,
                      backgroundColor: p.border,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// 用量条右端的收起 / 展开按钮。
  Widget _usageBarToggle({required bool collapsed}) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: collapsed ? '展开上下文与缓存' : '收起上下文与缓存',
      child: InkResponse(
        key: const ValueKey('chat_usage_toggle'),
        onTap: () => setState(() => _usageBarCollapsed = !_usageBarCollapsed),
        radius: 14,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            collapsed
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: p.textTertiary,
          ),
        ),
      ),
    );
  }

  /// 用量条上的小胶囊：图标 + 标签 + 数值，全部使用中性色。
  Widget _usagePill(
    BuildContext context, {
    Key? key,
    IconData? icon,
    Widget? leading,
    required String label,
    required String value,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      key: key,
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null)
            leading
          else if (icon != null)
            Icon(icon, size: 12, color: foreground),
          if (leading != null || icon != null) const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: foreground, height: 1.1),
          ),
          if (value.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: foreground,
                height: 1.1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatTokenCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      final k = value / 1000;
      return '${k >= 100 ? k.round() : k.toStringAsFixed(1)}k';
    }
    return '$value';
  }
}

/// ─── 流式实时气泡（打字机效果） ───

class _StreamingBubble extends ConsumerWidget {
  const _StreamingBubble();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final chat = ref.watch(chatProvider);

    final hasPhase1 = chat.phase1Text.isNotEmpty;
    final phase1Visible = hasPhase1 && chat.streamingText.isEmpty;
    final phase2Visible = chat.streamingText.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        // 助手输出占满列表可用宽度（列表左右各有 12dp 内边距）。
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 流式思考内容
              if (chat.streamingThinking.isNotEmpty)
                _buildStreamingThinking(chat.streamingThinking, p),
              // Phase 1 正文（搜索期间保持显示）
              if (phase1Visible)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: p.bubbleAssistant,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: ChatMarkdown(chat.phase1Text),
                ),
              // Phase 2 正文（流式展示，含 Phase 1 前缀）
              if (phase2Visible) ...[
                if (chat.streamingThinking.isNotEmpty)
                  const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: p.bubbleAssistant,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: ChatMarkdown(
                    hasPhase1
                        ? '${chat.phase1Text}\n\n${chat.streamingText}'
                        : chat.streamingText,
                  ),
                ),
              ],
              // 加载指示器
              if (chat.streamingText.isEmpty &&
                  chat.streamingThinking.isEmpty &&
                  !hasPhase1)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.accent,
                      ),
                    ),
                  ),
                ),
              // Phase 1 加载中（搜索进行中）
              if (phase1Visible)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingThinking(String thinking, AppPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology, size: 14, color: p.textTertiary),
              const SizedBox(width: 4),
              Text(
                '思考中...',
                style: TextStyle(fontSize: 11, color: p.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ChatMarkdown(thinking, fontSize: 11, textColor: p.textSecondary),
        ],
      ),
    );
  }
}
