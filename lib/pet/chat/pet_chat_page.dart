// lib/pet/chat/pet_chat_page.dart
// 宠物聊天页面 — 可与宠物对话，聊天情绪联动宠物状态

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/pet_provider.dart';
import '../pet_state.dart';
import 'pet_chat_controller.dart';
import '../../memo/memo_page.dart';
import '../../views/widgets/pet_floating_ball.dart';
import '../adventure/adventure_page.dart';

/// 宠物聊天 Provider
final petChatProvider = ChangeNotifierProvider<PetChatController>(
  (ref) => PetChatController(ref.read(petProvider.notifier)),
);

class PetChatPage extends ConsumerStatefulWidget {
  const PetChatPage({super.key});

  @override
  ConsumerState<PetChatPage> createState() => _PetChatPageState();
}

class _PetChatPageState extends ConsumerState<PetChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  int _lastMessageCount = 0;
  bool _isNearBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScrollChanged);
    // 初始化欢迎消息 + 检测离线
    Future.microtask(() {
      ref.read(petChatProvider).initWelcome();
      ref.read(petProvider.notifier).simulateOfflineDecay(2);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScrollChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onScrollChanged() {
    if (!_scrollCtrl.hasClients) return;
    final isNearBottom =
        (_scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels) <
        80;
    if (isNearBottom != _isNearBottom) {
      setState(() => _isNearBottom = isNearBottom);
    }
  }

  void _onSend() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _inputCtrl.clear();
    ref.read(petChatProvider).sendMessage(text);
    _lastMessageCount = ref.read(petChatProvider).messages.length;
    _scrollToBottom(animate: false);
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollCtrl.hasClients) return;
    if (animate) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  /// 当消息数量变化时自动滚到底部
  void _checkAutoScroll(int currentCount) {
    if (currentCount > _lastMessageCount && _isNearBottom) {
      _lastMessageCount = currentCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
    _lastMessageCount = currentCount;
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(petChatProvider);
    final pet = ref.watch(petProvider.select((s) => s.pet));
    final isLoading = chat.isLoading;
    final messages = chat.messages;
    final streamingText = chat.streamingText;

    // 检测消息变化自动滚动
    _checkAutoScroll(messages.length);

    return PopScope(
      canPop: true,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: const Color(0xFFF8F9FE),
            appBar: AppBar(
              toolbarHeight: 48,
              backgroundColor: Colors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                icon: const Icon(
                  Icons.arrow_back,
                  color: Color(0xFF333333),
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 宠物头像（带心情颜色）
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          _moodColor(pet.mood).withAlpha(160),
                          _moodColor(pet.mood),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.pets,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pet.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF333333),
                        ),
                      ),
                      Text(
                        'Lv.${pet.level} · ${pet.mood.label}',
                        style: TextStyle(
                          fontSize: 11,
                          color: _moodColor(pet.mood),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              centerTitle: false,
              actions: [
                IconButton(
                  icon: const Icon(
                    Icons.explore,
                    color: Color(0xFFE94560),
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  tooltip: '冒险',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AdventurePage()),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(
                    Icons.note_alt,
                    color: Color(0xFF333333),
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () {
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const MemoPage()));
                  },
                ),
              ],
              bottom: const PreferredSize(
                preferredSize: Size.fromHeight(1),
                child: Divider(height: 1, color: Color(0xFFEEEEEE)),
              ),
            ),
            body: Column(
              children: [
                Expanded(
                  child: _buildMessageList(messages, streamingText, isLoading),
                ),
                const Divider(height: 1, color: Color(0xFFEEEEEE)),
                _buildInputArea(isLoading),
              ],
            ),
          ),
          // 可拖拽悬浮宠物球
          PetFloatingBall(chatExpression: chat.currentExpression),
        ],
      ),
    );
  }

  Widget _buildMessageList(
    List<PetChatMessage> messages,
    String streamingText,
    bool isLoading,
  ) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: messages.length + (streamingText.isNotEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          final msg = messages[index];
          return RepaintBoundary(child: _buildMessageBubble(msg));
        }
        // 流式气泡
        return RepaintBoundary(child: _buildStreamingBubble(streamingText));
      },
    );
  }

  Widget _buildMessageBubble(PetChatMessage msg) {
    final isUser = msg.isUser;
    final isError = !isUser && msg.content.startsWith('呜呜~');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              // 思考过程指示器
              if (!isUser &&
                  msg.thinkingText != null &&
                  msg.thinkingText!.isNotEmpty)
                _buildThinkingBubble(),
              // 消息气泡
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isError
                      ? const Color(0xFFFFF3F0)
                      : isUser
                      ? const Color(0xFF6C63FF)
                      : Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: isUser
                        ? const Radius.circular(16)
                        : Radius.zero,
                    bottomRight: isUser
                        ? Radius.zero
                        : const Radius.circular(16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (isError
                                  ? Colors.red
                                  : isUser
                                  ? const Color(0xFF6C63FF)
                                  : Colors.black)
                              .withAlpha(8),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 错误标签
                    if (isError)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 12,
                              color: Color(0xFFE53935),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              '出错了',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFFE53935),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // 消息内容
                    SelectableText(
                      msg.content,
                      style: TextStyle(
                        fontSize: 14,
                        color: isError
                            ? const Color(0xFF333333)
                            : isUser
                            ? Colors.white
                            : const Color(0xFF333333),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              // 时间戳
              Padding(
                padding: EdgeInsets.only(
                  top: 4,
                  left: isUser ? 0 : 4,
                  right: isUser ? 4 : 0,
                ),
                child: Text(
                  _formatTime(msg.timestamp),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFBBBBBB),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStreamingBubble(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 思考指示
              _buildThinkingBubble(),
              // 流式消息气泡
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(8),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: SelectableText(
                        text,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF333333),
                          height: 1.5,
                        ),
                      ),
                    ),
                    // 打字光标动画
                    const _TypingCursor(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThinkingBubble() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6, left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F0FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE0E0FF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.psychology, size: 13, color: Color(0xFF6C63FF)),
          const SizedBox(width: 4),
          const Text(
            '小宠正在思考',
            style: TextStyle(fontSize: 11, color: Color(0xFF6C63FF)),
          ),
          const SizedBox(width: 2),
          _ThinkingDots(),
        ],
      ),
    );
  }

  Widget _buildInputArea(bool isLoading) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              focusNode: _inputFocus,
              enabled: !isLoading,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: isLoading ? '小宠正在思考...' : '和小宠说说话吧...',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFBBBBBB),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: isLoading ? null : (_) => _onSend(),
              maxLines: 4,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          // 发送/停止按钮
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isLoading ? Colors.redAccent : const Color(0xFF6C63FF),
              borderRadius: BorderRadius.circular(18),
            ),
            child: IconButton(
              onPressed: isLoading
                  ? () => ref.read(petChatProvider).cancelRequest()
                  : _onSend,
              icon: Icon(
                isLoading ? Icons.stop : Icons.arrow_upward,
                size: 18,
                color: Colors.white,
              ),
              padding: EdgeInsets.zero,
              splashRadius: 18,
              tooltip: isLoading ? '停止' : '发送',
            ),
          ),
        ],
      ),
    );
  }

  /// 格式化时间戳为 HH:mm 格式
  String _formatTime(String isoTime) {
    try {
      final dt = DateTime.parse(isoTime);
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
  }

  Color _moodColor(PetMood mood) {
    switch (mood) {
      case PetMood.happy:
        return const Color(0xFF4CAF50);
      case PetMood.normal:
        return const Color(0xFF6C63FF);
      case PetMood.tired:
        return const Color(0xFFFF9800);
      case PetMood.low:
        return const Color(0xFF9E9E9E);
    }
  }
}

/// 打字光标动画（闪烁竖线）
class _TypingCursor extends StatefulWidget {
  const _TypingCursor();

  @override
  State<_TypingCursor> createState() => _TypingCursorState();
}

class _TypingCursorState extends State<_TypingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: const Padding(
        padding: EdgeInsets.only(left: 2),
        child: Text(
          '▍',
          style: TextStyle(fontSize: 16, color: Color(0xFF6C63FF)),
        ),
      ),
    );
  }
}

/// 思考中点点点动画
class _ThinkingDots extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      '...',
      style: TextStyle(fontSize: 11, color: Color(0xFF6C63FF)),
    );
  }
}
