// 小说灵感 — 主页面
//
// 黑白极简：一次指令并行生成多个推演，所有推演收在同一个气泡里，用气泡内的
// 版本切换查看；顶部可查看 AI 当前会看到的全部内容（设定 / 大纲事件 / 人物卡 /
// 已采用剧情）。页面内不再堆叠说明性提示。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../../outline_editing/view/page/outline_edit_chapter_list_page.dart';
import '../../../outline_editing/view/page/outline_edit_novel_list_page.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../widget/inspiration_history_drawer.dart';
import '../widget/inspiration_theme.dart';
import 'inspiration_branch_edit_page.dart';
import 'inspiration_character_cards_page.dart';
import 'inspiration_context_page.dart';
import 'inspiration_settings_page.dart';
import 'inspiration_world_theme_edit_page.dart';

class NovelInspirationPage extends StatefulWidget {
  const NovelInspirationPage({super.key});

  @override
  State<NovelInspirationPage> createState() => _NovelInspirationPageState();
}

enum _InspirationMode { chat, deduction }

class _NovelInspirationPageState extends State<NovelInspirationPage> {
  final InspirationController _controller = InspirationController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _inlineCtrl = TextEditingController();
  final FocusNode _inlineFocus = FocusNode();
  int? _editingMessageId;
  _InspirationMode _mode = _InspirationMode.deduction;
  int? _viewRevisionMessageId;
  int? _viewRevisionIndex;

  /// messageId → 当前在气泡内查看的推演下标
  final Map<int, int> _activeVersion = {};
  final Map<int, int> _lastBranchCount = {};

  int _lastMessageCount = 0;
  int _lastChatCount = 0;
  int? _lastDraftMessageId;
  int? _lastSessionId;
  bool _lastBusy = false;
  bool _lastChatGenerating = false;
  String? _lastErrorShown;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _controller.init();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inlineCtrl.dispose();
    _inlineFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _syncVersions();
    setState(() {});
    final sessionId = _controller.session?.id;
    if (sessionId != _lastSessionId) {
      _lastSessionId = sessionId;
      _activeVersion.clear();
      _lastBranchCount.clear();
    }
    final countChanged = _controller.messages.length != _lastMessageCount;
    final chatCountChanged = _controller.chatMessages.length != _lastChatCount;
    final draftStarted =
        _controller.hasDraft &&
        _controller.draftMessageId != _lastDraftMessageId;
    _lastMessageCount = _controller.messages.length;
    _lastChatCount = _controller.chatMessages.length;
    _lastDraftMessageId = _controller.draftMessageId;
    final busyChanged = _controller.busy != _lastBusy;
    _lastBusy = _controller.busy;
    final chatGeneratingChanged =
        _controller.chatGenerating != _lastChatGenerating;
    _lastChatGenerating = _controller.chatGenerating;
    if (countChanged ||
        chatCountChanged ||
        draftStarted ||
        busyChanged ||
        chatGeneratingChanged) {
      _scheduleScrollToBottom();
    }
    final err = _controller.errorText;
    if (err != null && err != _lastErrorShown) {
      _lastErrorShown = err;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSnack(err);
      });
    } else if (err == null) {
      _lastErrorShown = null;
    }
  }

  /// 新推演生成后自动切到最新一版；首次加载默认采用项。
  void _syncVersions() {
    for (final msg in _controller.messages) {
      final id = msg.id;
      if (id == null) continue;
      final count = msg.branches.length;
      final prev = _lastBranchCount[id] ?? 0;
      if (count > 0) {
        if (prev > 0 && count > prev) {
          _activeVersion[id] = count - 1;
        } else if (!_activeVersion.containsKey(id)) {
          final chosen = msg.branches.indexWhere((b) => b.chosen);
          _activeVersion[id] = chosen >= 0 ? chosen : 0;
        }
      }
      if (_activeVersion[id] != null && count > 0) {
        _activeVersion[id] = _activeVersion[id]!.clamp(0, count - 1);
      }
      _lastBranchCount[id] = count;
    }
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _controller.busy) return;
    _inputCtrl.clear();
    await _controller.send(text);
    _scheduleScrollToBottom();
  }

  Future<void> _sendChat() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _controller.chatGenerating) return;
    _inputCtrl.clear();
    await _controller.sendChat(text);
    _scheduleScrollToBottom();
  }

  Future<void> _sendCurrent() async {
    if (_mode == _InspirationMode.chat) {
      await _sendChat();
    } else {
      await _send();
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _ensureSession() async {
    if (_controller.session?.id == null) {
      await _controller.newSession();
    }
  }

  // ── 菜单 / 查看 ─────────────────────────────────────────────

  Future<void> _openImportOutline() async {
    await _ensureSession();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OutlineEditNovelListPage(
          title: '导入大纲',
          hint: '选择要注入灵感的作品',
          emptyTitle: '还没有可用的大纲',
          emptyHint: '请先在「一键生成大纲」里创建作品',
          mutedAccent: true,
          onOpenNovel: (ctx, outline) async {
            final picked = await Navigator.of(ctx)
                .push<
                  List<
                    ({
                      OutlineChapter chapter,
                      int? majorNumber,
                      int? minorNumber,
                    })
                  >
                >(
                  MaterialPageRoute(
                    builder: (_) => OutlineEditChapterListPage(
                      outline: outline,
                      pickerMode: true,
                    ),
                  ),
                );
            if (picked == null || !ctx.mounted) return;
            final events = picked
                .map(
                  (p) => InspirationOutlineEvent(
                    chapterId: p.chapter.id,
                    type: p.chapter.eventType,
                    title: p.chapter.eventTitle,
                    summary: p.chapter.eventSummary,
                    majorNumber: p.majorNumber,
                    minorNumber: p.minorNumber,
                  ),
                )
                .toList();
            await _controller.saveOutlineSelection(
              outlineRecordId: outline.id!,
              outlineTitle: outline.title,
              events: events,
            );
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openCharacterCards() async {
    await _ensureSession();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspirationCharacterCardsPage(controller: _controller),
      ),
    );
  }

  Future<void> _openWorldTheme() async {
    await _ensureSession();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspirationWorldThemeEditPage(controller: _controller),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspirationSettingsPage(controller: _controller),
      ),
    );
  }

  void _openContext() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspirationContextPage(controller: _controller),
      ),
    );
  }

  // ── 推演操作 ───────────────────────────────────────────────

  void _editBranch(InspirationBranch branch) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            InspirationBranchEditPage(controller: _controller, branch: branch),
      ),
    );
  }

  Future<void> _confirmDeleteMessage(InspirationMessage message) async {
    final p = inspirationPalette(context.palette);
    final id = message.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          '删除这一轮？',
          style: TextStyle(fontSize: 15, color: p.textPrimary),
        ),
        content: Text(
          '本轮指令和全部推演都会删除。',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: p.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: p.textPrimary)),
          ),
        ],
      ),
    );
    if (ok == true) await _controller.deleteMessage(id);
  }

  /// 长按对话：修改并重新生成本轮 / 查看从该轮开始的下文 / 删除本轮。
  Future<void> _showMessageActions(InspirationMessage message) async {
    final p = inspirationPalette(context.palette);
    final index = _controller.messages.indexOf(message);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => InspirationTheme(
        child: Container(
          decoration: BoxDecoration(
            color: p.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _actionItem(ctx, p, 'edit', Icons.edit_outlined, '修改对话'),
                _actionItem(
                  ctx,
                  p,
                  'continue',
                  Icons.article_outlined,
                  '查看下文',
                  enabled: index >= 0,
                ),
                _actionItem(
                  ctx,
                  p,
                  'delete',
                  Icons.delete_outline_rounded,
                  '删除本轮',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        _startInlineEdit(message);
      case 'continue':
        if (index >= 0) await _openRoundContinuation(index);
      case 'delete':
        await _confirmDeleteMessage(message);
    }
  }

  /// 直接在用户气泡里编辑：保存后记录编辑前版本并重新生成本轮。
  void _startInlineEdit(InspirationMessage message) {
    if (message.id == null) return;
    if (_controller.busy) {
      _showSnack('生成中，稍后再修改');
      return;
    }
    _inlineCtrl.text = message.content;
    _inlineCtrl.selection = TextSelection.collapsed(
      offset: message.content.length,
    );
    setState(() => _editingMessageId = message.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inlineFocus.requestFocus();
    });
  }

  void _cancelInlineEdit() {
    _inlineFocus.unfocus();
    setState(() => _editingMessageId = null);
  }

  void _submitInlineEdit(InspirationMessage message) {
    final text = _inlineCtrl.text.trim();
    if (text.isEmpty || message.id == null) return;
    _inlineFocus.unfocus();
    setState(() => _editingMessageId = null);
    unawaited(_controller.editMessageAndRegenerate(message.id!, text));
  }

  /// 用户指令下方的版本切换：显示编辑前 / 编辑后版本。
  /// 点历史版本后，本轮之后的下文会隐藏，只显示该版本自己的对话。
  Widget _buildRevisionBar(AppPalette p, InspirationMessage message) {
    final total = message.revisions.length + 1;
    final viewing = _viewRevisionMessageId == message.id;
    final selected = viewing
        ? (_viewRevisionIndex ?? total - 1).clamp(0, total - 1)
        : total - 1;
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 4),
      child: Row(
        children: [
          Text('版本', style: TextStyle(fontSize: 9.5, color: p.textTertiary)),
          const SizedBox(width: 8),
          for (var i = 0; i < total; i++)
            InkWell(
              onTap: () => _selectRevision(message, i),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  i == total - 1 ? '${i + 1} 当前' : '${i + 1}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: i == selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: i == selected ? p.textPrimary : p.textTertiary,
                    decoration: i == selected
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    decorationColor: p.textPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _selectRevision(InspirationMessage message, int index) {
    final total = message.revisions.length;
    if (index >= total) {
      setState(() {
        _viewRevisionMessageId = null;
        _viewRevisionIndex = null;
      });
      return;
    }
    setState(() {
      _viewRevisionMessageId = message.id;
      _viewRevisionIndex = index;
    });
  }

  /// 查看从第 [startIndex] 轮开始的「下文」：按顺序显示各轮指令与已采用剧情。
  Future<void> _openRoundContinuation(int startIndex) async {
    final rounds = _controller.messages;
    if (startIndex < 0 || startIndex >= rounds.length) return;
    final p = inspirationPalette(context.palette);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => InspirationTheme(
        child: Container(
          height: MediaQuery.sizeOf(ctx).height * 0.74,
          decoration: BoxDecoration(
            color: p.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        '第 ${startIndex + 1} 轮起 · 下文',
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
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                    children: [
                      for (var i = startIndex; i < rounds.length; i++) ...[
                        Text(
                          '第 ${i + 1} 轮',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.4,
                            color: p.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          rounds[i].content,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.5,
                            color: p.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          rounds[i].chosenBranch?.content ?? '未采用',
                          style: TextStyle(
                            fontSize: 12.4,
                            height: 1.7,
                            color: p.textPrimary,
                          ),
                        ),
                        if (i < rounds.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Divider(height: 1, color: p.border),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteBranch(InspirationBranch branch) async {
    final p = inspirationPalette(context.palette);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          '删除这个推演？',
          style: TextStyle(fontSize: 15, color: p.textPrimary),
        ),
        content: Text(
          '只删除这一条推演。',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: p.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: p.textPrimary)),
          ),
        ],
      ),
    );
    if (ok == true && branch.id != null) {
      await _controller.deleteBranch(branch.id!);
    }
  }

  Future<void> _openMergeSheet(InspirationMessage message) async {
    final p = inspirationPalette(context.palette);
    final selected = <int>{};
    final requirementCtrl = TextEditingController();
    final ids = await showModalBottomSheet<List<int>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return InspirationTheme(
            child: Container(
              decoration: BoxDecoration(
                color: p.background,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                16 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 34,
                          height: 3,
                          decoration: BoxDecoration(
                            color: p.borderStrong,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '选择要合并的推演',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(ctx).height * 0.55,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: message.branches.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: p.border),
                          itemBuilder: (_, i) {
                            final b = message.branches[i];
                            final bid = b.id;
                            final checked =
                                bid != null && selected.contains(bid);
                            return InkWell(
                              onTap: bid == null
                                  ? null
                                  : () => setSheetState(() {
                                      if (!selected.remove(bid)) {
                                        selected.add(bid);
                                      }
                                    }),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Checkbox(
                                        value: checked,
                                        onChanged: bid == null
                                            ? null
                                            : (v) => setSheetState(() {
                                                if (v == true) {
                                                  selected.add(bid);
                                                } else {
                                                  selected.remove(bid);
                                                }
                                              }),
                                        activeColor: p.textPrimary,
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            b.isMerge ? '合并结果' : '推演 ${i + 1}',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: p.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            b.content,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              height: 1.5,
                                              color: p.textTertiary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: requirementCtrl,
                        minLines: 1,
                        maxLines: 3,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: p.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: '合并要求（可选）',
                          hintStyle: TextStyle(
                            fontSize: 12,
                            color: p.textTertiary,
                          ),
                          filled: true,
                          fillColor: p.surfaceMuted,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: p.borderStrong),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: selected.length < 2
                              ? null
                              : () => Navigator.of(ctx).pop(selected.toList()),
                          style: FilledButton.styleFrom(
                            backgroundColor: p.textPrimary,
                            foregroundColor: p.surface,
                            disabledBackgroundColor: p.surfaceMuted,
                            disabledForegroundColor: p.textTertiary,
                            minimumSize: const Size.fromHeight(44),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(
                            selected.length < 2
                                ? '至少选择 2 个'
                                : '合并所选（${selected.length}）',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    final requirement = requirementCtrl.text.trim();
    requirementCtrl.dispose();
    if (ids == null || ids.length < 2 || message.id == null) return;
    final ok = await _controller.mergeBranches(
      message.id!,
      ids,
      requirement: requirement,
    );
    if (!ok) _showSnack('合并失败');
  }

  void _adopt(InspirationMessage message, InspirationBranch branch) {
    if (message.id == null || branch.id == null || branch.chosen) return;
    _controller.setChosen(message.id!, branch.id!);
  }

  // ── UI ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    return InspirationTheme(
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: p.background,
        drawer: InspirationHistoryDrawer(controller: _controller),
        appBar: _buildAppBar(p),
        body: _controller.loading
            ? Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: p.textTertiary,
                  ),
                ),
              )
            : _buildPageBody(p),
      ),
    );
  }

  Widget _buildPageBody(AppPalette p) {
    final viewing = _viewRevisionMessageId != null;
    return Column(
      children: [
        if (viewing) _buildRevisionBanner(p),
        Expanded(child: _buildConversation(p)),
        if (!viewing) _buildComposer(p),
      ],
    );
  }

  Widget _buildRevisionBanner(AppPalette p) {
    return Container(
      width: double.infinity,
      color: p.surfaceMuted,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '正在查看编辑前的对话（第 ${(_viewRevisionIndex ?? 0) + 1} 版），后续内容已隐藏',
              style: TextStyle(fontSize: 10.5, color: p.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _viewRevisionMessageId = null;
              _viewRevisionIndex = null;
            }),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: p.textPrimary,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('返回当前', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildChatMessage(AppPalette p, String text, {required bool isUser}) {
    // 宽度 / 边距 / 字号参考聊天页 MessageBubble：最大 80%，右下/左下小圆角
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8,
          ),
          child: Container(
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
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: isUser ? p.bubbleUserText : p.bubbleAssistantText,
              ),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AppPalette p) {
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.menu_rounded, size: 20, color: p.textPrimary),
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        tooltip: '历史记录',
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              _controller.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: p.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildModeSwitch(p),
        ],
      ),
      actions: [
        PopupMenuButton<String>(
          tooltip: '更多',
          icon: Icon(Icons.more_horiz_rounded, size: 20, color: p.textPrimary),
          color: p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          onSelected: (value) {
            switch (value) {
              case 'context':
                _openContext();
              case 'import':
                _openImportOutline();
              case 'cards':
                _openCharacterCards();
              case 'world':
                _openWorldTheme();
              case 'settings':
                _openSettings();
            }
          },
          itemBuilder: (context) => [
            _menuItem(p, 'context', Icons.menu_book_outlined, '已选内容'),
            _menuItem(p, 'import', Icons.video_library_outlined, '导入大纲'),
            _menuItem(p, 'cards', Icons.badge_outlined, '人物卡'),
            _menuItem(p, 'world', Icons.public_rounded, '设定'),
            _menuItem(p, 'settings', Icons.settings_outlined, '设置'),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    AppPalette p,
    String value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 42,
      child: Row(
        children: [
          Icon(icon, size: 17, color: p.textSecondary),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: p.textPrimary)),
        ],
      ),
    );
  }

  /// 标题旁的「聊天 / 推演」切换：两种内容同页显示，只决定发送方式。
  Widget _buildModeSwitch(AppPalette p) {
    Widget option(String label, _InspirationMode mode) {
      final active = _mode == mode;
      return InkWell(
        onTap: () => setState(() {
          _mode = mode;
          _viewRevisionMessageId = null;
          _viewRevisionIndex = null;
          _editingMessageId = null;
        }),
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: active ? p.textPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? p.surface : p.textTertiary,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        border: Border.all(color: p.borderStrong),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          option('聊天', _InspirationMode.chat),
          option('推演', _InspirationMode.deduction),
        ],
      ),
    );
  }

  /// 聊天消息与推演轮次按时间合并到同一条时间线。
  List<
    ({
      DateTime time,
      InspirationMessage? deduction,
      InspirationChatMessage? chat,
    })
  >
  _timelineEvents() {
    final events =
        <
          ({
            DateTime time,
            InspirationMessage? deduction,
            InspirationChatMessage? chat,
          })
        >[];
    DateTime timeOf(String raw) =>
        DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    for (final m in _controller.messages) {
      events.add((time: timeOf(m.createdAt), deduction: m, chat: null));
    }
    for (final m in _controller.chatMessages) {
      events.add((time: timeOf(m.createdAt), deduction: null, chat: m));
    }
    events.sort((a, b) => a.time.compareTo(b.time));
    return events;
  }

  Widget _buildConversation(AppPalette p) {
    final events = _timelineEvents();
    final viewId = _viewRevisionMessageId;
    int? viewingIndex;
    if (viewId != null) {
      viewingIndex = events.indexWhere((e) => e.deduction?.id == viewId);
    }
    final visible = viewingIndex != null
        ? events.sublist(0, viewingIndex + 1)
        : events;
    final showChatStreaming =
        _controller.chatGenerating && viewingIndex == null;
    if (visible.isEmpty &&
        !_controller.hasDraft &&
        !_controller.chatGenerating) {
      return _buildEmptyState(p);
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      itemCount: visible.length + (showChatStreaming ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= visible.length) {
          return _buildChatMessage(
            p,
            _controller.chatStreamingText.isEmpty
                ? '…'
                : _controller.chatStreamingText,
            isUser: false,
          );
        }
        final event = visible[index];
        final deduction = event.deduction;
        if (deduction != null) {
          if (viewingIndex == index && _viewRevisionIndex != null) {
            return _buildVersionedRound(p, deduction, _viewRevisionIndex!);
          }
          return _buildRound(p, deduction);
        }
        final chat = event.chat!;
        return _buildChatMessage(p, chat.content, isUser: chat.isUser);
      },
    );
  }

  /// 只读显示某一版编辑前的「用户指令 + 当时采用结果」。
  Widget _buildVersionedRound(
    AppPalette p,
    InspirationMessage message,
    int index,
  ) {
    final revision = message.revisions[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.76,
              ),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                color: p.bubbleUser,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                revision.instruction,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: p.bubbleUserText,
                ),
              ),
            ),
          ),
          if (message.revisions.isNotEmpty) _buildRevisionBar(p, message),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            decoration: BoxDecoration(
              color: p.bubbleAssistant,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '第 ${index + 1} 版 · 编辑前',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.4,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  revision.result.trim().isEmpty ? '未采用' : revision.result,
                  style: TextStyle(
                    fontSize: 12.4,
                    height: 1.72,
                    color: p.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 30, color: p.textTertiary),
            const SizedBox(height: 18),
            Text(
              '小说灵感',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '描述情节，或从右上角导入大纲。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: p.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRound(AppPalette p, InspirationMessage message) {
    final isDraftTarget =
        _controller.draftMessageId == message.id && _controller.hasDraft;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: _editingMessageId == message.id
                ? _buildInlineEditor(p, message)
                : GestureDetector(
                    onLongPress: () => _showMessageActions(message),
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.76,
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      decoration: BoxDecoration(
                        color: p.bubbleUser,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        message.content,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.6,
                          color: p.bubbleUserText,
                        ),
                      ),
                    ),
                  ),
          ),
          if (message.revisions.isNotEmpty && _editingMessageId != message.id)
            _buildRevisionBar(p, message),
          const SizedBox(height: 10),
          if (message.branches.isNotEmpty || isDraftTarget)
            _buildAssistantBubble(p, message, isDraftTarget)
          else
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '无结果',
                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                  ),
                  TextButton(
                    onPressed: _controller.busy
                        ? null
                        : () => _controller.regenerate(message.id!),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: p.textPrimary,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInlineEditor(AppPalette p, InspirationMessage message) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.9,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _inlineCtrl,
            focusNode: _inlineFocus,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            style: TextStyle(fontSize: 13, height: 1.55, color: p.textPrimary),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: '修改本轮对话',
              hintStyle: TextStyle(fontSize: 12.5, color: p.textTertiary),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _cancelInlineEdit,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: p.textTertiary,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 11.5)),
              ),
              TextButton(
                onPressed: () => _submitInlineEdit(message),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: p.textPrimary,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('完成', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantBubble(
    AppPalette p,
    InspirationMessage message,
    bool isDraftTarget,
  ) {
    final isDraft = isDraftTarget && _controller.draftBranches.isNotEmpty;
    final branches = message.branches;
    final total = isDraft ? _controller.draftBranches.length : branches.length;
    if (total == 0) return const SizedBox.shrink();

    var active = _activeVersion[message.id] ?? 0;
    active = active.clamp(0, total - 1);

    final activeBranch = isDraft ? null : branches[active];
    final activeDraft = isDraft ? _controller.draftBranches[active] : null;
    final content = isDraft
        ? (activeDraft?.text ?? '')
        : (activeBranch?.content ?? '');
    final wordCount = content.trim().characters.length;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.bubbleAssistant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
            child: Row(
              children: [
                Text(
                  isDraft ? '推演 · 生成中' : '推演',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                    color: p.textSecondary,
                  ),
                ),
                if (!isDraft && activeBranch != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    activeBranch.isMerge
                        ? '合并'
                        : (activeBranch.chosen ? '已采用' : ''),
                    style: TextStyle(fontSize: 9.5, color: p.textTertiary),
                  ),
                ],
                const Spacer(),
                if (!isDraft)
                  IconButton(
                    tooltip: '推演操作',
                    onPressed: activeBranch == null
                        ? null
                        : () => _openBranchActions(message, activeBranch),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: p.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
            child: isDraft && content.trim().isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '生成中…',
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                    ),
                  )
                : _ExpandableProse(
                    text: content,
                    style: TextStyle(
                      fontSize: 11.8,
                      height: 1.72,
                      color: p.textPrimary,
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 12, 6),
            child: Row(
              children: [
                _pagerButton(
                  p,
                  Icons.chevron_left_rounded,
                  '上一页',
                  active > 0
                      ? () => setState(
                          () => _activeVersion[message.id!] = active - 1,
                        )
                      : null,
                ),
                Text(
                  '${active + 1} / $total',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.2,
                    color: p.textTertiary,
                  ),
                ),
                _pagerButton(
                  p,
                  Icons.chevron_right_rounded,
                  '下一页',
                  active < total - 1
                      ? () => setState(
                          () => _activeVersion[message.id!] = active + 1,
                        )
                      : null,
                ),
                const Spacer(),
                if (!isDraft && activeBranch != null)
                  TextButton(
                    onPressed: activeBranch.chosen
                        ? null
                        : () => _adopt(message, activeBranch),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: activeBranch.chosen
                          ? p.textTertiary
                          : p.textPrimary,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                    ),
                    child: Text(
                      activeBranch.chosen ? '已采用' : '采用此版',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                  ),
                if (!isDraft) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$wordCount 字',
                    style: TextStyle(fontSize: 9.5, color: p.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pagerButton(
    AppPalette p,
    IconData icon,
    String semanticLabel,
    VoidCallback? onTap,
  ) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 18,
            color: onTap == null
                ? p.textTertiary.withValues(alpha: 0.35)
                : p.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 气泡右上角「…」：编辑 / 刷新 / 删除 / 合并 的横向操作栏。
  Future<void> _openBranchActions(
    InspirationMessage message,
    InspirationBranch branch,
  ) async {
    final p = context.palette;
    final hasMultiple = message.branches.length >= 2;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => InspirationTheme(
        child: Container(
          decoration: BoxDecoration(
            color: p.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _actionItem(ctx, p, 'edit', Icons.edit_outlined, '编辑'),
                _actionItem(
                  ctx,
                  p,
                  'regenerate',
                  Icons.refresh_rounded,
                  '重新生成',
                ),
                _actionItem(
                  ctx,
                  p,
                  'merge',
                  Icons.merge_type_rounded,
                  '合并',
                  enabled: hasMultiple,
                ),
                _actionItem(
                  ctx,
                  p,
                  'delete',
                  Icons.delete_outline_rounded,
                  '删除',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        _editBranch(branch);
      case 'regenerate':
        await _controller.regenerate(message.id!);
      case 'merge':
        await _openMergeSheet(message);
      case 'delete':
        await _confirmDeleteBranch(branch);
    }
  }

  Widget _actionItem(
    BuildContext ctx,
    AppPalette p,
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? () => Navigator.of(ctx).pop(value) : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: p.textPrimary),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: p.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(AppPalette p) {
    final busy = _controller.chatGenerating || _controller.busy;
    final hint = _mode == _InspirationMode.chat ? '和 AI 讨论剧情' : '描述接下来想推演的情节';
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Text(
                        _controller.chatGenerating
                            ? '回复中'
                            : (_controller.merging ? '合并中' : '生成中'),
                        style: TextStyle(fontSize: 11, color: p.textTertiary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _controller.chatGenerating
                            ? _controller.cancelChat
                            : _controller.cancelGeneration,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: p.textSecondary,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        child: const Text('取消', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      minLines: 1,
                      maxLines: 4,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: p.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: hint,
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: p.textTertiary,
                        ),
                        filled: true,
                        fillColor: p.surfaceMuted,
                        contentPadding: const EdgeInsets.fromLTRB(
                          14,
                          11,
                          14,
                          11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide(color: p.borderStrong),
                        ),
                      ),
                      onSubmitted: (_) => _sendCurrent(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: FilledButton(
                      onPressed: busy ? null : _sendCurrent,
                      style: FilledButton.styleFrom(
                        backgroundColor: p.textPrimary,
                        foregroundColor: p.surface,
                        disabledBackgroundColor: p.surfaceMuted,
                        disabledForegroundColor: p.textTertiary,
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: const Icon(Icons.arrow_upward_rounded, size: 19),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 长正文折叠：默认最多 8 行，超过时可展开 / 收起。
class _ExpandableProse extends StatefulWidget {
  const _ExpandableProse({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_ExpandableProse> createState() => _ExpandableProseState();
}

class _ExpandableProseState extends State<_ExpandableProse> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final couldCollapse = widget.text.characters.length > 220;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: _expanded ? null : 8,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: widget.style,
        ),
        if (couldCollapse)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(vertical: 2),
                foregroundColor: p.textTertiary,
              ),
              child: Text(
                _expanded ? '收起' : '展开',
                style: const TextStyle(fontSize: 10.5),
              ),
            ),
          ),
      ],
    );
  }
}
