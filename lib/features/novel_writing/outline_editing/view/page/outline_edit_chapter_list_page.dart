import 'package:flutter/material.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
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
      OutlineEditChapterListPageState();
}

/// State 类公开（原本是私有的 `_OutlineEditChapterListPageState`）：
/// 多选的底部操作栏只在「勾了章节」时才有内容，而勾选要经过卡片点击、
/// 卡片又要先读库——测试环境没有 sqflite，读库必失败，卡片压根渲染不出来。
/// 因此这里公开两个测试钩子（`debugSetSelectedForTest` / `debugSelectedForTest`），
/// 让 `test/outline_edit_multi_select_test.dart` 能直接摆出勾选状态验底部栏。
class OutlineEditChapterListPageState
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
  ///
  /// 具体实现抽在 `shared/outline_chapter_sync.dart` 的 [latestOutlineRecord]：
  /// 「听大纲改名」页也要按最新正文校正事件结构，两处必须是同一套口径。
  Future<OutlineRecord> _latestRecord(int id) => latestOutlineRecord(_outline);

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

  /// 是否已经全选（用来把「全选」按钮置灰，不再兼作「取消全选」的开关）
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

  /// 全选：一次勾上全部事件。**只做全选，不再兼任「取消全选」**。
  ///
  /// 原先这个按钮是双向开关（全选 ☑ 后变成「取消全选」），而它要取消的东西
  /// 与「取消选择」完全重复——两个按钮做同一件事，还容易点错（想全选却点了取消）。
  /// 现在清空只剩「取消选择」一个出口：按钮 label 恒为「全选」，已经全选时置灰。
  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_chapters.map((c) => c.id).whereType<int>());
    });
  }

  /// 取消多选：清空已勾选的事件。
  ///
  /// 「编辑所选（N）」是进编辑页，这个方法是**唯一的清空出口**：底部计数旁的
  /// 「取消选择」，以及返回键 / 返回手势都走它。
  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() => _selected.clear());
  }

  /// 测试钩子：直接摆出章节列表与勾选状态（见类注释）。生产代码不调用。
  @visibleForTesting
  void debugSetSelectedForTest(Set<int> ids, {List<OutlineChapter>? chapters}) {
    setState(() {
      if (chapters != null) _chapters = chapters;
      _selected
        ..clear()
        ..addAll(ids);
    });
  }

  /// 测试钩子：读当前勾选（见类注释）。
  @visibleForTesting
  Set<int> get debugSelectedForTest => Set<int>.unmodifiable(_selected);

  /// 打开编辑页：[chapters] 为待编辑章节（单章或多章）。
  ///
  /// 传下去的是 [_outline]（带**库里最新正文**的那一份），不是 `widget.outline`：
  /// 编辑页的 controller 拿它当初始正文，落后一份快照的话，进页面后立刻删除 /
  /// 新增事件就会按旧序号写到正文的另一处。
  ///
  /// 返回后按静默方式刷新（编辑页可能改了标题 / 概要），并把列表定位回
  /// 进入编辑页时所显示的区域，而不是跳回顶部（见 shared/list_scroll_offset.dart）。
  /// 顺手清掉勾选：批量编辑已经完成，留着勾选会让下一眼误以为还要再点一次
  /// 「编辑所选（N）」。（刷新时本来也会剔掉已不存在的章节，这里一并清空更干脆。）
  Future<void> _openEdit(List<OutlineChapter> chapters) async {
    if (chapters.isEmpty) return;
    final offset = captureScrollOffset(_scrollCtrl);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineEditPage(outline: _outline, chapters: chapters),
      ),
    );
    if (!mounted) return;
    setState(() => _selected.clear());
    await _load(showLoading: false);
    if (!mounted) return;
    restoreScrollOffset(_scrollCtrl, offset);
  }

  int get _completedCount =>
      _chapters.where((c) => c.status == 'completed').length;

  /// 返回键 / 返回手势：勾了章节时先取消多选，第二次才真正退出页面。
  /// （勾选是页面内的临时状态，返回键顺手把它清掉，免得退出去再进来还留着）
  void _onBackPressed() {
    if (_selected.isNotEmpty) {
      _clearSelection();
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final outline = _outline;
    // 大 / 小事件序号：与大纲正文里的「大事件N」/「○ 小事件N」同一套编号
    // （大事件只数大事件；小事件在每个大事件内部从 1 重新开始），
    // 显示在卡片的类型标签上（大事件57 / 小事件2），方便对上正文与生成记录
    final majorNumbers = majorEventNumbers(_chapters);
    final minorNumbers = minorEventNumbers(_chapters);
    return PopScope(
      // 系统返回手势与顶栏返回键保持同一套行为：先取消多选，再退出页面。
      // 否则手势一划就把页面退掉，勾选白选了（顶栏按钮却是先清勾选）。
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _clearSelection();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(
            outline.title.isNotEmpty ? outline.title : '选择事件',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: Colors.white,
          elevation: 0.5,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
            onPressed: _onBackPressed,
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
                  '该小说没有可编辑的事件',
                  style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
                ),
              )
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: const Color(0xFFF8F9FF),
                    child: Text(
                      '共 ${_chapters.length} 个事件 · 已完成 $_completedCount',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(10),
                      itemCount: _chapters.length,
                      itemBuilder: (context, index) {
                        final ch = _chapters[index];
                        return _ChapterSelectTile(
                          chapter: ch,
                          selected: ch.id != null && _selected.contains(ch.id),
                          majorNumber: majorNumbers[index],
                          minorNumber: minorNumbers[index],
                          onTap: () => _toggleSelect(ch),
                          onEdit: () => _openEdit([ch]),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 底部操作栏：已选数量 + 取消选择 + 全选 + 编辑所选。
  ///
  /// 尺寸刻意压小：这一行在 360dp 宽的手机上本来只剩 336dp（减去左右各 12 的
  /// 内边距），而「已选 N 个事件 + 取消选择 + 全选 + 带图标的大按钮」按原尺寸
  /// （计数 13 / 按钮 13 + 左右各 10 / 主按钮 14 + 图标 18 + 左右各 16）实测
  /// **溢出 17px**（真机上就是按钮右边那条黄黑警示条）。现在：字号 13 → 12、
  /// 主按钮去掉图标（标签本身已经说清是编辑）、内边距 16 → 12，宽度降到 296dp。
  ///
  /// 另外给两处文字都加了省略兜底：极窄屏或系统大字体下宁可截断，也不再溢出。
  Widget _buildBottomBar() {
    final count = _selected.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                '已选 $count 个事件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
            ),
            // 取消多选：勾了事件才出现，一键把勾选清零
            if (count > 0)
              TextButton(
                onPressed: _clearSelection,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text(
                  '取消选择',
                  style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                ),
              ),
            // 全选：只做全选。清空勾选交给「取消选择」，两个按钮不再重复
            TextButton(
              onPressed: (_chapters.isEmpty || _allSelected) ? null : _selectAll,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('全选', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: ElevatedButton(
                onPressed: count == 0
                    ? null
                    : () => _openEdit(_selectedChapters),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4D6BFE),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFE8ECF4),
                  disabledForegroundColor: const Color(0xFF999999),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(
                  count <= 1 ? '编辑该事件' : '编辑所选（$count）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
/// 类型标签上带序号（大事件57 / 小事件2），与大纲正文的写法一致。
class _ChapterSelectTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool selected;

  /// 大事件序号（全篇只数大事件，从 1 连续）；非大事件为 null
  final int? majorNumber;

  /// 小事件序号（在所属大事件内部从 1 重新计数）；非小事件为 null
  final int? minorNumber;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _ChapterSelectTile({
    required this.chapter,
    required this.selected,
    this.majorNumber,
    this.minorNumber,
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
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
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
            // 复选框：默认 48dp 的点击区在长列表里太占地方，收成 32dp
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                value: selected,
                onChanged: (_) => onTap(),
                activeColor: const Color(0xFF4D6BFE),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isMajor ? Icons.flag : Icons.article_outlined,
                        size: 14,
                        color: isMajor
                            ? const Color(0xFF4D6BFE)
                            : const Color(0xFF999999),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          chapter.eventTitle,
                          style: TextStyle(
                            fontSize: isMajor ? 13 : 12,
                            fontWeight: isMajor
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: const Color(0xFF333333),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      EventTypeTag(
                        isMajor: isMajor,
                        majorNumber: majorNumber,
                        minorNumber: minorNumber,
                        background: isMajor
                            ? const Color(0xFFE8ECF4)
                            : const Color(0xFFF2F4F8),
                        foreground: const Color(0xFF666666),
                        // 序号用主色加粗：长列表里一眼能扫到第几个大事件 / 小事件
                        numberColor: const Color(0xFF4D6BFE),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    chapter.eventSummary.trim().isEmpty
                        ? '暂无概要'
                        : chapter.eventSummary.trim(),
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.35,
                      color: Color(0xFF999999),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isMajor ? statusText : '$statusText · $words 字',
                    style: TextStyle(
                      fontSize: 9,
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
                style: TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
