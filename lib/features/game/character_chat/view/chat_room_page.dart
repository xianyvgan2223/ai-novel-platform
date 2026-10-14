// lib/game/character_chat/view/chat_room_page.dart
// 聊天室页面 — 与角色进行对话

import 'package:flutter/material.dart';
import '../../../../core/widgets/keyboard_inset_padding.dart';
import '../controller/chat_controller.dart';
import '../model/character_model.dart';

class ChatRoomPage extends StatefulWidget {
  final CharacterChatController controller;
  final CharacterModel? character;
  final int? sessionId;

  const ChatRoomPage({
    super.key,
    required this.controller,
    required this.character,
    this.sessionId,
  });

  /// 从已有会话恢复
  const ChatRoomPage.fromSession({
    super.key,
    required this.controller,
    required this.sessionId,
  }) : character = null;

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _isNearBottom = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onDataChanged);
    _scrollCtrl.addListener(_onScrollChanged);
    if (widget.character != null) {
      widget.controller.selectCharacter(widget.character!);
    } else if (widget.sessionId != null) {
      widget.controller.loadSession(widget.sessionId!);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onDataChanged);
    _scrollCtrl.removeListener(_onScrollChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _onScrollChanged() {
    if (_scrollCtrl.hasClients) {
      final maxScroll = _scrollCtrl.position.maxScrollExtent;
      _isNearBottom = (maxScroll - _scrollCtrl.position.pixels) < 100;
    }
  }

  void _scrollToBottom() {
    if (_isNearBottom && _scrollCtrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _onSend() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty || widget.controller.isLoading) return;
    _inputCtrl.clear();
    widget.controller.sendMessage(text);
  }

  void _showWorldBookSheet() {
    final ctrl = widget.controller;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // useSafeArea 走 SafeArea 而不是框架内部的 MediaQuery.removePadding：
      // 后者是全字段依赖，会让这个面板的 builder 在键盘动画期间被逐帧重新调用。
      // 这里 bottom 本来就是 false，视觉上无差别。
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            ctrl.addListener(() {
              if (mounted) setSheetState(() {});
            });
            // 键盘 inset 交给 KeyboardInsetPadding 去读：留在这里的话，
            // 本 builder 的 Element 会订阅 viewInsets，键盘动画每帧重跑，
            // 下面整棵面板内容跟着每帧重建。Column 作为 child 传进去后，
            // 每帧只有 KeyboardInsetPadding 自己那一层重建。
            return KeyboardInsetPadding(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDDDDD),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '世界书管理',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0xFFEEEEEE)),
                  if (ctrl.worldEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '暂无条目',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF999999),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: ctrl.worldEntries.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        itemBuilder: (_, i) {
                          final entry = ctrl.worldEntries[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.title,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF333333),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '关键词: ${entry.keywords.join(', ')}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF999999),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: () {
                                    ctrl.removeWorldEntry(entry.id!);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const Divider(height: 1, color: Color(0xFFEEEEEE)),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _showAddEntryDialog(ctx),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text(
                          '添加条目',
                          style: TextStyle(fontSize: 13),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4D6BFE),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAddEntryDialog(BuildContext sheetContext) {
    final titleCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final keywordsCtrl = TextEditingController();

    showDialog(
      context: sheetContext,
      builder: (ctx) => AlertDialog(
        title: const Text('添加条目', style: TextStyle(fontSize: 14)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: '标题',
                  labelStyle: TextStyle(fontSize: 13),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '内容',
                  labelStyle: TextStyle(fontSize: 13),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keywordsCtrl,
                decoration: const InputDecoration(
                  labelText: '关键词（逗号分隔）',
                  labelStyle: TextStyle(fontSize: 13),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () {
              final title = titleCtrl.text.trim();
              final content = contentCtrl.text.trim();
              final keywordsStr = keywordsCtrl.text.trim();
              if (title.isEmpty) return;
              final keywords = keywordsStr.isEmpty
                  ? <String>[]
                  : keywordsStr
                        .split(',')
                        .map((k) => k.trim())
                        .where((k) => k.isNotEmpty)
                        .toList();
              widget.controller.addWorldEntry(title, content, keywords);
              Navigator.of(ctx).pop();
            },
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 13, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    ).then((_) {
      titleCtrl.dispose();
      contentCtrl.dispose();
      keywordsCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final character = ctrl.character;
    final messages = ctrl.messages;
    final isLoading = ctrl.isLoading;
    final error = ctrl.error;
    final summary = ctrl.summary;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8F8F8),
        appBar: _buildAppBar(character),
        body: Column(
          children: [
            if (error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                color: const Color(0xFFFFEBEE),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 14,
                      color: Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error,
                        style: const TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _buildMessageList(
                messages,
                isLoading,
                character?.name ?? '',
              ),
            ),
            if (summary != null && summary.isNotEmpty) _buildSummaryBar(),
            _buildInputArea(isLoading),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar() {
    return Container(
      width: double.infinity,
      height: 28,
      color: const Color(0xFFFFF9E6),
      alignment: Alignment.center,
      child: const Text(
        '早期对话已压缩为摘要',
        style: TextStyle(fontSize: 11, color: Color(0xFF997A00)),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(CharacterModel? character) {
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20, color: Color(0xFF333333)),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFF4D6BFE).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(13),
            ),
            alignment: Alignment.center,
            child: Text(
              character?.name.characters.first ?? '?',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4D6BFE),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            character?.name ?? '',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.menu_book, size: 20, color: Color(0xFF333333)),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: _showWorldBookSheet,
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
      ),
    );
  }

  Widget _buildMessageList(
    List<ChatMessage> messages,
    bool isLoading,
    String charName,
  ) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: messages.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          return _MessageBubble(
            message: messages[index],
            isCharacter: !messages[index].isUser,
            charName: charName,
            controller: widget.controller,
            messageIndex: index,
          );
        }
        return const _TypingIndicator();
      },
    );
  }

  Widget _buildInputArea(bool isLoading) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
                decoration: InputDecoration(
                  hintText: '说点什么...',
                  hintStyle: const TextStyle(
                    color: Color(0xFFBBBBBB),
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _onSend(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: isLoading ? widget.controller.cancelRequest : _onSend,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isLoading ? Colors.redAccent : const Color(0xFF4D6BFE),
                  borderRadius: BorderRadius.circular(17),
                ),
                alignment: Alignment.center,
                child: Icon(
                  isLoading ? Icons.stop : Icons.arrow_upward,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息气泡
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isCharacter;
  final String charName;
  final CharacterChatController controller;
  final int messageIndex;

  const _MessageBubble({
    required this.message,
    required this.isCharacter,
    required this.charName,
    required this.controller,
    required this.messageIndex,
  });

  bool get _canSwipe =>
      isCharacter && controller.candidateCount(messageIndex) > 1;

  int get _candidateCount => controller.candidateCount(messageIndex);

  int get _currentIndex => controller.currentCandidateIndex(messageIndex);

  @override
  Widget build(BuildContext context) {
    final bubble = Column(
      crossAxisAlignment: isCharacter
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        // 角色名和时间戳
        Padding(
          padding: EdgeInsets.only(
            left: isCharacter ? 4 : 0,
            right: isCharacter ? 0 : 4,
            bottom: 3,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCharacter)
                Text(
                  charName,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
              if (isCharacter) const SizedBox(width: 8),
              Text(
                _formatTime(message.timestamp),
                style: const TextStyle(fontSize: 9, color: Color(0xFFBBBBBB)),
              ),
              if (!isCharacter) const SizedBox(width: 8),
              if (!isCharacter)
                const Text(
                  '你',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF666666),
                  ),
                ),
            ],
          ),
        ),
        // 气泡
        Align(
          alignment: isCharacter ? Alignment.centerLeft : Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.widthOf(context) * 0.78,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isCharacter ? Colors.white : const Color(0xFF4D6BFE),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isCharacter ? 4 : 14),
                  topRight: Radius.circular(isCharacter ? 14 : 4),
                  bottomLeft: const Radius.circular(14),
                  bottomRight: const Radius.circular(14),
                ),
                boxShadow: isCharacter
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: SelectableText(
                message.content,
                style: TextStyle(
                  fontSize: 13,
                  color: isCharacter ? const Color(0xFF333333) : Colors.white,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
        // 滑动指示圆点 - 仅 AI 消息且有多候选时显示
        if (_canSwipe) ...[const SizedBox(height: 6), _buildDotIndicator()],
      ],
    );

    if (_canSwipe) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity != null) {
              if (details.primaryVelocity! > 0) {
                // 右滑 -> 上一条
                controller.swipePrev(messageIndex);
              } else {
                // 左滑 -> 下一条
                controller.swipeNext(messageIndex);
              }
            }
          },
          child: bubble,
        ),
      );
    }

    return Padding(padding: const EdgeInsets.only(bottom: 10), child: bubble);
  }

  Widget _buildDotIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_candidateCount, (i) {
        return Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i == _currentIndex
                ? const Color(0xFF4D6BFE)
                : const Color(0xFFBBBBBB),
          ),
        );
      }),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 输入指示器
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _dot(0),
                  const SizedBox(width: 4),
                  _dot(400),
                  const SizedBox(width: 4),
                  _dot(800),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(int delay) {
    return SizedBox(
      width: 6,
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF999999),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
