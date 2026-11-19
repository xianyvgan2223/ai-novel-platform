// 聊天气泡里的 Markdown 渲染。
//
// 模型输出本身带 Markdown（标题、列表、表格、代码块、加粗等），此前展示层用
// stripMarkdownForChat 把标记全部擦掉，气泡里只剩纯文本；现在气泡直接渲染
// Markdown，复制到剪贴板时仍走 markdown_cleaner 的纯文本清洗。
//
// 样式全部取自 AppPalette，浅色 / 深色主题共用同一套排版：
// - 正文 13sp / 1.5 行高，与原来的聊天气泡字号一致；
// - 行内代码与代码块用等宽字体 + surfaceMuted 底；
// - 表格窄屏时横向滚动，避免撑破气泡。
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../../core/theme/app_palette.dart';

/// 聊天气泡的 Markdown 视图。
///
/// [selectable] 默认开启，保留原来长按选中 / 复制气泡文字的能力；
/// [textColor] / [fontSize] 用来让主气泡、思考过程和迷你面板共用这套渲染。
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown(
    this.data, {
    super.key,
    this.textColor,
    this.fontSize = 12,
    this.selectable = true,
  });

  final String data;
  final Color? textColor;
  final double fontSize;
  final bool selectable;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  // 样式在依赖变化时重建一次即可。MarkdownBody 用 `styleSheet` 的实例身份
  // 判断是否需要重新解析 Markdown；如果每次 build 都新建样式，流式分片会把
  // 整段文本重复解析一遍。这里把实例缓存下来，只有主题 / 字号变化才更新。
  MarkdownStyleSheet? _styleSheet;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _styleSheet = _buildStyleSheet(context);
  }

  @override
  void didUpdateWidget(ChatMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textColor != widget.textColor ||
        oldWidget.fontSize != widget.fontSize) {
      _styleSheet = _buildStyleSheet(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: widget.data,
      selectable: widget.selectable,
      styleSheet: _styleSheet,
      // 模型的输出经常用单个换行分行；Markdown 默认会把段内软换行折叠成
      // 一个空格（两行粘成一行）。聊天里保留换行更接近模型原意。
      softLineBreak: true,
    );
  }

  MarkdownStyleSheet _buildStyleSheet(BuildContext context) {
    final p = context.palette;
    final base = TextStyle(
      fontSize: widget.fontSize,
      height: 1.5,
      color: widget.textColor ?? p.bubbleAssistantText,
    );
    final codeBg = p.surfaceMuted;

    return MarkdownStyleSheet(
      p: base,
      a: base.copyWith(
        color: p.accent,
        decoration: TextDecoration.underline,
        decorationColor: p.accent,
      ),
      // 按需求使用黑色粗体、不加蓝色。中文系统字体没有 Bold 字重时 Flutter 会
      // 合成粗体；正文已从 13sp 收到 12sp，观感比之前轻一些。
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      del: base.copyWith(decoration: TextDecoration.lineThrough),
      code: base.copyWith(
        fontFamily: 'monospace',
        fontSize: widget.fontSize - 1,
        backgroundColor: codeBg,
      ),
      h1: base.copyWith(
        fontSize: widget.fontSize + 5,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
      h2: base.copyWith(
        fontSize: widget.fontSize + 3,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
      h3: base.copyWith(
        fontSize: widget.fontSize + 1.5,
        fontWeight: FontWeight.w500,
        height: 1.4,
      ),
      h4: base.copyWith(
        fontSize: widget.fontSize + 0.5,
        fontWeight: FontWeight.w500,
        height: 1.4,
      ),
      h5: base.copyWith(fontWeight: FontWeight.w500),
      h6: base.copyWith(
        fontSize: widget.fontSize - 0.5,
        fontWeight: FontWeight.w500,
        color: p.textSecondary,
      ),
      blockquote: base.copyWith(color: p.textSecondary),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      blockquoteDecoration: BoxDecoration(
        color: codeBg,
        border: Border(left: BorderSide(color: p.border, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      blockSpacing: 5,
      listIndent: 16,
      listBullet: base,
      listBulletPadding: const EdgeInsets.only(right: 6),
      tableHead: base.copyWith(fontWeight: FontWeight.w500),
      tableBody: base,
      tableBorder: TableBorder.all(color: p.border, width: 0.8),
      // 窄屏时让表格横向滚动，而不是把聊天气泡撑出屏幕。
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableScrollbarThumbVisibility: false,
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      tableHeadCellsPadding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 4,
      ),
      tableHeadCellsDecoration: BoxDecoration(color: codeBg),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.border)),
      ),
    );
  }
}
