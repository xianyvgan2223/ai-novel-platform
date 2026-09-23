import 'package:flutter/material.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/outline_event_parser.dart';
import 'outline_edit_page.dart';

/// 「大纲编辑」章节选择页。
///
/// 勾选一章或多章后进入编辑页；也可以点章节右侧「编辑」直接编辑单章。
/// 该小说若还没在「大纲转章节」里解析过章节，会先按大纲正文解析并落库，
/// 保证「大纲编辑」可以直接使用。
class OutlineEditChapterListPage extends StatefulWidget {
  final OutlineRecord outline;

  const OutlineEditChapterListPage({super.key, required this.outline});

  @override
  State<OutlineEditChapterListPage> createState() =>
      _OutlineEditChapterListPageState();
}

class _OutlineEditChapterListPageState
    extends State<OutlineEditChapterListPage> {
  List<OutlineChapter> _chapters = [];
  final Set<int> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.outline.id;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      var rows = await OutlineChapterDbHelper().getByOutlineId(id);
      if (rows.isEmpty) {
        // 首次进入且尚未解析章节：与「大纲转章节」首次进入行为一致，
        // 解析大纲正文中的事件并入库（保留正文为空，由用户编辑或后续生成）
        final parsed = parseOutlineEvents(
          widget.outline.content,
          outlineId: id,
        );
        await OutlineChapterDbHelper().batchInsert(
          parsed.map((c) => c.toMap()).toList(),
        );
        rows = await OutlineChapterDbHelper().getByOutlineId(id);
      }
      _chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      _selected.removeWhere(
        (sid) => !_chapters.any((c) => c.id == sid),
      );
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<OutlineChapter> get _selectedChapters =>
      _chapters.where((c) => c.id != null && _selected.contains(c.id)).toList();

  bool get _allSelected =>
      _chapters.isNotEmpty &&
      _chapters.every((c) => c.id != null && _selected.contains(c.id));

  void _toggleSelect(OutlineChapter ch) {
    final id = ch.id;
    if (id == null) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_chapters.map((c) => c.id).whereType<int>());
      }
    });
  }

  /// 打开编辑页：[chapters] 为待编辑章节（单章或多章）
  Future<void> _openEdit(List<OutlineChapter> chapters) async {
    if (chapters.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            OutlineEditPage(outline: widget.outline, chapters: chapters),
      ),
    );
    if (mounted) await _load();
  }

  int get _completedCount =>
      _chapters.where((c) => c.status == 'completed').length;

  @override
  Widget build(BuildContext context) {
    final outline = widget.outline;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          outline.title.isNotEmpty ? outline.title : '选择章节',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      bottomNavigationBar: _loading ? null : _buildBottomBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _chapters.isEmpty
          ? const Center(
              child: Text(
                '该小说没有可编辑的章节',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  color: const Color(0xFFF8F9FF),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '共 ${_chapters.length} 个事件 · 已完成 $_completedCount',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF666666),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '勾选一章或多章后可批量编辑；点右侧「编辑」直接编辑单章',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      final ch = _chapters[index];
                      return _ChapterSelectTile(
                        chapter: ch,
                        selected: ch.id != null && _selected.contains(ch.id),
                        onTap: () => _toggleSelect(ch),
                        onEdit: () => _openEdit([ch]),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildBottomBar() {
    final count = _selected.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            Text(
              '已选 $count 章',
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
            TextButton(
              onPressed: _chapters.isEmpty ? null : _toggleSelectAll,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(
                _allSelected ? '取消全选' : '全选',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: count == 0 ? null : () => _openEdit(_selectedChapters),
              icon: const Icon(Icons.edit_note, size: 18),
              label: Text(count <= 1 ? '编辑该章' : '编辑所选（$count）'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4D6BFE),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE8ECF4),
                disabledForegroundColor: const Color(0xFF999999),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个章节选择卡片：左侧复选框，点卡片切换选中；右侧「编辑」直接编辑单章
class _ChapterSelectTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _ChapterSelectTile({
    required this.chapter,
    required this.selected,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isMajor = chapter.eventType == 'major';
    final isCompleted = chapter.status == 'completed';
    final words = chapter.content.characters.length;
    final statusText = chapter.status == 'generating'
        ? '生成中'
        : (isCompleted ? '已生成' : '待生成');
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        decoration: BoxDecoration(
          color: isMajor ? const Color(0xFFF8F9FF) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF4D6BFE)
                : (isCompleted
                      ? const Color(0xFFE0F0E0)
                      : const Color(0xFFE8ECF4)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => onTap(),
              activeColor: const Color(0xFF4D6BFE),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isMajor ? Icons.flag : Icons.article_outlined,
                        size: 16,
                        color: isMajor
                            ? const Color(0xFF4D6BFE)
                            : const Color(0xFF999999),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          chapter.eventTitle,
                          style: TextStyle(
                            fontSize: isMajor ? 14 : 13,
                            fontWeight: isMajor
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: const Color(0xFF333333),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: isMajor
                              ? const Color(0xFFE8ECF4)
                              : const Color(0xFFF2F4F8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isMajor ? '大事件' : '章节',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    chapter.eventSummary.trim().isEmpty
                        ? '暂无概要'
                        : chapter.eventSummary.trim(),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: Color(0xFF999999),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isMajor ? statusText : '$statusText · $words 字',
                    style: TextStyle(
                      fontSize: 10,
                      color: isCompleted
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFBBBBBB),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                '编辑',
                style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
