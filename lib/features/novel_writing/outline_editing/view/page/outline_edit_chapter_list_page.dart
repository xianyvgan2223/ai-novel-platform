import 'package:flutter/material.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/list_scroll_offset.dart';
import '../../../shared/outline_chapter_sync.dart';
import '../../../shared/outline_load_error_view.dart';
import '../widget/event_type_tag.dart';
import 'outline_edit_page.dart';

/// 「大纲编辑」章节选择页。
///
/// 点章节卡片上的复选框可就地勾选，页面底部按勾选数量进入编辑页（单章 / 多章）；
/// 也可以点章节右侧「编辑」直接编辑单章。
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

  /// 当前这一份大纲记录：**每次读章节前都按库里的最新正文刷新一次**
  /// （见 [_latestRecord]）。进入编辑页也传它，编辑页的初始正文才不会落后。
  late OutlineRecord _outline = widget.outline;

  /// 列表滚动控制器：进入编辑页前记下位置，返回时按它停回同一区域
  final ScrollController _scrollCtrl = ScrollController();
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 校正章节结构用的那份记录：**以库里最新写下的正文为准**。
  ///
  /// 为什么不能直接用 `widget.outline.content`：它是打开这本小说时的快照，
  /// 而「大纲编辑」页保存时把改过的正文直接写进库、并不回填内存
  /// （`OutlineRecord.content` 是 final）。拿旧快照校正的后果是**删掉的事件
  /// 又长回来**：正文里已经没有它、库里的行也删了，按标题一条都匹配不上，
  /// 校正逻辑便把它当成「新增的事件」重新 INSERT——用户看到的现象正是
  /// 「小事件怎么删都删不掉，删完返回列表它还在」；改过的标题 / 概要同样会被
  /// 按旧快照翻回旧值。
  ///
  /// 正文为空是有效状态（用户可能把事件全删了），必须照它清空结构，
  /// 所以只在**读失败 / 记录已不存在**时才退回快照。
  Future<OutlineRecord> _latestRecord(int id) async {
    try {
      final content = await OutlineRecordDbHelper().getContentById(id);
      if (content == null || content == widget.outline.content) {
        return widget.outline;
      }
      // content 是 final：套一份带最新正文的记录（其余字段原样带过来）
      return OutlineRecord.fromMap({
        ...widget.outline.toMap(),
        'id': id,
        'content': content,
      });
    } catch (e, st) {
      debugPrint('[outline_edit_chapters] 读取最新大纲正文失败 outline=$id：$e\n$st');
      return widget.outline;
    }
  }

  /// 读取章节结构。
  ///
  /// [showLoading] 为 false 时保留当前列表、不切成整页 loading：从编辑页
  /// 返回后的刷新走这条路径——整页 loading 会把 ListView 从树上拆掉，
  /// 滚动位置随之丢失，返回时界面就跳回顶部了。
  Future<void> _load({bool showLoading = true}) async {
    final id = widget.outline.id;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) {
      setState(() {
        if (showLoading) _loading = true;
        _error = null;
      });
    }
    try {
      final record = await _latestRecord(id);
      // 与「大纲转章节」共用同一套无损校正（shared/outline_chapter_sync.dart）：
      // 首次进入按大纲正文解析入库；之后进入则按最新正文校正结构。
      // 旧版只在章节表为空时才解析，导致解析规则修复后旧数据永远不自愈，
      // 页面一直显示错误的章节结构。
      await reconcileOutlineChapters(
        outlineId: id,
        content: record.content,
      );
      final rows = await OutlineChapterDbHelper().getByOutlineId(id);
      _chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      _selected.removeWhere((sid) => !_chapters.any((c) => c.id == sid));
      _outline = record;
    } catch (e, st) {
      // 结构校正或读取失败：以前静默吞掉，界面会误显示「没有可编辑的章节」
      debugPrint('[outline_edit_chapters] 加载章节失败 outline=$id：$e\n$st');
      _chapters = [];
      _error = e;
    }
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

  /// 打开编辑页：[chapters] 为待编辑章节（单章或多章）。
  ///
  /// 传下去的是 [_outline]（带**库里最新正文**的那一份），不是 `widget.outline`：
  /// 编辑页的 controller 拿它当初始正文，落后一份快照的话，进页面后立刻删除 /
  /// 新增事件就会按旧序号写到正文的另一处。
  ///
  /// 返回后按静默方式刷新（编辑页可能改了标题 / 概要），并把列表定位回
  /// 进入编辑页时所显示的区域，而不是跳回顶部（见 shared/list_scroll_offset.dart）。
  Future<void> _openEdit(List<OutlineChapter> chapters) async {
    if (chapters.isEmpty) return;
    final offset = captureScrollOffset(_scrollCtrl);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineEditPage(outline: _outline, chapters: chapters),
      ),
    );
    if (!mounted) return;
    await _load(showLoading: false);
    if (!mounted) return;
    restoreScrollOffset(_scrollCtrl, offset);
  }

  int get _completedCount =>
      _chapters.where((c) => c.status == 'completed').length;

  @override
  Widget build(BuildContext context) {
    final outline = _outline;
    // 大事件序号：与大纲正文里的「大事件N」同一套编号（只数大事件），
    // 显示在卡片的类型标签上（大事件57），方便对上正文与生成记录
    final majorNumbers = majorEventNumbers(_chapters);
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
          : _error != null
          ? OutlineLoadErrorView(error: _error!, onRetry: _load)
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
                  child: Text(
                    '共 ${_chapters.length} 个事件 · 已完成 $_completedCount',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF666666),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      final ch = _chapters[index];
                      return _ChapterSelectTile(
                        chapter: ch,
                        selected: ch.id != null && _selected.contains(ch.id),
                        majorNumber: majorNumbers[index],
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

/// 单个章节选择卡片：左侧复选框，点卡片切换选中；右侧「编辑」直接编辑单章。
/// 大事件的类型标签上带序号（大事件57），与大纲正文的写法一致。
class _ChapterSelectTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool selected;

  /// 大事件序号（从 1 开始，只数大事件）；非大事件为 null
  final int? majorNumber;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _ChapterSelectTile({
    required this.chapter,
    required this.selected,
    this.majorNumber,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isMajor = chapter.isMajor;
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
                      EventTypeTag(
                        isMajor: isMajor,
                        majorNumber: majorNumber,
                        background: isMajor
                            ? const Color(0xFFE8ECF4)
                            : const Color(0xFFF2F4F8),
                        foreground: const Color(0xFF666666),
                        // 序号用主色加粗：长列表里一眼能扫到第几个大事件
                        numberColor: const Color(0xFF4D6BFE),
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
