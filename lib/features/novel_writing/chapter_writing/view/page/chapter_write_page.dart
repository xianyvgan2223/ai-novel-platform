import 'package:flutter/material.dart';
import '../../../shared/models/outline_record.dart';
import '../../../shared/models/outline_chapter.dart';
import '../../../shared/models/db/outline_chapter_db_helper.dart';
import 'outline_setting_page.dart';
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

  @override
  void initState() {
    super.initState();
    _controller = ChapterWriteController(widget.outline);
    _controller.initLoad().then((_) {
      if (mounted) setState(() {});
      if (mounted && _controller.needsResync) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _showResyncDialog(),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Color(0xFF666666)),
            tooltip: 'AI 设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OutlineSettingPage()),
              );
            },
          ),
        ],
      ),
      body: _controller.isLoading
          ? const Center(child: CircularProgressIndicator())
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
                        : '${_controller.completedCount}/${_controller.chapters.length} 个事件已完成',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF666666),
                    ),
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
                        isWriting: _controller.writingId == ch.id,
                        writingContent: _controller.writingId == ch.id
                            ? _controller.writingText
                            : '',
                        onWrite: () => _controller.startWrite(
                          context,
                          ch,
                          () => setState(() {}),
                        ),
                        onView: () => _showContentDialog(ch),
                        onEdit: (c) => _openEditPage(c),
                        onEditOutline: (c) => _showEditOutlineDialog(c),
                        onDelete: () async {
                          await OutlineChapterDbHelper().updateContent(
                            ch.id!,
                            '',
                          );
                          _controller.chapters[index] = ch.copyWith(
                            content: '',
                            status: 'pending',
                          );
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
    );
  }

  void _showContentDialog(OutlineChapter ch) {
    if (ch.content.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          ch.eventTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              ch.content,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
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
                                Navigator.of(ctx2).pop();
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => editCtrl.dispose(),
                                );
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
                                summaryCtrl.text = editCtrl.text;
                                Navigator.of(ctx2).pop();
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => editCtrl.dispose(),
                                );
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
            onPressed: () => Navigator.of(ctx).pop(),
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
              final oldCh = _controller.chapters.firstWhere(
                (c) => c.id == ch.id,
              );
              await OutlineChapterDbHelper().updateSummary(
                ch.id!,
                title,
                summary,
              );
              await _controller.syncEventToOutline(oldCh, title, summary);
              final idx = _controller.chapters.indexWhere((c) => c.id == ch.id);
              if (idx != -1) {
                _controller.chapters[idx] = _controller.chapters[idx].copyWith(
                  eventTitle: title,
                  eventSummary: summary,
                );
                setState(() {});
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
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
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('忽略', style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
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

  /// 打开章节编辑全屏页面
  void _openEditPage(OutlineChapter ch) {
    if (ch.id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ChapterEditPage(
          chapter: ch,
          onSaved: (newContent) async {
            await OutlineChapterDbHelper().updateContent(ch.id!, newContent);
            final idx = _controller.chapters.indexWhere((c) => c.id == ch.id);
            if (idx != -1) {
              _controller.chapters[idx] = _controller.chapters[idx].copyWith(
                content: newContent,
                status: 'completed',
              );
              setState(() {});
            }
          },
        ),
      ),
    );
  }
}

/// 单个事件卡片
class _ChapterTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool isWriting;
  final String writingContent;
  final VoidCallback onWrite;
  final VoidCallback onView;
  final VoidCallback onDelete;
  final void Function(OutlineChapter) onEdit;
  final void Function(OutlineChapter) onEditOutline;

  const _ChapterTile({
    required this.chapter,
    required this.isWriting,
    required this.writingContent,
    required this.onWrite,
    required this.onView,
    required this.onDelete,
    required this.onEdit,
    required this.onEditOutline,
  });

  @override
  Widget build(BuildContext context) {
    final isMajor = chapter.eventType == 'major';
    final isCompleted = chapter.status == 'completed';

    return Container(
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
              if (isWriting)
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
                    onPressed: onWrite,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4D6BFE),
                      foregroundColor: Colors.white,
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
          if (isCompleted && !isWriting) ...[
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
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认删除'),
                        content: const Text('确定要删除已生成的内容吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
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
          if (!isCompleted && !isWriting)
            GestureDetector(
              onTap: () => onEditOutline(chapter),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '修改大纲',
                  style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
                ),
              ),
            ),
          if (isWriting && writingContent.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
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
          ],
        ],
      ),
    );
  }
}

/// 章节编辑全屏页面
class _ChapterEditPage extends StatefulWidget {
  final OutlineChapter chapter;
  final ValueChanged<String> onSaved;

  const _ChapterEditPage({required this.chapter, required this.onSaved});

  @override
  State<_ChapterEditPage> createState() => _ChapterEditPageState();
}

class _ChapterEditPageState extends State<_ChapterEditPage> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.chapter.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            final content = _controller.text;
            if (content != widget.chapter.content) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('未保存的修改'),
                  content: const Text('内容已修改，是否保存？'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).pop();
                      },
                      child: const Text(
                        '不保存',
                        style: TextStyle(color: Color(0xFF999999)),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _saveAndGoBack();
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
          TextButton(
            onPressed: _saveAndGoBack,
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
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
    );
  }

  void _saveAndGoBack() {
    widget.onSaved(_controller.text);
    Navigator.of(context).pop();
  }
}
