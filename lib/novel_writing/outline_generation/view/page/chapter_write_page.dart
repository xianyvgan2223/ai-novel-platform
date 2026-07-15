import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../../model/outline_record.dart';
import '../../model/outline_chapter.dart';
import '../../model/outline_setting.dart';
import '../../model/db/outline_db_helper.dart';
import '../../model/db/outline_chapter_db_helper.dart';
import 'outline_setting_page.dart';

/// 大纲转章节写作页面
class ChapterWritePage extends StatefulWidget {
  final OutlineRecord outline;
  const ChapterWritePage({super.key, required this.outline});

  @override
  State<ChapterWritePage> createState() => _ChapterWritePageState();
}

class _ChapterWritePageState extends State<ChapterWritePage> {
  late final _ChapterWriteController _controller;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = _ChapterWriteController(widget.outline);
    _controller.initLoad().then((_) => setState(() {}));
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
              await OutlineChapterDbHelper().updateSummary(
                ch.id!,
                title,
                summary,
              );
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

/// 章节写作控制器
class _ChapterWriteController {
  final OutlineRecord outline;
  final _apiService = ApiService();

  _ChapterWriteController(this.outline);

  List<OutlineChapter> chapters = [];
  bool isLoading = true;
  bool isWriting = false;
  int? writingId;
  String writingText = '';
  CancelToken? _cancelToken;

  bool get isAllCompleted => chapters.every((c) => c.status == 'completed');
  int get completedCount =>
      chapters.where((c) => c.status == 'completed').length;

  Future<void> initLoad() async {
    isLoading = true;
    try {
      final rows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      if (rows.isNotEmpty) {
        chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      } else {
        chapters = _parseEvents(outline.content);
        await OutlineChapterDbHelper().batchInsert(
          chapters.map((c) => c.toMap()).toList(),
        );
        final newRows = await OutlineChapterDbHelper().getByOutlineId(
          outline.id!,
        );
        chapters = newRows.map((m) => OutlineChapter.fromMap(m)).toList();
      }
    } catch (_) {}
    isLoading = false;
  }

  /// 开始生成
  Future<void> startWrite(
    BuildContext context,
    OutlineChapter ch,
    VoidCallback onUpdate,
  ) async {
    if (ch.id == null) return;
    final settings = await OutlineDbHelper().getSettings();
    if (settings == null) return;

    final prevContent = await _loadPrevSummary(ch);

    final prompt =
        '''
你是一位小说作家。请根据以下大纲设定，完整写出指定事件的详细章节内容。

【小说设定】
类型：${outline.genre}
主题：${outline.theme}
主角：${outline.protagonist}

【大纲结构】
${outline.content}

【当前事件】${ch.eventTitle}
【事件概要】${ch.eventSummary}

【前文摘要】${prevContent}

要求：
1. 以文学性强的叙述方式展开，包含场景描写、对话、心理活动
2. 字数 2000-3000 字
3. 结尾自然衔接下一个事件
4. 只写当前事件的内容，不要超出范围
5. 直接输出正文，不要添加注释说明
''';

    final apiKey = (await UserSettingService.getSettings()).apiKey;
    if (apiKey.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先在设置中填写 API Key')));
      }
      return;
    }

    isWriting = true;
    writingId = ch.id;
    writingText = '';
    _cancelToken = CancelToken();
    onUpdate();

    await OutlineChapterDbHelper().updateStatus(ch.id!, 'generating');

    try {
      final setting = OutlineSetting.fromMap(settings);
      await _apiService.streamChat(
        apiKey: apiKey,
        apiParams: {
          'model': setting.model,
          'temperature': setting.temperature,
          'max_tokens': setting.maxTokens,
          'stream': true,
        },
        messages: [
          {
            'role': 'system',
            'content': setting.chapterSystemPrompt.isNotEmpty
                ? setting.chapterSystemPrompt
                : '你是一个专业的小说作家。',
          },
          {'role': 'user', 'content': prompt},
        ],
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;
          final text = delta['content'] as String?;
          if (text != null) {
            writingText += text;
            onUpdate();
          }
        },
        onDone: () {
          _cancelToken = null;
          if (writingText.isNotEmpty) {
            OutlineChapterDbHelper().updateContent(ch.id!, writingText);
            final idx = chapters.indexWhere((c) => c.id == ch.id);
            if (idx != -1) {
              chapters[idx] = chapters[idx].copyWith(
                content: writingText,
                status: 'completed',
              );
            }
          }
          isWriting = false;
          writingId = null;
          onUpdate();
        },
        onError: (_) {
          _cancelToken = null;
          if (writingText.isNotEmpty) {
            OutlineChapterDbHelper().updateContent(ch.id!, writingText);
          } else {
            OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
          }
          isWriting = false;
          writingId = null;
          onUpdate();
        },
      );
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (writingText.isNotEmpty) {
          OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        } else {
          await OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
        }
      }
      isWriting = false;
      writingId = null;
      onUpdate();
    }
  }

  void stopWrite() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  void dispose() {
    stopWrite();
  }

  List<OutlineChapter> _parseEvents(String content) {
    final lines = content.split('\n');
    final result = <OutlineChapter>[];
    int eventIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      final majorMatch = RegExp(
        r'══\s*(大事件\d*|事件\d*|Major\s*\d*)\s*[：:]\s*(.+?)\s*══',
      ).firstMatch(trimmed);
      if (majorMatch != null) {
        eventIndex++;
        final title = majorMatch.group(2)?.trim() ?? '大事件$eventIndex';
        result.add(
          OutlineChapter(
            outlineId: outline.id!,
            eventIndex: eventIndex,
            eventType: 'major',
            eventTitle: title,
          ),
        );
        continue;
      }
      if (trimmed.startsWith('══') && trimmed.endsWith('══')) {
        continue;
      }
      final minorMatch = RegExp(
        r'[○\-]\s*(小事件\d*|事件\d*)\s*[：:]\s*(.+?)$',
      ).firstMatch(trimmed);
      if (minorMatch != null) {
        eventIndex++;
        final title = minorMatch.group(2)?.trim() ?? '小事件$eventIndex';
        result.add(
          OutlineChapter(
            outlineId: outline.id!,
            eventIndex: eventIndex,
            eventType: 'minor',
            eventTitle: title,
          ),
        );
        continue;
      }
      if (result.isNotEmpty &&
          trimmed.isNotEmpty &&
          !trimmed.startsWith('══') &&
          !trimmed.startsWith('○') &&
          !trimmed.startsWith('-')) {
        final last = result.last;
        if (last.eventSummary.isEmpty && !trimmed.contains('第')) {
          result[result.length - 1] = last.copyWith(eventSummary: trimmed);
        }
      }
    }

    if (result.isEmpty) {
      result.add(
        OutlineChapter(
          outlineId: outline.id!,
          eventIndex: 1,
          eventType: 'major',
          eventTitle: '正文',
        ),
      );
    }

    return result;
  }

  Future<String> _loadPrevSummary(OutlineChapter currentCh) async {
    if (currentCh.id == null) return '';
    final all = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
    final prevs = all
        .map((m) => OutlineChapter.fromMap(m))
        .where(
          (c) => c.status == 'completed' && c.eventIndex < currentCh.eventIndex,
        )
        .toList();
    if (prevs.isEmpty) return '故事刚开始，没有前文。';
    return prevs
        .map(
          (c) =>
              '【${c.eventTitle}】\n${c.content.substring(0, c.content.length > 200 ? 200 : c.content.length)}...',
        )
        .join('\n\n');
  }
}
