// lib/views/widgets/message_bubble.dart
// 消息气泡组件 — 独立渲染层，流式更新时仅受影响的消息重绘

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../domain/chat_message.dart';
import 'chat_markdown.dart';
import 'search_sources_card.dart';

/// 消息气泡组件（带 RepaintBoundary 独立渲染层）
class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isEditMode;
  final bool isSelected;

  /// 是否在「···」菜单里显示缓存命中（设置页「显示缓存命中」开关）。
  final bool showCacheHit;
  final VoidCallback? onEditRequested;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;
  final VoidCallback? onShowCache;

  const MessageBubble({
    super.key,
    required this.message,
    this.isEditMode = false,
    this.isSelected = false,
    this.showCacheHit = true,
    this.onEditRequested,
    this.onToggleSelection,
    this.onCopy,
    this.onDelete,
    this.onShowCache,
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
          // 长按也可以直接进入多选（和「···」菜单里的「多选」等价）
          onLongPress: widget.isEditMode ? null : widget.onEditRequested,
          child: Column(
            // 助手气泡占满列表可用宽度；用户气泡仍按内容宽度靠右。
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.stretch,
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
              // 每条消息右下角「···」：点开后显示 复制 / 删除 / 多选（助手多一项缓存命中）
              if (!widget.isEditMode)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: PopupMenuButton<String>(
                      tooltip: '更多操作',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 24,
                      ),
                      offset: const Offset(0, 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      onSelected: (value) {
                        switch (value) {
                          case 'copy':
                            widget.onCopy?.call();
                          case 'delete':
                            widget.onDelete?.call();
                          case 'select':
                            widget.onEditRequested?.call();
                          case 'cache':
                            widget.onShowCache?.call();
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(p, 'copy', Icons.copy_rounded, '复制'),
                        _menuItem(
                          p,
                          'delete',
                          Icons.delete_outline,
                          '删除',
                          danger: true,
                        ),
                        _menuItem(p, 'select', Icons.checklist_rounded, '多选'),
                        if (!isUser && widget.showCacheHit)
                          _menuItem(
                            p,
                            'cache',
                            Icons.bolt_rounded,
                            widget.message.cachePercent == null
                                ? '缓存命中 —'
                                : '缓存命中 ${widget.message.cachePercent}%',
                          ),
                      ],
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
              // 用户气泡最多占 80% 宽；助手气泡占满列表可用宽度
              // （列表左右各有 12dp 内边距，气泡不会真的贴到屏幕边缘）。
              maxWidth: isUser
                  ? MediaQuery.widthOf(context) * 0.8
                  : double.infinity,
            ),
            child: isUser
                ? bubbleRow
                : SizedBox(width: double.infinity, child: bubbleRow),
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(AppPalette p) {
    final isUser = widget.message.isUser;
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
      child: ChatMarkdown(
        widget.message.content,
        textColor: isUser ? p.bubbleUserText : p.bubbleAssistantText,
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
              ChatMarkdown(
                widget.message.thinkingText!,
                fontSize: 11,
                textColor: p.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultsSection() {
    return SearchSourcesCard(results: widget.message.searchResults!);
  }

  /// 「···」菜单里的一项：复制 / 删除 / 缓存命中
  PopupMenuItem<String> _menuItem(
    AppPalette p,
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: danger ? p.danger : p.textSecondary),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: danger ? p.danger : p.textPrimary,
            ),
          ),
        ],
      ),
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
