import 'dart:async';
import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/domain/outline_chapter.dart';
import 'outline_setting_page.dart';
import 'story_state_page.dart';
import '../../controller/chapter_write_controller.dart';

/// 大纲转章节写作页面
class ChapterWritePage extends StatefulWidget {
  final OutlineRecord outline;
  const ChapterWritePage({super.key, required this.outline});

  @override
  State<ChapterWritePage> createState() => _ChapterWritePageState();
}

class _ChapterWritePageState extends State<ChapterWritePage> {
  late final ChapterWriteController _controller;
  final _scrollController = ScrollController();
  final _writeScrollController = ScrollController();
  bool _showWriteView = false; // 是否处于全屏生成视图
  bool _selectMode = false; // 是否处于批量删除选择模式
  final Set<int> _selected = {}; // 批量删除选中的章节 id
  bool _followOutput = true; // 是否自动跟随流式输出滚到底部（用户上滑阅读时暂停跟随）
  DateTime? _lastScrollJump; // 自动滚动节流时间戳
  int _lastChapterWords = 0; // 上一次章节生成的字数（连续生成时预填，避免重复输入）
  OutlineChapter? _lastWriteChapter; // 最近一次尝试生成的章节（失败后写视图提供「重新生成」）
  Timer? _foreshadowWatchTimer; // 轻量轮询：伏笔后台提炼期间保持横幅提醒直到完成
  bool _lastForeshadowRefreshing = false; // 伏笔提炼状态快照
  Timer? _processWatchTimer; // 轻量轮询：章节账本/小结提炼状态（卡片加载指示）
  bool _lastProcessingChapter = false; // 提炼状态快照

  @override
  void initState() {
    super.initState();
    _controller = ChapterWriteController(widget.outline);
    // 用户上滑阅读时暂停自动跟随，避免流式输出不断把视图拉回底部导致卡顿
    _writeScrollController.addListener(() {
      final pos = _writeScrollController.position;
      if (pos.hasContentDimensions) {
        _followOutput = pos.pixels >= pos.maxScrollExtent - 80;
      }
    });
    _controller.initLoad().then((_) {
      if (mounted) setState(() {});
      if (mounted && _controller.needsResync) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _showResyncDialog(),
        );
      }
    });
    _startForeshadowWatch();
    _startProcessWatch();
  }

  /// 轻量轮询：编辑保存后的账本/小结提炼状态变化时刷新列表卡片
  /// （提炼中的章节显示加载指示，开始/结束自动切换）
  void _startProcessWatch() {
    _processWatchTimer?.cancel();
    // 常驻轮询：编辑页保存开始/结束提炼时切换章节卡片指示；
    // 不随空闲自停，否则回到列表后无法感知新的提炼开始
    _processWatchTimer = Timer.periodic(
      const Duration(milliseconds: 600),
      (_) {
        if (!mounted) return;
        final processing = _controller.processingChapterId != null;
        if (processing != _lastProcessingChapter) {
          _lastProcessingChapter = processing;
          setState(() {});
        }
      },
    );
  }

  /// 轻量轮询：控制器伏笔后台提炼状态变化时刷新界面——
  /// 提炼开始显示常驻横幅提醒，完成自动消失；提炼结束后停止轮询
  void _startForeshadowWatch() {
    _foreshadowWatchTimer?.cancel();
    _foreshadowWatchTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        final refreshing = _controller.isRefreshingForeshadows;
        if (refreshing != _lastForeshadowRefreshing) {
          _lastForeshadowRefreshing = refreshing;
          setState(() {});
        }
        if (!refreshing) t.cancel();
      },
    );
  }

  @override
  void dispose() {
    _foreshadowWatchTimer?.cancel();
    _processWatchTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _writeScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showWriteView && !_selectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 系统返回键：全屏生成视图/选择模式下先退出该模式，再按一次才离开页面
        if (_selectMode) {
          setState(() {
            _selectMode = false;
            _selected.clear();
          });
        } else if (_showWriteView) {
          setState(() => _showWriteView = false);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(
            widget.outline.title.isNotEmpty ? widget.outline.title : '大纲转章节',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          backgroundColor: Colors.white,
          elevation: 0.5,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.menu_book, color: Color(0xFF4D6BFE)),
              tooltip: '剧情状态账本',
              onPressed: () {
                if (widget.outline.id == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StoryStatePage(
                      outlineId: widget.outline.id!,
                      controller: _controller,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.settings_outlined,
                color: Color(0xFF666666),
              ),
              tooltip: 'AI 设置',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChapterSettingPage()),
                );
              },
            ),
            if (_selectMode)
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF666666)),
                tooltip: '取消选择',
                onPressed: () => setState(() {
                  _selectMode = false;
                  _selected.clear();
                }),
              )
            else
              IconButton(
                icon: const Icon(
                  Icons.delete_sweep_outlined,
                  color: Color(0xFF666666),
                ),
                tooltip: '批量删除已生成内容',
                onPressed: (_controller.isWriting || _showWriteView)
                    ? null
                    : () => setState(() => _selectMode = true),
              ),
          ],
        ),
        bottomNavigationBar: _selectMode && !_showWriteView
            ? _buildSelectBar()
            : null,
        body: _controller.isLoading
            ? const Center(child: CircularProgressIndicator())
            : _showWriteView
            ? _buildWriteView()
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    color: const Color(0xFFF8F9FF),
                    child: Text(
                      _controller.isAllCompleted
                          ? '✅ 所有事件已完成'
                          : '${_controller.completedCount}/${_controller.writableCount} 个事件已完成',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF666666),
                      ),
                    ),
                  ),
                  // 伏笔后台提炼常驻提醒：从触发一直显示到提炼完成
                  if (_controller.isRefreshingForeshadows)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: const Color(0xFFFFF8E1),
                      child: const Row(
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '伏笔清单提炼中，完成后自动更新',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF8D6E63),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _controller.chapters.length,
                      itemBuilder: (context, index) {
                        final ch = _controller.chapters[index];
                        return _ChapterTile(
                          chapter: ch,
                          locked: !_controller.isWritable(ch),
                          isWriting: _controller.writingId == ch.id,
                          isProcessing:
                              _controller.isProcessingChapter(ch),
                          writingContent: _controller.writingId == ch.id
                              ? _controller.writingText
                              : '',
                          selectMode: _selectMode,
                          selected: _selected.contains(ch.id),
                          onToggleSelect: () => _toggleSelect(ch),
                          onWrite: () => _startWrite(ch),
                          onView: () => _openViewPage(ch),
                          onEdit: (c) => _openEditPage(c),
                          onEditOutline: (c) => _showEditOutlineDialog(c),
                          onEditLedger: (c) => _openLedgerDialog(c),
                          onOpenWriteView: () =>
                              setState(() => _showWriteView = true),
                          onDelete: () async {
                            await _controller.resetChapter(ch);
                            setState(() {});
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),

        floatingActionButton: _controller.isWriting
            ? FloatingActionButton.extended(
                onPressed: () => _controller.stopWrite(),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('停止生成'),
              )
            : null,
      ),
    );
  }

  /// 返回逻辑：选择模式/全屏生成视图下先退出当前模式，再按一次才退出页面
  void _handleBack() {
    if (_selectMode) {
      setState(() {
        _selectMode = false;
        _selected.clear();
      });
      return;
    }
    if (_showWriteView) {
      setState(() => _showWriteView = false);
      return;
    }
    Navigator.of(context).pop();
  }

  /// 开始写章节：先生成前弹出字数输入框（预填设置默认值/上次输入），
  /// 确认后切换到全屏生成视图，流式内容实时展示。
  Future<void> _startWrite(OutlineChapter ch) async {
    final defaultWords = await _controller.loadDefaultWords();
    if (!mounted) return;
    final target = await _showWordCountDialog(
      _lastChapterWords > 0 ? _lastChapterWords : defaultWords,
    );
    if (!mounted || target == null) return;
    _lastChapterWords = target;
    _lastWriteChapter = ch;
    _followOutput = true;
    setState(() => _showWriteView = true);
    _controller.startWrite(context, ch, () {
      if (!mounted) return;
      setState(() {});
      _scrollWriteToBottom();
    }, targetWords: target);
  }

  /// 章节生成前的字数输入弹窗：返回用户输入的目标字数；取消返回 null
  Future<int?> _showWordCountDialog(int defaultWords) {
    return showDialog<int>(
      context: context,
      // 键盘弹出时上移弹窗，避免输入框被键盘遮挡
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _WordCountDialog(initialWords: defaultWords),
      ),
    );
  }

  /// 生成视图自动滚动到底部（流式输出跟随）。
  /// 节流 + 跟随判定：用户上滑阅读时不打扰；每 150ms 最多滚一次，避免分块流式下卡顿。
  void _scrollWriteToBottom() {
    if (!_followOutput) return; // 用户已上滑阅读，停止自动跟随
    final now = DateTime.now();
    if (_lastScrollJump != null &&
        now.difference(_lastScrollJump!) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastScrollJump = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_followOutput || !_writeScrollController.hasClients) return;
      final pos = _writeScrollController.position;
      if (pos.maxScrollExtent > 0) {
        _writeScrollController.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  /// 当前正在生成的章节
  OutlineChapter? _currentWritingChapter() {
    for (final c in _controller.chapters) {
      if (c.id == _controller.writingId) return c;
    }
    return null;
  }

  /// 全屏生成视图：状态条 + 完整流式正文（可选中复制、自动滚动）
  Widget _buildWriteView() {
    final ch = _currentWritingChapter();
    final writing = _controller.isWriting;
    final text = _controller.writingText;
    final thinking = _controller.thinkingText;
    final review = _controller.reviewText;
    final story = _controller.storyStateText;
    final protagonist = _controller.protagonistText;
    final protagonistThink = _controller.protagonistThinking;
    final protagonistReview = _controller.protagonistReviewText;
    final protagonistReviewThink = _controller.protagonistReviewThinking;
    final reviewThink = _controller.reviewThinking;
    final storyThink = _controller.storyStateThinking;
    final String status;
    if (_controller.extractingProtagonist) {
      status = '正在提炼主角档案...';
    } else if (_controller.reviewingProtagonist) {
      status = '主角档案审查中...';
    } else if (_controller.reviewing) {
      status = 'AI 审查修正中...';
    } else if (_controller.extractingStory) {
      status = '正在提炼剧情状态...';
    } else if (writing) {
      status = '正在生成：${ch?.eventTitle ?? ''}';
    } else if (_controller.wasCancelled) {
      status = '已停止，已保留部分内容';
    } else if (_controller.errorText.trim().isNotEmpty && text.isEmpty) {
      status = '生成失败：${_controller.errorText}';
    } else {
      status = text.isEmpty ? '未开始生成' : '生成完成';
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFF8F9FF),
          child: Row(
            children: [
              if (writing ||
                  _controller.extractingProtagonist ||
                  _controller.reviewingProtagonist ||
                  _controller.reviewing ||
                  _controller.extractingStory)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  _controller.wasCancelled
                      ? Icons.stop_circle_outlined
                      : Icons.check_circle,
                  size: 16,
                  color: _controller.wasCancelled
                      ? const Color(0xFFFF9800)
                      : const Color(0xFF4CAF50),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF666666),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _showWriteView = false),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                ),
                child: const Text(
                  '回到列表',
                  style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _writeScrollController,
            thumbVisibility: true,
            // 允许拖动滚动条拇指快速上滑/下拉（移动端默认不可拖动，需显式开启）
            interactive: true,
            scrollbarOrientation: ScrollbarOrientation.right,
            child: SingleChildScrollView(
              controller: _writeScrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 主角档案提炼（含思考、档案审查），位于最上方 ──
                  if (_controller.extractingProtagonist ||
                      protagonist.trim().isNotEmpty) ...[
                    if (protagonistThink.trim().isNotEmpty) ...[
                      _buildProcessBubble(
                        icon: Icons.psychology_alt,
                        title: '主角提炼思考',
                        content: protagonistThink,
                        emptyHint: '',
                      ),
                      const SizedBox(height: 12),
                    ],
                    _buildProcessBubble(
                      icon: Icons.person_outline,
                      title: '主角档案提炼',
                      content: protagonist,
                      emptyHint: '正在提炼中...',
                    ),
                    const SizedBox(height: 12),
                    // 档案审查独立气泡：审查对象是主角档案而非章节正文，
                    // 与正文下方的「AI 审查」（章节审查）区分
                    if (_controller.reviewingProtagonist ||
                        protagonistReview.trim().isNotEmpty) ...[
                      if (protagonistReviewThink.trim().isNotEmpty) ...[
                        _buildProcessBubble(
                          icon: Icons.psychology_alt,
                          title: '档案审查思考',
                          content: protagonistReviewThink,
                          emptyHint: '',
                        ),
                        const SizedBox(height: 12),
                      ],
                      _buildProcessBubble(
                        icon: Icons.verified_user_outlined,
                        title: '档案审查',
                        content: protagonistReview,
                        emptyHint: '正在审查档案中...',
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                  // ── 正文生成思考（仅生成阶段） ──
                  if (thinking.trim().isNotEmpty) ...[
                    _buildProcessBubble(
                      icon: Icons.psychology_alt,
                      title: '思考过程',
                      content: thinking,
                      emptyHint: '',
                    ),
                    const SizedBox(height: 12),
                  ],
                  // ── 生成失败错误提示（正文为空且失败时展示，避免静默） ──
                  if (!writing &&
                      _controller.errorText.trim().isNotEmpty &&
                      text.isEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3F0),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFFCCBC)),
                      ),
                      child: SelectableText(
                        '生成失败：${_controller.errorText}',
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: Color(0xFFD84315),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 失败后提供「重新生成」入口，一键重试本章
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _lastWriteChapter == null
                            ? null
                            : () => _startWrite(_lastWriteChapter!),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重新生成'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4D6BFE),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // ── 章节正文（第一次生成内容） ──
                  SelectableText(
                    text.isEmpty
                        ? (writing &&
                                  thinking.trim().isEmpty &&
                                  review.trim().isEmpty
                              ? '正在思考中，请稍候...'
                              : '（暂无内容）')
                        : text,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.8,
                      color: Color(0xFF333333),
                    ),
                  ),
                  // ── 审查相关（思考/意见/对比）位于正文下方 ──
                  if (reviewThink.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildProcessBubble(
                      icon: Icons.psychology_alt,
                      title: '审查思考',
                      content: reviewThink,
                      emptyHint: '',
                    ),
                  ],
                  if (_controller.reviewing || review.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildProcessBubble(
                      icon: Icons.edit_note,
                      title: 'AI 审查',
                      content: review,
                      emptyHint: '正在审查思考中...',
                    ),
                  ],
                  if (_controller.reviewBefore.trim().isNotEmpty &&
                      _controller.reviewAfter.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildProcessBubble(
                      icon: Icons.difference,
                      title: '审查对比',
                      content:
                          '【修改前】\n${_controller.reviewBefore}\n\n【修改后】\n${_controller.reviewAfter}',
                      emptyHint: '',
                    ),
                  ],
                  // ── 剧情状态账本（含思考），位于最下方 ──
                  if (_controller.extractingStory ||
                      story.trim().isNotEmpty) ...[
                    if (storyThink.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildProcessBubble(
                        icon: Icons.psychology_alt,
                        title: '账本提炼思考',
                        content: storyThink,
                        emptyHint: '',
                      ),
                    ],
                    const SizedBox(height: 12),
                    _buildProcessBubble(
                      icon: Icons.menu_book,
                      title: '剧情状态账本',
                      content: story,
                      emptyHint: '正在提炼中...',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 生成过程气泡（思考/审查/账本提炼统一样式）：
  /// 浅蓝卡片 + 图标 + 标题 + 可选中复制的内容；内容为空时显示占位提示。
  Widget _buildProcessBubble({
    required IconData icon,
    required String title,
    required String content,
    required String emptyHint,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD8E2FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: const Color(0xFF4D6BFE)),
              const SizedBox(width: 4),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4D6BFE),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            content.trim().isEmpty ? emptyHint : content,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Color(0xFF666666),
            ),
          ),
        ],
      ),
    );
  }

  /// 有已生成内容的章节（可作为批量删除的候选）
  List<OutlineChapter> _deletableChapters() => _controller.chapters
      .where(
        (c) =>
            c.id != null &&
            c.status == 'completed' &&
            c.content.trim().isNotEmpty,
      )
      .toList();

  void _toggleSelect(OutlineChapter ch) {
    final id = ch.id;
    if (id == null) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// 批量删除底部操作栏：已选数量 + 全选 + 删除
  Widget _buildSelectBar() {
    final deletable = _deletableChapters();
    final allSelected =
        deletable.isNotEmpty && _selected.length == deletable.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            Text(
              '已选 ${_selected.length} 项',
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(deletable.map((c) => c.id!));
                }
              }),
              child: Text(
                allSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 13, color: Color(0xFF4D6BFE)),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _selected.isEmpty ? null : _confirmBatchDelete,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF5252),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('删除所选'),
            ),
          ],
        ),
      ),
    );
  }

  /// 确认并批量删除已选章节的已生成内容
  Future<void> _confirmBatchDelete() async {
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('确定删除已选 $count 个章节的已生成内容吗？删除后可重新生成。'),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final items = _controller.chapters
        .where((c) => c.id != null && _selected.contains(c.id))
        .toList();
    await _controller.resetChapters(items);
    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已删除 ${items.length} 个章节的已生成内容')));
  }

  /// 打开章节内容查看全屏页面（替代弹窗，便于完整阅读）
  void _openViewPage(OutlineChapter ch) {
    if (ch.content.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ChapterViewPage(
          chapter: ch,
          controller: _controller,
          onEdit: () => _openEditPage(ch),
        ),
      ),
    );
  }

  /// 编辑章节大纲弹窗
  void _showEditOutlineDialog(OutlineChapter ch) {
    if (ch.id == null) return;
    final titleCtrl = TextEditingController(text: ch.eventTitle);
    final summaryCtrl = TextEditingController(text: ch.eventSummary);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        title: const Text(
          '修改大纲',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: InputDecoration(
                  labelText: '事件标题',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  contentPadding: const EdgeInsets.all(10),
                  filled: true,
                  fillColor: const Color(0xFFFAFAFA),
                ),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: summaryCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: '事件概要',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  contentPadding: const EdgeInsets.all(10),
                  filled: true,
                  fillColor: const Color(0xFFFAFAFA),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.open_in_full, size: 18),
                    tooltip: '放大编辑',
                    color: const Color(0xFF999999),
                    onPressed: () {
                      final editCtrl = TextEditingController(
                        text: summaryCtrl.text,
                      );
                      final screenHeight = MediaQuery.of(context).size.height;
                      final screenWidth = MediaQuery.of(context).size.width;
                      showDialog(
                        context: context,
                        builder: (ctx2) => AlertDialog(
                          titlePadding: const EdgeInsets.fromLTRB(
                            16,
                            10,
                            16,
                            0,
                          ),
                          contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                          actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                          insetPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 24,
                          ),
                          title: const Text(
                            '编辑事件概要',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          content: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: screenHeight * 0.72,
                              maxWidth: screenWidth * 0.92,
                            ),
                            child: TextField(
                              controller: editCtrl,
                              maxLines: null,
                              expands: true,
                              textAlignVertical: TextAlignVertical.top,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.fromLTRB(
                                  4,
                                  2,
                                  4,
                                  2,
                                ),
                                filled: true,
                                fillColor: const Color(0xFFFAFAFA),
                              ),
                              style: const TextStyle(fontSize: 10, height: 1.5),
                            ),
                          ),
                          actions: [
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                if (!closeDialogSafely(ctx2)) return;
                                scheduleControllerDispose(editCtrl);
                              },
                              child: const Text(
                                '取消',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                if (!closeDialogSafely(ctx2)) return;
                                summaryCtrl.text = editCtrl.text;
                                scheduleControllerDispose(editCtrl);
                              },
                              child: const Text(
                                '确定',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF4D6BFE),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx),
            child: const Text(
              '取消',
              style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
          ),
          TextButton(
            onPressed: () async {
              final title = titleCtrl.text.trim();
              final summary = summaryCtrl.text.trim();
              if (title.isEmpty && summary.isEmpty) return;
              await _controller.updateChapterSummary(ch, title, summary);
              if (mounted) setState(() {});
              // 防止等待期间重复点击造成重复 pop（会连带关闭下层页面）
              if (ctx.mounted) closeDialogSafely(ctx);
              // 保存完成：伏笔清单在后台重新提炼，页面横幅会持续提醒直到提炼完成
            },
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
  }

  /// 检测到大纲内容已修改时弹出同步确认对话框
  Future<void> _showResyncDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('大纲已修改'),
        content: const Text('检测到大纲内容已更新，是否重新解析章节结构？\n\n注意：已完成的章节正文内容将被保留。'),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: false),
            child: const Text('忽略', style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: true),
            child: const Text(
              '重新解析',
              style: TextStyle(color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _controller.resync();
      if (mounted) setState(() {});
    }
  }

  /// 查看/编辑本章独立的剧情账本（每章生成时自动保存，重新生成后可回退）
  void _openLedgerDialog(OutlineChapter ch) {
    final ctrl = TextEditingController(text: ch.storyState);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        title: Text(
          '剧情账本 · ' + ch.eventTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: SingleChildScrollView(
            child: TextField(
              controller: ctrl,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: '本章剧情账本（角色处境 / 时间地点 / 伏笔 / 悬念 / 冲突）。生成章节后自动提炼，可在此手动修改',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(10),
                filled: true,
                fillColor: Color(0xFFFAFAFA),
              ),
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(ctrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              if (!closeDialogSafely(ctx)) return; // 防重复点击
              scheduleControllerDispose(ctrl);
              await _controller.saveChapterLedger(ch, text);
              if (mounted) setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('本章账本已保存'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF4D6BFE)),
            child: const Text('保存', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// 打开章节编辑全屏页面
  Future<void> _openEditPage(OutlineChapter ch) async {
    if (ch.id == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ChapterEditPage(
          chapter: ch,
          controller: _controller,
          onSaved: (newContent) async {
            await _controller.saveChapterContent(ch, newContent);
            if (mounted) setState(() {});
          },
        ),
      ),
    );
    // 返回列表后刷新：提炼中/已更新的章节卡片状态即时反映
    if (mounted) setState(() {});
  }
}

/// 单个事件卡片
class _ChapterTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool locked; // 前序章节未全部完成时锁定「写」按钮，强制顺序生成
  final bool isWriting;
  final bool isProcessing; // 编辑保存后正在后台提炼账本/小结
  final String writingContent;
  final VoidCallback onWrite;
  final VoidCallback onView;
  final VoidCallback onDelete;
  final VoidCallback onOpenWriteView;
  final bool selectMode; // 是否处于批量删除选择模式
  final bool selected; // 当前是否被选中
  final VoidCallback? onToggleSelect;
  final void Function(OutlineChapter) onEdit;
  final void Function(OutlineChapter) onEditOutline;
  final void Function(OutlineChapter) onEditLedger; // 查看/编辑本章剧情账本

  const _ChapterTile({
    required this.chapter,
    required this.locked,
    required this.isWriting,
    required this.isProcessing,
    required this.writingContent,
    required this.onWrite,
    required this.onView,
    required this.onDelete,
    required this.onEdit,
    required this.onEditOutline,
    required this.onEditLedger,
    required this.onOpenWriteView,
    required this.selectMode,
    required this.selected,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isMajor = chapter.eventType == 'major';
    final isCompleted = chapter.status == 'completed';
    // 选择模式下仅已完成且含正文的章节可被勾选
    final canSelect =
        selectMode && isCompleted && chapter.content.trim().isNotEmpty;

    // 大事件不可写：仅作为阶段标题展示（含概述，可修改大纲）
    if (isMajor) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE8ECF4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.flag, size: 20, color: Color(0xFF4D6BFE)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chapter.eventTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => onEditOutline(chapter),
                  child: const Text(
                    '修改大纲',
                    style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                  ),
                ),
              ],
            ),
            if (chapter.eventSummary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                chapter.eventSummary,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Color(0xFF999999),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: canSelect ? onToggleSelect : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMajor ? const Color(0xFFF8F9FF) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCompleted
                ? const Color(0xFFE0F0E0)
                : const Color(0xFFE8ECF4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (selectMode) ...[
                  Checkbox(
                    value: selected,
                    onChanged: canSelect ? (_) => onToggleSelect?.call() : null,
                    activeColor: const Color(0xFF4D6BFE),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 4),
                ],
                Icon(
                  isMajor ? Icons.flag : Icons.circle_outlined,
                  size: isMajor ? 20 : 8,
                  color: isCompleted
                      ? const Color(0xFF4CAF50)
                      : (isMajor
                            ? const Color(0xFF4D6BFE)
                            : const Color(0xFF999999)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chapter.eventTitle,
                    style: TextStyle(
                      fontSize: isMajor ? 15 : 13,
                      fontWeight: isMajor ? FontWeight.w600 : FontWeight.w500,
                      color: const Color(0xFF333333),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selectMode)
                  const SizedBox.shrink()
                else if (isWriting || isProcessing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (isCompleted)
                  const Icon(
                    Icons.check_circle,
                    size: 20,
                    color: Color(0xFF4CAF50),
                  )
                else
                  SizedBox(
                    height: 28,
                    child: ElevatedButton(
                      onPressed: locked ? null : onWrite,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: locked
                            ? const Color(0xFFE8ECF4)
                            : const Color(0xFF4D6BFE),
                        foregroundColor: locked
                            ? const Color(0xFF999999)
                            : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('写'),
                    ),
                  ),
              ],
            ),
            if (chapter.eventSummary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                chapter.eventSummary,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Color(0xFF999999),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ] else ...[
              const SizedBox(height: 6),
              Text(
                '暂无概要',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.grey[300],
                ),
              ),
            ],
            if (locked && !isCompleted && !isWriting && !selectMode) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 12,
                    color: Color(0xFFBBBBBB),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '需先完成前面的章节才能生成',
                    style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
                  ),
                ],
              ),
            ],
            if (isCompleted && !isWriting && !selectMode) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  GestureDetector(
                    onTap: onView,
                    child: const Text(
                      '查看内容',
                      style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => onEdit(chapter),
                    child: const Text(
                      '编辑',
                      style: TextStyle(fontSize: 11, color: Color(0xFF7C4DFF)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => onEditOutline(chapter),
                    child: const Text(
                      '修改大纲',
                      style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => onEditLedger(chapter),
                    child: const Text(
                      '账本',
                      style: TextStyle(fontSize: 11, color: Color(0xFF00897B)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('确认删除'),
                          content: const Text('确定要删除已生成的内容吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => closeDialogSafely(ctx),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () {
                                if (!closeDialogSafely(ctx)) return;
                                onDelete();
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Text(
                      '重新生成',
                      style: TextStyle(fontSize: 11, color: Color(0xFFFF5722)),
                    ),
                  ),
                ],
              ),
            ],
            if (isProcessing) ...[
              const SizedBox(height: 6),
              Row(
                children: const [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '正在提炼剧情状态与整章小结，可点「查看内容」查看进度',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8D6E63),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (!isCompleted && !isWriting && !selectMode) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => onEditOutline(chapter),
                      child: const Text(
                        '修改大纲',
                        style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => onEditLedger(chapter),
                      child: const Text(
                        '账本',
                        style: TextStyle(fontSize: 11, color: Color(0xFF00897B)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isWriting && writingContent.isEmpty) ...[
              // 思考阶段无正文，仍提供进入全屏生成视图的入口
              const SizedBox(height: 6),
              GestureDetector(
                onTap: onOpenWriteView,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F4FF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '正在思考中，点击查看生成进度',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (isWriting && writingContent.isNotEmpty) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: onOpenWriteView,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    writingContent,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: Color(0xFF666666),
                    ),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 章节内容查看全屏页面（只读，可选中复制；右上角可直接进入编辑）。
/// 章节正在后台提炼账本/小结时，正文下方实时展示 AI 思考与输出进度。
class _ChapterViewPage extends StatefulWidget {
  final OutlineChapter chapter;
  final ChapterWriteController controller;
  final VoidCallback? onEdit;

  const _ChapterViewPage({
    required this.chapter,
    required this.controller,
    this.onEdit,
  });

  @override
  State<_ChapterViewPage> createState() => _ChapterViewPageState();
}

class _ChapterViewPageState extends State<_ChapterViewPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {}); // 提炼状态变化时刷新（面板显示/隐藏）
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapter;
    final processing = widget.controller.isProcessingChapter(chapter);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          chapter.eventTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (widget.onEdit != null)
            TextButton(
              onPressed: widget.onEdit,
              child: const Text(
                '编辑',
                style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // 提炼中提示条
          if (processing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              color: const Color(0xFFF0F4FF),
              child: Row(
                children: const [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '正在提炼剧情状态与整章小结...',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF4D6BFE),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                chapter.content,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.8,
                  color: Color(0xFF333333),
                ),
              ),
            ),
          ),
          // 提炼过程气泡（下方，提炼中实时展示）
          if (processing)
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.3,
              child: _ChapterProcessPanel(
                controller: widget.controller,
                chapter: chapter,
              ),
            ),
        ],
      ),
    );
  }
}

/// 章节编辑全屏页面
class _ChapterEditPage extends StatefulWidget {
  final OutlineChapter chapter;
  final ChapterWriteController controller; // 保存后的账本/小结提炼状态（气泡展示）
  final Future<void> Function(String) onSaved;

  const _ChapterEditPage({
    required this.chapter,
    required this.controller,
    required this.onSaved,
  });

  @override
  State<_ChapterEditPage> createState() => _ChapterEditPageState();
}

class _ChapterEditPageState extends State<_ChapterEditPage> {
  late final TextEditingController _controller;
  // 编辑历史：文本快照栈，支持撤回（undo）/ 前进（redo），最多保留 100 步
  static const _maxHistory = 100;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  String _lastSnapshot = '';
  bool _restoring = false; // 撤回/前进回写文本时不重复记录历史
  String _savedBaseline = ''; // 最近一次已保存的正文（返回时的未保存判定基准）
  bool _saving = false; // 保存中（账本/小结提炼进行中，气泡展示）
  Timer? _watchTimer; // 轻量轮询：提炼过程气泡实时刷新

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.chapter.content);
    _lastSnapshot = _controller.text;
    _savedBaseline = widget.chapter.content;
    _controller.addListener(_onTextChanged);
    _watchTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {}); // 账本/小结提炼状态与流式内容实时刷新
    });
  }

  @override
  void dispose() {
    _watchTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 每次文本变更前把上一个快照压入撤销栈；新输入清空前进栈
  void _onTextChanged() {
    if (_restoring) return;
    final current = _controller.text;
    if (current == _lastSnapshot) return;
    _undoStack.add(_lastSnapshot);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    _lastSnapshot = current;
    setState(() {}); // 刷新字数与撤回/前进按钮可用态
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_lastSnapshot);
    _lastSnapshot = _undoStack.removeLast();
    _applySnapshot();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_lastSnapshot);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _lastSnapshot = _redoStack.removeLast();
    _applySnapshot();
  }

  /// 回写快照文本并恢复光标到末尾（不记录历史）
  void _applySnapshot() {
    _restoring = true;
    _controller.text = _lastSnapshot;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _restoring = false;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final wordCount = _controller.text.characters.length;
    // 过程气泡可见：本页保存中，或本章正在后台提炼（退出编辑页后重新进入续显进度）
    final showProcess =
        _saving || widget.controller.isProcessingChapter(widget.chapter);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          widget.chapter.eventTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () {
            if (_saving) {
              // 提炼进行中：正文已保存，允许直接退出（后台继续完成提炼）
              Navigator.of(context).pop();
              return;
            }
            final content = _controller.text;
            if (content != _savedBaseline) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('未保存的修改'),
                  content: const Text('内容已修改，是否保存？'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        // 防重复点击：先关弹窗，再退出编辑页
                        if (!closeDialogSafely(ctx)) return;
                        Navigator.of(context).pop();
                      },
                      child: const Text(
                        '不保存',
                        style: TextStyle(color: Color(0xFF999999)),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        if (!closeDialogSafely(ctx)) return;
                        _saveAndProcess();
                      },
                      child: const Text(
                        '保存',
                        style: TextStyle(color: Color(0xFF4D6BFE)),
                      ),
                    ),
                  ],
                ),
              );
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          // 当前页面字数（实时更新）
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Center(
              child: Text(
                '$wordCount 字',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.undo, size: 20, color: Color(0xFF4D6BFE)),
            tooltip: '撤回',
            onPressed: (_saving || _undoStack.isEmpty) ? null : _undo,
          ),
          IconButton(
            icon: const Icon(Icons.redo, size: 20, color: Color(0xFF4D6BFE)),
            tooltip: '前进',
            onPressed: (_saving || _redoStack.isEmpty) ? null : _redo,
          ),
          TextButton(
            onPressed: _saving ? null : _saveAndProcess,
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    '保存',
                    style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 正文输入区（提炼进行中锁定输入，避免内容分叉）。
          // 用 Expanded + flex 按可用高度分配，键盘弹出时自动收缩，避免固定高度溢出
          Expanded(
            flex: showProcess ? 72 : 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                readOnly: _saving,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '在此编辑章节内容...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                  filled: true,
                  fillColor: const Color(0xFFFAFAFA),
                ),
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ),
          ),
          // 提炼过程气泡（账本提炼 → 整章小结）：本页保存中或本章正在后台提炼时展示
          if (showProcess) ...[
            const SizedBox(height: 8),
            Expanded(
              flex: 28,
              child: _ChapterProcessPanel(
                controller: widget.controller,
                chapter: widget.chapter,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 保存并展示提炼过程：正文先落盘（快），随后账本提炼 → 整章小结
  /// 在下方气泡实时展示（AI 思考 + 输出），全部完成弹提醒并返回列表
  Future<void> _saveAndProcess() async {
    if (_saving) return;
    final text = _controller.text;
    setState(() => _saving = true);
    _savedBaseline = text; // 正文即将保存：先更新基线，中途退出不再误报未保存
    await widget.onSaved(text);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已保存，剧情账本与整章小结已更新'),
        duration: Duration(seconds: 2),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }
}


/// 章节提炼过程面板：账本提炼 → 整章小结 的 AI 思考/输出气泡，
/// 500ms 轮询实时刷新；章节不在提炼中时隐藏。
/// 供编辑页（保存中/重新进入）、查看页（提炼中续显进度）复用。
class _ChapterProcessPanel extends StatefulWidget {
  final ChapterWriteController controller;
  final OutlineChapter chapter;
  const _ChapterProcessPanel({
    required this.controller,
    required this.chapter,
  });

  @override
  State<_ChapterProcessPanel> createState() => _ChapterProcessPanelState();
}

class _ChapterProcessPanelState extends State<_ChapterProcessPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {}); // 提炼状态与流式内容实时刷新
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // 不在提炼中（或提炼的不是本章）时不占位
    if (!c.isProcessingChapter(widget.chapter)) {
      return const SizedBox.shrink();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        // 阶段提示条
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F4FF),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.extractingStory
                      ? '正在提炼剧情状态账本...'
                      : '正在提炼整章小结...',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF4D6BFE),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 账本提炼（思考 + 输出）
        if (c.extractingStory ||
            c.storyStateThinking.trim().isNotEmpty ||
            c.storyStateText.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          if (c.storyStateThinking.trim().isNotEmpty) ...[
            _bubble(
              icon: Icons.psychology_alt,
              title: '账本提炼思考',
              content: c.storyStateThinking,
              emptyHint: '',
            ),
            const SizedBox(height: 6),
          ],
          _bubble(
            icon: Icons.menu_book,
            title: '剧情状态账本',
            content: c.storyStateText,
            emptyHint: '正在提炼中...',
          ),
        ],
        // 整章小结（思考 + 输出）
        if (c.summarizingChapter ||
            c.chapterSummaryThinkingText.trim().isNotEmpty ||
            c.chapterSummaryOutputText.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          if (c.chapterSummaryThinkingText.trim().isNotEmpty) ...[
            _bubble(
              icon: Icons.psychology_alt,
              title: '小结提炼思考',
              content: c.chapterSummaryThinkingText,
              emptyHint: '',
            ),
            const SizedBox(height: 6),
          ],
          _bubble(
            icon: Icons.notes,
            title: '整章小结',
            content: c.chapterSummaryOutputText,
            emptyHint: '正在提炼中...',
            color: const Color(0xFFF1F8E9),
            borderColor: const Color(0xFFDCEDC8),
            iconColor: const Color(0xFF558B2F),
          ),
        ],
      ],
    );
  }

  Widget _bubble({
    required IconData icon,
    required String title,
    required String content,
    required String emptyHint,
    Color color = const Color(0xFFF0F4FF),
    Color borderColor = const Color(0xFFD8E2FF),
    Color iconColor = const Color(0xFF4D6BFE),
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: iconColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            content.trim().isEmpty ? emptyHint : content,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Color(0xFF666666),
            ),
          ),
        ],
      ),
    );
  }
}
/// 章节生成前的字数输入弹窗：返回用户输入的目标字数；取消/关闭返回 null。
class _WordCountDialog extends StatefulWidget {
  final int initialWords;
  const _WordCountDialog({required this.initialWords});

  @override
  State<_WordCountDialog> createState() => _WordCountDialogState();
}

class _WordCountDialogState extends State<_WordCountDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.initialWords}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final n = int.tryParse(_ctrl.text.trim());
    if (n == null || n <= 0) {
      setState(() => _error = '请输入有效的字数（大于 0 的整数）');
      return;
    }
    Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        '设置本章字数',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '输入本章目标字数，将覆盖设置中的默认范围',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '如：3000',
              errorText: _error,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 14),
            onSubmitted: (_) => _confirm(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Color(0xFF999999))),
        ),
        TextButton(
          onPressed: _confirm,
          child: const Text(
            '开始生成',
            style: TextStyle(
              color: Color(0xFF4D6BFE),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
