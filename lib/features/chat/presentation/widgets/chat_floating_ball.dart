// lib/features/chat/presentation/widgets/chat_floating_ball.dart
// 全局悬浮聊天球 — 离开主聊天页（如写小说、游戏等页面）后显示，
// 点击悬浮球可展开缩小化的聊天面板，面板与主聊天页共用同一个
// chatProvider，消息、会话、流式输出完全互通。

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/chat_controller.dart';
import '../../domain/chat_message.dart';
import '../chat_page.dart'; // ChatPage（面板“展开”时打开完整聊天页）
import 'message_bubble.dart';

/// 悬浮球直径
const double _kBallSize = 48;

/// 迷你面板默认尺寸
const double _kPanelWidth = 340;
const double _kPanelHeight = 540;

/// 迷你面板尺寸可调范围
const double _kMinPanelWidth = 220;
const double _kMinPanelHeight = 300;

/// 悬浮面板“展开”进入完整聊天页的路由名（用于识别并隐藏悬浮球）
const String _kFloatingChatRouteName = '/floating_chat';

/// 在「事件回调 / 一次性读取」里取 MediaQuery，不建立依赖。
///
/// `MediaQuery.of` 会把调用它的那个 Element 注册成依赖方；而悬浮层挂在
/// Overlay 上（在 Scaffold 之上），拿到的是**根** MediaQuery——键盘弹出动画
/// 期间 viewInsets 每帧都在变。于是只要拖动 / 缩放一次，悬浮球或迷你面板
/// 就会被每帧重建，等于把刚修掉的漏洞又从后门放回来。
/// `getInheritedWidgetOfExactType` 只查表返回，不注册依赖，正合这类场景。
MediaQueryData _mqDataOf(BuildContext context) =>
    context.getInheritedWidgetOfExactType<MediaQuery>()?.data ??
    MediaQueryData.fromView(View.of(context));

/// 路由观察者：维护当前路由栈，判断何时显示悬浮球。
class FloatingChatRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];
  VoidCallback? onRoutesChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _stack.add(route);
    onRoutesChanged?.call();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _stack.remove(route);
    onRoutesChanged?.call();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _stack.remove(route);
    onRoutesChanged?.call();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) _stack.remove(oldRoute);
    if (newRoute != null) _stack.add(newRoute);
    onRoutesChanged?.call();
  }

  /// 是否已回到主聊天页（根路由）
  bool get isAtHomeRoute => _stack.length <= 1;

  /// 仅当离开主聊天页（根路由）且顶层路由不透明（弹窗/底部弹层不显示）时显示悬浮球
  bool get shouldShowFloatingBall {
    if (isAtHomeRoute) return false;
    final route = _stack.last;
    // 面板“展开”进入的完整聊天页不显示悬浮球
    if (route.settings.name == _kFloatingChatRouteName) return false;
    return route is TransitionRoute && route.opaque;
  }
}

/// 悬浮聊天宿主：挂在 MaterialApp.builder 上，管理悬浮球与迷你面板的 Overlay。
class ChatFloatingBallHost extends ConsumerStatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  final FloatingChatRouteObserver observer;

  const ChatFloatingBallHost({
    super.key,
    required this.child,
    required this.navigatorKey,
    required this.observer,
  });

  @override
  ConsumerState<ChatFloatingBallHost> createState() =>
      _ChatFloatingBallHostState();
}

class _ChatFloatingBallHostState extends ConsumerState<ChatFloatingBallHost> {
  final ValueNotifier<bool> _ballVisible = ValueNotifier(false);
  final ValueNotifier<bool> _panelOpen = ValueNotifier(false);
  final ValueNotifier<Offset> _ballPosition = ValueNotifier(Offset.zero);
  final ValueNotifier<Offset> _panelPosition = ValueNotifier(Offset.zero);
  final ValueNotifier<Size> _panelSize = ValueNotifier(Size.zero);
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    widget.observer.onRoutesChanged = _syncVisibility;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initPositions();
      _insertOverlayEntry();
      _syncVisibility();
    });
  }

  void _initPositions() {
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final size = _mqDataOf(overlay.context).size;
    _ballPosition.value = Offset(
      size.width - _kBallSize - 16,
      size.height - 200,
    );
    final panelW = math.min(_kPanelWidth, size.width - 24);
    final panelH = math.min(_kPanelHeight, size.height * 0.72);
    _panelSize.value = Size(panelW, panelH);
    _panelPosition.value = Offset(
      size.width - panelW - 16,
      size.height - panelH - 140,
    );
  }

  void _insertOverlayEntry() {
    final overlay = widget.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    _overlayEntry = OverlayEntry(
      builder: (context) => _FloatingChatLayer(
        ballVisible: _ballVisible,
        panelOpen: _panelOpen,
        ballPosition: _ballPosition,
        panelPosition: _panelPosition,
        panelSize: _panelSize,
        onTapBall: () => _panelOpen.value = true,
        onMinimizePanel: () {
          FocusManager.instance.primaryFocus?.unfocus();
          _panelOpen.value = false;
        },
        onMaximizePanel: () {
          FocusManager.instance.primaryFocus?.unfocus();
          _panelOpen.value = false;
          // 打开完整聊天页：推入新页面，手机返回键可回到原页面
          widget.navigatorKey.currentState?.push(
            MaterialPageRoute(
              settings: const RouteSettings(name: _kFloatingChatRouteName),
              builder: (_) => const ChatPage(),
            ),
          );
        },
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _syncVisibility() {
    _ballVisible.value = widget.observer.shouldShowFloatingBall;
    // 回到主聊天页时自动收起迷你面板
    if (widget.observer.isAtHomeRoute) {
      _panelOpen.value = false;
    }
  }

  @override
  void dispose() {
    widget.observer.onRoutesChanged = null;
    _overlayEntry?.remove();
    _ballVisible.dispose();
    _panelOpen.dispose();
    _ballPosition.dispose();
    _panelPosition.dispose();
    _panelSize.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 悬浮层：悬浮球 + 迷你面板（两者始终挂载，隐藏时用 Offstage 保留内部状态）
class _FloatingChatLayer extends StatelessWidget {
  final ValueListenable<bool> ballVisible;
  final ValueListenable<bool> panelOpen;
  final ValueNotifier<Offset> ballPosition;
  final ValueNotifier<Offset> panelPosition;
  final ValueNotifier<Size> panelSize;
  final VoidCallback onTapBall;
  final VoidCallback onMinimizePanel;
  final VoidCallback onMaximizePanel;

  const _FloatingChatLayer({
    required this.ballVisible,
    required this.panelOpen,
    required this.ballPosition,
    required this.panelPosition,
    required this.panelSize,
    required this.onTapBall,
    required this.onMinimizePanel,
    required this.onMaximizePanel,
  });

  @override
  Widget build(BuildContext context) {
    // 三个分支彼此独立：拖动球/面板/缩放只重建各自分支，
    // 避免整层 setState 导致始终挂载的迷你面板每帧重建（帧率低的主因）。
    return Stack(
      children: [
        // 面板展开时：点击面板外任意区域收起为悬浮球
        AnimatedBuilder(
          animation: panelOpen,
          builder: (context, _) {
            if (!panelOpen.value) return const SizedBox.shrink();
            return Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMinimizePanel,
              ),
            );
          },
        ),
        // 悬浮球（面板展开时隐藏，收起到球时恢复）
        AnimatedBuilder(
          animation: Listenable.merge([ballVisible, panelOpen, ballPosition]),
          builder: (context, _) {
            final visible = ballVisible.value && !panelOpen.value;
            if (!visible) return const SizedBox.shrink();
            final pos = ballPosition.value;
            return Positioned(
              left: pos.dx,
              top: pos.dy,
              child: RepaintBoundary(
                child: _FloatingBall(
                  positionNotifier: ballPosition,
                  onTap: onTapBall,
                ),
              ),
            );
          },
        ),
        // 迷你聊天面板（自由定位，支持拖动与边缘缩放）
        AnimatedBuilder(
          animation: Listenable.merge([panelOpen, panelPosition, panelSize]),
          // 面板作为 child 传进来，不要写在 builder 里：
          // 键盘动画期间 viewInsets 每帧都在变，builder 也就每帧重跑；
          // 若在 builder 里 new 一个 _MiniChatPanel，这个「始终挂载」的面板
          // 就会每帧整棵重建——和上面注释里说的是同一类问题，
          // 只是触发源从拖动换成了键盘。
          child: RepaintBoundary(
            child: _MiniChatPanel(
              visible: panelOpen,
              positionNotifier: panelPosition,
              sizeNotifier: panelSize,
              onMinimize: onMinimizePanel,
              onMaximize: onMaximizePanel,
            ),
          ),
          builder: (context, child) {
            final rawPos = panelPosition.value;
            final pSize = panelSize.value;
            // 按 aspect 读：只有键盘 inset / 屏幕尺寸变化才重跑 builder
            final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
            final screen = MediaQuery.sizeOf(context);
            // 键盘弹出时自动上移，避免遮挡输入区
            final maxDx = math.max(0.0, screen.width - pSize.width - 8);
            final maxDy = math.max(
              0.0,
              screen.height - viewInsets - 8 - pSize.height,
            );
            final effDx = rawPos.dx.clamp(0.0, maxDx);
            final effDy = rawPos.dy.clamp(0.0, maxDy);
            return Positioned(
              left: effDx,
              top: effDy,
              child: Offstage(
                offstage: !panelOpen.value,
                child: SizedBox(
                  width: pSize.width,
                  height: pSize.height,
                  child: child,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 可拖拽的悬浮球（松手后自动吸附到左右边缘）
class _FloatingBall extends ConsumerStatefulWidget {
  final ValueNotifier<Offset> positionNotifier;
  final VoidCallback onTap;

  const _FloatingBall({required this.positionNotifier, required this.onTap});

  @override
  ConsumerState<_FloatingBall> createState() => _FloatingBallState();
}

class _FloatingBallState extends ConsumerState<_FloatingBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snapCtrl;
  late Animation<Offset> _snapAnim;

  @override
  void initState() {
    super.initState();
    _snapCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (_snapCtrl.isAnimating) {
            widget.positionNotifier.value = _snapAnim.value;
          }
        });
    _snapAnim = Tween<Offset>(
      begin: widget.positionNotifier.value,
      end: widget.positionNotifier.value,
    ).animate(CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _snapCtrl.stop();
    final size = _mqDataOf(context).size;
    final topPadding = _mqDataOf(context).padding.top;
    final current = widget.positionNotifier.value;
    final next = Offset(
      (current.dx + details.delta.dx).clamp(4.0, size.width - _kBallSize - 4),
      (current.dy + details.delta.dy).clamp(
        topPadding + 4.0,
        size.height - _kBallSize - 60,
      ),
    );
    widget.positionNotifier.value = next;
  }

  void _onDragEnd(DragEndDetails details) {
    final size = _mqDataOf(context).size;
    final current = widget.positionNotifier.value;
    final targetX = current.dx < size.width / 2
        ? 8.0
        : size.width - _kBallSize - 8;
    _snapAnim = Tween<Offset>(
      begin: current,
      end: Offset(targetX, current.dy),
    ).animate(CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
    _snapCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(chatProvider.select((p) => p.isLoading));
    return GestureDetector(
      onPanStart: (_) => _snapCtrl.stop(),
      onPanUpdate: _onDragUpdate,
      onPanEnd: _onDragEnd,
      onTap: widget.onTap,
      child: Container(
        width: _kBallSize,
        height: _kBallSize,
        decoration: BoxDecoration(
          color: const Color(0xFF4D6BFE),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.chat_bubble, color: Colors.white, size: 24),
            // 回复生成中显示小红点
            if (isLoading)
              Positioned(
                right: 5,
                bottom: 5,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 缩小化聊天面板：标题栏 + 消息列表 + 输入区，与主聊天页共用 chatProvider。
/// 支持拖动（标题栏）与边缘滑动缩放（上下左右边缘 + 右下角把手）。
class _MiniChatPanel extends ConsumerStatefulWidget {
  final ValueListenable<bool> visible;
  final ValueNotifier<Offset> positionNotifier;
  final ValueNotifier<Size> sizeNotifier;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;

  const _MiniChatPanel({
    required this.visible,
    required this.positionNotifier,
    required this.sizeNotifier,
    required this.onMinimize,
    required this.onMaximize,
  });

  @override
  ConsumerState<_MiniChatPanel> createState() => _MiniChatPanelState();
}

class _MiniChatPanelState extends ConsumerState<_MiniChatPanel> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _isNearBottom = true;
  int? _lastSessionId;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScrollChanged);
    // 面板展开时滚动到底部，展示最新消息
    widget.visible.addListener(_onVisibleChanged);
  }

  @override
  void dispose() {
    widget.visible.removeListener(_onVisibleChanged);
    _scrollCtrl.removeListener(_onScrollChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onVisibleChanged() {
    if (widget.visible.value) _scrollToBottom();
  }

  void _onSessionChanged() {
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _onScrollChanged() {
    if (_scrollCtrl.hasClients) {
      final maxScroll = _scrollCtrl.position.maxScrollExtent;
      _isNearBottom = (maxScroll - _scrollCtrl.position.pixels) < 80;
    }
  }

  void _onSend() {
    final text = _inputCtrl.text;
    final chat = ref.read(chatProvider);
    if (text.trim().isEmpty || chat.isLoading) return;

    _inputCtrl.clear();
    chat.sendMessage(text);

    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients && _isNearBottom) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 用 select 监听关键变化，避免流式分片时整面板频繁重建
    final messageCount = ref.watch(
      chatProvider.select((p) => p.messages.length),
    );
    final isStreamingEmpty = ref.watch(
      chatProvider.select((p) => p.isStreamingEmpty),
    );
    final isLoading = ref.watch(chatProvider.select((p) => p.isLoading));
    final title = ref.watch(
      chatProvider.select((p) => p.currentSession?.title ?? '新对话'),
    );
    final sessionId = ref.watch(
      chatProvider.select((p) => p.currentSession?.id),
    );
    // 会话切换后刷新列表并滚动到底部
    if (sessionId != _lastSessionId) {
      _lastSessionId = sessionId;
      _onSessionChanged();
    }
    final messages = ref.read(chatProvider).messages;

    return Stack(
      children: [
        Positioned.fill(
          child: _buildPanelBody(
            messages,
            messageCount,
            isStreamingEmpty,
            isLoading,
            title,
          ),
        ),
        // 边缘滑动缩放热区（透明，置于内容之上）
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: 8,
          child: _buildResizeZone(_onResizeTop),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 8,
          child: _buildResizeZone(_onResizeBottom),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 8,
          child: _buildResizeZone(_onResizeLeft),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 8,
          child: _buildResizeZone(_onResizeRight),
        ),
        // 右下角 2D 缩放把手
        Positioned(right: 0, bottom: 0, child: _buildCornerHandle()),
      ],
    );
  }

  /// 边缘缩放热区
  Widget _buildResizeZone(GestureDragUpdateCallback onUpdate) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: onUpdate,
      child: const SizedBox.expand(),
    );
  }

  /// 右下角 2D 缩放把手
  Widget _buildCornerHandle() {
    return GestureDetector(
      onPanUpdate: _onResizeCorner,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.only(right: 2, bottom: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFDDDDDD)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(Icons.crop_free, size: 13, color: Color(0xFF999999)),
      ),
    );
  }

  // ── 拖动与缩放 ──

  /// 拖动整个窗口（标题栏）
  void _onMove(DragUpdateDetails details) {
    final pos = widget.positionNotifier.value;
    final pSize = widget.sizeNotifier.value;
    final screen = _mqDataOf(context).size;
    final viewInsets = _mqDataOf(context).viewInsets.bottom;
    final maxX = math.max(0.0, screen.width - pSize.width - 8);
    final maxY = math.max(0.0, screen.height - viewInsets - 8 - pSize.height);
    widget.positionNotifier.value = Offset(
      (pos.dx + details.delta.dx).clamp(0.0, maxX),
      (pos.dy + details.delta.dy).clamp(0.0, maxY),
    );
  }

  /// 右边缘：调整宽度（左边缘固定）
  void _onResizeRight(DragUpdateDetails details) {
    final pos = widget.positionNotifier.value;
    final pSize = widget.sizeNotifier.value;
    final screen = _mqDataOf(context).size;
    final maxW = math.max(_kMinPanelWidth, screen.width - pos.dx - 8);
    final newW = (pSize.width + details.delta.dx).clamp(_kMinPanelWidth, maxW);
    widget.sizeNotifier.value = Size(newW, pSize.height);
  }

  /// 左边缘：调整宽度（右边缘固定）
  void _onResizeLeft(DragUpdateDetails details) {
    final pos = widget.positionNotifier.value;
    final pSize = widget.sizeNotifier.value;
    final maxLeft = math.max(0.0, pos.dx + pSize.width - _kMinPanelWidth);
    final newLeft = (pos.dx + details.delta.dx).clamp(0.0, maxLeft);
    widget.positionNotifier.value = Offset(newLeft, pos.dy);
    widget.sizeNotifier.value = Size(
      pos.dx + pSize.width - newLeft,
      pSize.height,
    );
  }

  /// 下边缘：调整高度（上边缘固定）
  void _onResizeBottom(DragUpdateDetails details) {
    final pos = widget.positionNotifier.value;
    final pSize = widget.sizeNotifier.value;
    final screen = _mqDataOf(context).size;
    final viewInsets = _mqDataOf(context).viewInsets.bottom;
    final maxH = math.max(
      _kMinPanelHeight,
      screen.height - viewInsets - 8 - pos.dy,
    );
    final newH = (pSize.height + details.delta.dy).clamp(
      _kMinPanelHeight,
      maxH,
    );
    widget.sizeNotifier.value = Size(pSize.width, newH);
  }

  /// 上边缘：调整高度（下边缘固定）
  void _onResizeTop(DragUpdateDetails details) {
    final pos = widget.positionNotifier.value;
    final pSize = widget.sizeNotifier.value;
    final maxTop = math.max(0.0, pos.dy + pSize.height - _kMinPanelHeight);
    final newTop = (pos.dy + details.delta.dy).clamp(0.0, maxTop);
    widget.positionNotifier.value = Offset(pos.dx, newTop);
    widget.sizeNotifier.value = Size(
      pSize.width,
      pos.dy + pSize.height - newTop,
    );
  }

  /// 右下角：同时调整宽高
  void _onResizeCorner(DragUpdateDetails details) {
    _onResizeRight(details);
    _onResizeBottom(details);
  }

  /// 面板主体：标题栏 + 消息列表 + 输入区
  Widget _buildPanelBody(
    List<ChatMessage> messages,
    int messageCount,
    bool isStreamingEmpty,
    bool isLoading,
    String title,
  ) {
    return Material(
      color: Colors.white,
      elevation: 12,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(title),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          Expanded(
            child: _buildMessageList(messages, messageCount, isStreamingEmpty),
          ),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          _buildInputArea(isLoading),
        ],
      ),
    );
  }

  Widget _buildHeader(String title) {
    return GestureDetector(
      // 拖动标题栏移动整个窗口
      onPanUpdate: _onMove,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble, size: 15, color: Color(0xFF4D6BFE)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.add_comment_outlined,
                size: 18,
                color: Color(0xFF666666),
              ),
              tooltip: '新开聊天',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                ref.read(chatProvider).newSession();
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: Color(0xFF666666),
              ),
              tooltip: '收起',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: widget.onMinimize,
            ),
            IconButton(
              icon: const Icon(
                Icons.open_in_full,
                size: 15,
                color: Color(0xFF666666),
              ),
              tooltip: '回到聊天页',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: widget.onMaximize,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(
    List<ChatMessage> messages,
    int messageCount,
    bool isStreamingEmpty,
  ) {
    // 流式生成中若用户在底部附近则自动滚动
    if (!isStreamingEmpty && _isNearBottom && _scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messageCount + (isStreamingEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          return MessageBubble(message: messages[index]);
        }
        return const _MiniStreamingBubble();
      },
    );
  }

  Widget _buildInputArea(bool isLoading) {
    return Container(
      // 底部留白给右下角缩放把手让位
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 26),
      color: Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
              maxLines: 3,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              onSubmitted: (_) => _onSend(),
              decoration: InputDecoration(
                hintText: '输入问题或指令...',
                hintStyle: const TextStyle(
                  color: Color(0xFFBBBBBB),
                  fontSize: 12,
                ),
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            onPressed: isLoading
                ? () => ref.read(chatProvider).cancelRequest()
                : _onSend,
            icon: Icon(isLoading ? Icons.stop : Icons.arrow_upward, size: 16),
            style: IconButton.styleFrom(
              backgroundColor: isLoading
                  ? Colors.redAccent
                  : const Color(0xFF4D6BFE),
              foregroundColor: Colors.white,
              minimumSize: const Size(32, 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 迷你面板内的流式实时气泡（打字机效果）
class _MiniStreamingBubble extends ConsumerWidget {
  const _MiniStreamingBubble();

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
              if (chat.streamingThinking.isNotEmpty)
                _buildThinkingBox(chat.streamingThinking),
              if (phase1Visible) _buildContentBox(chat.phase1Text),
              if (phase2Visible)
                _buildContentBox(
                  hasPhase1
                      ? '${chat.phase1Text}\n\n${chat.streamingText}'
                      : chat.streamingText,
                ),
              if (chat.streamingText.isEmpty &&
                  chat.streamingThinking.isEmpty &&
                  !hasPhase1)
                const _MiniLoading(),
              if (phase1Visible) const _MiniLoading(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThinkingBox(String thinking) {
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
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology, size: 14, color: Color(0xFF999999)),
              SizedBox(width: 4),
              Text(
                '思考中...',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            thinking,
            maxLines: 8,
            style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
          ),
        ],
      ),
    );
  }

  Widget _buildContentBox(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(
          fontSize: 13,
          color: Color(0xFF333333),
          height: 1.5,
        ),
      ),
    );
  }
}

class _MiniLoading extends StatelessWidget {
  const _MiniLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF4D6BFE),
        ),
      ),
    );
  }
}
