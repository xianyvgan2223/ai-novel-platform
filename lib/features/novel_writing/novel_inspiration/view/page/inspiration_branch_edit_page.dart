// 小说灵感 — 单个推演的正文编辑页
//
// 黑白极简：正文直接铺开，不做输入框卡片；字号更小、行距更松。
// 选中一段文字后可让 AI 只改写这一段。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../widget/inspiration_theme.dart';

class InspirationBranchEditPage extends StatefulWidget {
  const InspirationBranchEditPage({
    super.key,
    required this.controller,
    required this.branch,
  });

  final InspirationController controller;
  final InspirationBranch branch;

  @override
  State<InspirationBranchEditPage> createState() =>
      _InspirationBranchEditPageState();
}

class _InspirationBranchEditPageState extends State<InspirationBranchEditPage> {
  late final TextEditingController _textCtrl;
  bool _saving = false;
  bool _hasSelection = false;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.branch.content);
    _textCtrl.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_onSelectionChanged);
    _textCtrl.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    final sel = _textCtrl.selection;
    final has =
        sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= _textCtrl.text.length;
    if (has != _hasSelection) setState(() => _hasSelection = has);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.controller.updateBranchContent(
      widget.branch.id!,
      _textCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
  }

  Future<void> _rewriteSelection() async {
    final sel = _textCtrl.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final start = sel.start;
    final end = sel.end;
    final selected = _textCtrl.text.substring(start, end).trim();
    if (selected.isEmpty) return;
    // 先收起系统文本选择菜单与焦点：选择浮层还挂着时 push 新路由，
    // 关闭时容易触发 InheritedElement 的 dependents 断言。
    FocusScope.of(context).unfocus();
    _textCtrl.selection = TextSelection.collapsed(offset: end);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SegmentRewriteSheet(
        controller: widget.controller,
        fullText: _textCtrl.text,
        selectedText: selected,
      ),
    );
    if (!mounted || result == null || result.trim().isEmpty) return;
    final next = _textCtrl.text.replaceRange(start, end, result.trim());
    _textCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + result.trim().length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final count = _textCtrl.text.characters.length;
    return InspirationTheme(
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_rounded,
              size: 20,
              color: p.textPrimary,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            '编辑',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: p.textTertiary,
                      ),
                    )
                  : Text(
                      '保存',
                      style: TextStyle(fontSize: 13, color: p.textPrimary),
                    ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                child: TextField(
                  controller: _textCtrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: TextStyle(
                    fontSize: 12.6,
                    height: 1.72,
                    color: p.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '正文',
                    hintStyle: TextStyle(fontSize: 12.5, color: p.textTertiary),
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.border)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '$count 字',
                        style: TextStyle(fontSize: 10, color: p.textTertiary),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _hasSelection ? _rewriteSelection : null,
                        style: TextButton.styleFrom(
                          foregroundColor: p.textPrimary,
                          disabledForegroundColor: p.textTertiary,
                          visualDensity: VisualDensity.compact,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                        icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                        label: const Text(
                          '改写选中',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 对话式段落改写面板：可连续提要求、查看多版结果，选一版替换回原文。
class _SegmentRewriteSheet extends StatefulWidget {
  const _SegmentRewriteSheet({
    required this.controller,
    required this.fullText,
    required this.selectedText,
  });

  final InspirationController controller;
  final String fullText;
  final String selectedText;

  @override
  State<_SegmentRewriteSheet> createState() => _SegmentRewriteSheetState();
}

class _SegmentRewriteSheetState extends State<_SegmentRewriteSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<({String instruction, String result})> _turns = [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    final raw = _input.text.trim();
    _input.clear();
    setState(() {
      _busy = true;
      _error = null;
    });
    _scrollToBottom();
    try {
      final result = await widget.controller.rewriteSegmentChat(
        fullText: widget.fullText,
        selectedText: widget.selectedText,
        turns: List.of(_turns),
        instruction: raw,
      );
      if (!mounted) return;
      if (result.trim().isEmpty) {
        setState(() => _error = '没有生成内容，请再试一次');
      } else {
        setState(() {
          _turns.add((
            instruction: raw.isEmpty ? '直接改写' : raw,
            result: result.trim(),
          ));
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '生成失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scrollToBottom();
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return InspirationTheme(
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.78,
        decoration: BoxDecoration(
          color: p.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: EdgeInsets.only(bottom: bottom),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                child: Row(
                  children: [
                    Text(
                      '段落改写',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: p.textTertiary,
                      ),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: p.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.selectedText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: p.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: _turns.isEmpty && !_busy
                    ? Center(
                        child: Text(
                          '说说想怎么改；直接发送也可以',
                          style: TextStyle(fontSize: 12, color: p.textTertiary),
                        ),
                      )
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                        children: [
                          for (var i = 0; i < _turns.length; i++) ...[
                            Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.sizeOf(context).width * 0.72,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: p.bubbleUser,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  _turns[i].instruction,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                    color: p.bubbleUserText,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                              decoration: BoxDecoration(
                                color: p.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: p.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _turns[i].result,
                                    style: TextStyle(
                                      fontSize: 12.2,
                                      height: 1.7,
                                      color: p.textPrimary,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed:
                                          i == _turns.length - 1 && !_busy
                                          ? () {
                                              FocusScope.of(context).unfocus();
                                              Navigator.of(
                                                context,
                                              ).pop(_turns[i].result);
                                            }
                                          : null,
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        minimumSize: Size.zero,
                                        foregroundColor: p.textPrimary,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                      ),
                                      child: const Text(
                                        '替换选中段落',
                                        style: TextStyle(fontSize: 10.5),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                          ],
                          if (_busy)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: p.surface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: p.border),
                                ),
                                child: Text(
                                  '生成中…',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: p.textTertiary,
                                  ),
                                ),
                              ),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: p.danger,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: p.surface,
                  border: Border(top: BorderSide(color: p.border)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 3,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: p.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: '描述改写方向（可留空）',
                          hintStyle: TextStyle(
                            fontSize: 12,
                            color: p.textTertiary,
                          ),
                          filled: true,
                          fillColor: p.surfaceMuted,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: p.borderStrong),
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: FilledButton(
                        onPressed: _busy ? null : _send,
                        style: FilledButton.styleFrom(
                          backgroundColor: p.textPrimary,
                          foregroundColor: p.surface,
                          disabledBackgroundColor: p.surfaceMuted,
                          padding: EdgeInsets.zero,
                          shape: const CircleBorder(),
                        ),
                        child: const Icon(Icons.arrow_upward_rounded, size: 17),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
