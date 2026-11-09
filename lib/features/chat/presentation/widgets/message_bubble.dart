// lib/views/widgets/message_bubble.dart
// 消息气泡组件 — 独立渲染层，流式更新时仅受影响的消息重绘

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../domain/chat_message.dart';
import '../markdown_cleaner.dart';
import 'search_sources_card.dart';

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
  // 搜索来源的展开/收起状态由 SearchSourcesCard 自己管（它同时用于流式回答区）

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isUser = widget.message.isUser;

    // 气泡的两个槽位：复选框（仅编辑模式）+ 内容
    final rowChildren = <Widget>[
      if (widget.isEditMode && !isUser) _buildCheckbox(p),
      Flexible(
        child: GestureDetector(
          onTap: widget.isEditMode ? widget.onToggleSelection : null,
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!isUser && widget.message.thinkingText != null) ...[
                _buildThinkingSection(p),
                const SizedBox(height: 6),
              ],
              _buildBubble(p),
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
                          color: p.surfaceMuted,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '···',
                          style: TextStyle(
                            fontSize: 12,
                            color: p.textTertiary,
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
      if (widget.isEditMode && isUser) _buildCheckbox(p),
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

  Widget _buildBubble(AppPalette p) {
    final isUser = widget.message.isUser;
    // 助手回复的 Markdown 在展示层清洗成纯文本（用户自己输入的原样显示）
    final text = isUser
        ? widget.message.content
        : stripMarkdownForChat(widget.message.content);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isUser ? p.bubbleUser : p.bubbleAssistant,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: isUser ? const Radius.circular(12) : Radius.zero,
          bottomRight: isUser ? Radius.zero : const Radius.circular(12),
        ),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 13,
          color: isUser ? p.bubbleUserText : p.bubbleAssistantText,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildThinkingSection(AppPalette p) {
    return GestureDetector(
      onTap: () => setState(() => _showThinking = !_showThinking),
      child: Container(
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
                  '思考过程',
                  style: TextStyle(fontSize: 11, color: p.textTertiary),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showThinking
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14,
                  color: p.textTertiary,
                ),
              ],
            ),
            if (_showThinking) ...[
              const SizedBox(height: 6),
              SelectableText(
                stripMarkdownForChat(widget.message.thinkingText!),
                style: TextStyle(fontSize: 11, color: p.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultsSection() {
    return SearchSourcesCard(
      results: widget.message.searchResults!,
      collapsible: true,
    );
  }

  Widget _buildCheckbox(AppPalette p) {
    return Container(
      alignment: Alignment.center,
      padding: EdgeInsets.only(
        left: widget.message.isUser ? 8 : 0,
        right: widget.message.isUser ? 0 : 8,
      ),
      child: SizedBox(
        width: 24,
        height: 24,
        child: Checkbox(
          value: widget.isSelected,
          onChanged: (_) => widget.onToggleSelection?.call(),
          activeColor: p.accent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
