// lib/views/chat_page.dart
// 主对话页面 — 对话消息区域 + 输入框 + 流式实时渲染

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/route_names.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import 'history_page.dart';
import 'settings_page.dart';
import 'session_setting_page.dart';
import '../../novel_writing/novel_writing_page.dart';
import 'widgets/message_bubble.dart';
import 'widgets/search_sources_card.dart';
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

  /// 已滚到底部的会话 id（抽屉切换会话/新建会话后需要重新定位到底部）
  int? _scrolledSessionId;

  ChatController get _chat => ref.read(chatProvider);

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScrollChanged);
    // 监听会话切换：抽屉里选中历史会话后自动定位到最新消息
    ref.read(chatProvider).addListener(_onChatChanged);
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
      _isNearBottom = (maxScroll - _scrollCtrl.position.pixels) < 80;
    }
  }

  /// 路由转场（切页 / 返回）是否已经停下。
  ///
  /// 为什么要判断这个：`_ModalScope` 是把 `buildPage` 包在 `AnimatedBuilder`
  /// 里调用的（flutter/lib/src/widgets/routes.dart），所以**转场动画的每一帧
  /// 都会重跑整页 build**。自动跟随如果在 build 里直接 jumpTo，就等于每帧强制
  /// 写一次滚动位置——视口要重新布局并重绘，和转场动画、以及输入法收起动画
  /// 叠在同一帧里，这就是「键盘开着切页掉帧」的主要来源。
  bool get _transitionIdle {
    final route = ModalRoute.of(context);
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
  void dispose() {
    ref.read(chatProvider).removeListener(_onChatChanged);
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
            child: const Text(
              '删除',
              style: TextStyle(fontSize: 13, color: Colors.red),
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
        buffer.writeln('$prefix${msg.content}');
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

  // ── 发送消息 ──

  void _onSend() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty || _chat.isLoading) return;

    _inputCtrl.clear();
    _chat.sendMessage(text);

    // 滚动到底部（用户未手动翻阅时才自动跟随）
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients && _isNearBottom) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
                child: Text('确定', style: TextStyle(color: Colors.red)),
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
        backgroundColor: Colors.white,
        drawer: const HistoryDrawer(),
        appBar: _isEditMode
            ? _buildEditAppBar()
            : _buildAppBar(sessionTitle, hasSession),
        body: Column(
          children: [
            Expanded(child: _buildMessageList(messages, isStreamingEmpty)),
            if (!_isEditMode) ...[
              const Divider(height: 1, color: Color(0xFFEEEEEE)),
              _buildInputArea(isLoading, context),
            ],
          ],
        ),
        bottomNavigationBar: _isEditMode ? _buildEditBottomBar() : null,
      ),
    );
  }

  /// 普通模式 AppBar
  PreferredSizeWidget _buildAppBar(String title, bool hasSession) {
    // 非根路由（悬浮面板展开进入的聊天页）显示返回按钮
    final isRoot = ModalRoute.of(context)?.isFirst ?? true;
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: isRoot
          ? IconButton(
              icon: const Icon(Icons.menu, color: Color(0xFF333333), size: 20),
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
              color: const Color(0xFF333333),
              onPressed: () => Navigator.of(context).pop(),
            ),
      title: GestureDetector(
        onTap: () {
          // 点击标题打开当前会话的设置页
          if (hasSession) {
            _pushPage(const SessionSettingsPage());
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: Color(0xFF999999),
            ),
          ],
        ),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(
            Icons.auto_stories,
            color: Color(0xFF333333),
            size: 20,
          ),
          constraints: BoxConstraints(minWidth: 36, minHeight: 36),
          tooltip: '写小说',
          onPressed: () => _pushPage(const NovelWritingPage()),
        ),
        PopupMenuButton<String>(
          icon: const Icon(
            Icons.more_horiz,
            color: Color(0xFF333333),
            size: 20,
          ),
          constraints: BoxConstraints(minWidth: 36, minHeight: 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 2,
          onSelected: (value) {
            switch (value) {
              case 'settings':
                // 带名字推入：设置页右上角全是控件，全局悬浮球要在这页隐藏。
                _pushPage(const SettingsPage(), routeName: kSettingsRouteName);
              case 'game':
                _pushPage(const GameHubPage());
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'settings',
              child: Row(
                children: [
                  Icon(Icons.settings, size: 18, color: Color(0xFF666666)),
                  SizedBox(width: 8),
                  Text('设置', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'game',
              child: Row(
                children: [
                  Icon(
                    Icons.videogame_asset,
                    size: 18,
                    color: Color(0xFF666666),
                  ),
                  SizedBox(width: 8),
                  Text('游戏', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
      ),
    );
  }

  /// 编辑模式 AppBar（仅保留取消和标题）
  PreferredSizeWidget _buildEditAppBar() {
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: GestureDetector(
        onTap: _exitEditMode,
        child: Container(
          alignment: Alignment.center,
          child: const Text(
            '取消',
            style: TextStyle(fontSize: 13, color: Color(0xFF4D6BFE)),
          ),
        ),
      ),
      title: Text(
        '选择消息 (${_selectedIndices.length})',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF333333),
        ),
      ),
      centerTitle: true,
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
      ),
    );
  }

  /// 编辑模式底部操作栏
  Widget _buildEditBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
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
                    child: const Text(
                      '全选',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF4D6BFE),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: const Color(0xFFEEEEEE)),
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
                            ? const Color(0xFFCCCCCC)
                            : const Color(0xFF4D6BFE),
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: const Color(0xFFEEEEEE)),
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
                            ? const Color(0xFFCCCCCC)
                            : Colors.redAccent,
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

  Widget _buildMessageList(List<ChatMessage> messages, bool isStreamingEmpty) {
    // 流式生成中：若用户在底部附近则自动滚动
    // 直接 jumpTo 而非 addPostFrameCallback，减少帧回调堆积；
    // 但转场动画进行中必须停手——转场每帧都会重跑整页 build（见 _transitionIdle），
    // 那时 jumpTo 等于每帧强制写一次滚动位置，和转场/输入法收起动画抢同一帧。
    if (isStreamingEmpty == false &&
        _isNearBottom &&
        _transitionIdle &&
        _scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    }

    return CupertinoScrollbar(
      controller: _scrollCtrl,
      thumbVisibility: true,
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
                isEditMode: _isEditMode,
                isSelected: _selectedIndices.contains(index),
                onEditRequested: () => _enterEditMode(index),
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
    );
  }

  /// 放大输入弹窗
  void _showExpandInputDialog(BuildContext context) {
    final ctrl = TextEditingController(text: _inputCtrl.text);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
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
                child: const Icon(
                  Icons.close,
                  size: 16,
                  color: Color(0xFF999999),
                ),
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
                style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
                decoration: InputDecoration(
                  hintText: '输入问题或指令...',
                  hintStyle: const TextStyle(
                    color: Color(0xFFBBBBBB),
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
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
                child: const Text(
                  '取消',
                  style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
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
                  backgroundColor: const Color(0xFF4D6BFE),
                  foregroundColor: Colors.white,
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

  Widget _buildInputArea(bool isLoading, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Colors.white,
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
                decoration: InputDecoration(
                  hintText: '输入问题或指令...',
                  hintStyle: const TextStyle(
                    color: Color(0xFFBBBBBB),
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
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
                        color: Color(0xFF999999),
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
              icon: Icon(isLoading ? Icons.stop : Icons.arrow_upward, size: 16),
              style: IconButton.styleFrom(
                backgroundColor: isLoading
                    ? Colors.redAccent
                    : const Color(0xFF4D6BFE),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                minimumSize: const Size(32, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ─── 流式实时气泡（打字机效果） ───

class _StreamingBubble extends ConsumerWidget {
  const _StreamingBubble();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider);

    final hasPhase1 = chat.phase1Text.isNotEmpty;
    final phase1Visible = hasPhase1 && chat.streamingText.isEmpty;
    final phase2Visible = chat.streamingText.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.widthOf(context) * 0.8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 流式思考内容
              if (chat.streamingThinking.isNotEmpty)
                _buildStreamingThinking(chat.streamingThinking),
              // Phase 1 正文（搜索期间保持显示）
              if (phase1Visible)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: SelectableText(
                    chat.phase1Text,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF333333),
                      height: 1.5,
                    ),
                  ),
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
                    color: const Color(0xFFF5F5F5),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: SelectableText(
                    hasPhase1
                        ? '${chat.phase1Text}\n\n${chat.streamingText}'
                        : chat.streamingText,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF333333),
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              // 加载指示器
              if (chat.streamingText.isEmpty &&
                  chat.streamingThinking.isEmpty &&
                  !hasPhase1)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF4D6BFE),
                    ),
                  ),
                ),
              // Phase 1 加载中（搜索进行中）
              if (phase1Visible)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF4D6BFE),
                    ),
                  ),
                ),
              // 流式搜索结果（保持在最底部，与 _MessageBubble 顺序一致）
              if (chat.streamingSearchResults != null &&
                  chat.streamingSearchResults!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SearchSourcesCard(
                    results: chat.streamingSearchResults!,
                    collapsible: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingThinking(String thinking) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.psychology, size: 14, color: Color(0xFF999999)),
              const SizedBox(width: 4),
              const Text(
                '思考中...',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            thinking,
            style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
          ),
        ],
      ),
    );
  }
}
