// lib/views/widgets/message_bubble.dart
// 消息气泡组件 — 独立渲染层，流式更新时仅受影响的消息重绘

import 'package:flutter/material.dart';
import '../../domain/chat_message.dart';

/// 搜索详情弹窗
void showSearchDetailDialog(
  BuildContext context,
  String title,
  String url,
  String snippet,
  String content,
) {
  final buffer = StringBuffer();
  if (title.isNotEmpty) buffer.writeln('标题：$title');
  if (url.isNotEmpty) buffer.writeln('链接：$url');
  if (snippet.isNotEmpty) buffer.writeln('\n摘要：\n$snippet');
  if (content.isNotEmpty) buffer.writeln('\n正文：\n$content');
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('搜索详情', style: TextStyle(fontSize: 14)),
      content: SingleChildScrollView(
        child: SelectableText(
          buffer.toString(),
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭', style: TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

/// 消息气泡组件（带 RepaintBoundary 独立渲染层）
class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isEditMode;
  final bool isSelected;
  final VoidCallback? onEditRequested;
  final VoidCallback? onToggleSelection;

  const MessageBubble({
    super.key,
    required this.message,
    this.isEditMode = false,
    this.isSelected = false,
    this.onEditRequested,
    this.onToggleSelection,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _showThinking = false;
  bool _showSearchResults = false;

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.isUser;

    // 气泡的两个槽位：复选框（仅编辑模式）+ 内容
    final rowChildren = <Widget>[
      if (widget.isEditMode && !isUser) _buildCheckbox(),
      Flexible(
        child: GestureDetector(
          onTap: widget.isEditMode ? widget.onToggleSelection : null,
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!isUser && widget.message.thinkingText != null) ...[
                _buildThinkingSection(),
                const SizedBox(height: 6),
              ],
              _buildBubble(),
              if (!isUser && widget.message.searchResults != null) ...[
                const SizedBox(height: 8),
                _buildSearchResultsSection(),
              ],
              if (!widget.isEditMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: InkWell(
                      onTap: widget.onEditRequested,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0F0F0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '···',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      if (widget.isEditMode && isUser) _buildCheckbox(),
    ];

    // IntrinsicHeight 的唯一用途是把复选框撑到气泡高度，代价是每次布局都要为
    // 整棵子树多跑一遍 intrinsic 预测量。键盘弹出动画期间，Scaffold 会因
    // viewInsets 变化逐帧调整 body 高度，每个可见气泡因此每帧重新布局一次；
    // 60Hz 的 16.6ms 预算勉强够用，120Hz 只有 8.3ms，于是掉帧。
    // 非编辑模式下 Row 只剩 Flexible 一个子节点，此时 start 与 stretch 的
    // 布局结果完全一致（Row 高度即该子节点高度），可以直接跳过 IntrinsicHeight。
    final bubbleRow = widget.isEditMode
        ? IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rowChildren,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rowChildren,
          );

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.widthOf(context) * 0.8,
            ),
            child: bubbleRow,
          ),
        ),
      ),
    );
  }

  Widget _buildBubble() {
    final isUser = widget.message.isUser;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isUser
            ? const Color(0xFF4D6BFE)
            : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: isUser ? const Radius.circular(12) : Radius.zero,
          bottomRight: isUser ? Radius.zero : const Radius.circular(12),
        ),
      ),
      child: SelectableText(
        widget.message.content,
        style: TextStyle(
          fontSize: 13,
          color: isUser ? Colors.white : const Color(0xFF333333),
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildThinkingSection() {
    return GestureDetector(
      onTap: () => setState(() => _showThinking = !_showThinking),
      child: Container(
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
                const Text('思考过程',
                  style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showThinking
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14, color: const Color(0xFF999999),
                ),
              ],
            ),
            if (_showThinking) ...[
              const SizedBox(height: 6),
              SelectableText(
                widget.message.thinkingText!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultsSection() {
    final results = widget.message.searchResults!;
    return GestureDetector(
      onTap: () => setState(() => _showSearchResults = !_showSearchResults),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFE8EEFF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFB3C5FF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.public, size: 14, color: Color(0xFF4D6BFE)),
                const SizedBox(width: 4),
                const Text('搜索来源',
                  style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                ),
                const Spacer(),
                Icon(
                  _showSearchResults
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14, color: const Color(0xFF4D6BFE),
                ),
              ],
            ),
            if (_showSearchResults) ...[
              const SizedBox(height: 6),
              ...results.take(5).map((r) {
                final title = r['name']?.toString() ?? r['title']?.toString() ?? '';
                final url = r['url']?.toString() ?? r['link']?.toString() ?? '';
                final snippet = r['snippet']?.toString() ?? '';
                final content = r['content']?.toString() ?? '';
                return GestureDetector(
                  onTap: () => showSearchDetailDialog(
                    context, title, url, snippet, content,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                          style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600,
                            color: Color(0xFF333333),
                          ),
                        ),
                        if (snippet.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(snippet,
                              style: const TextStyle(
                                fontSize: 10, color: Color(0xFF666666),
                              ),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (url.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(url,
                              style: const TextStyle(
                                fontSize: 9, color: Color(0xFF4D6BFE),
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCheckbox() {
    return Container(
      alignment: Alignment.center,
      padding: EdgeInsets.only(
        left: widget.message.isUser ? 8 : 0,
        right: widget.message.isUser ? 0 : 8,
      ),
      child: SizedBox(
        width: 24, height: 24,
        child: Checkbox(
          value: widget.isSelected,
          onChanged: (_) => widget.onToggleSelection?.call(),
          activeColor: const Color(0xFF4D6BFE),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
