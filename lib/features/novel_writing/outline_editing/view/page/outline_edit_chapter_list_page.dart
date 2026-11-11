import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../shared/monochrome_palette.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/list_scroll_offset.dart';
import '../../../shared/outline_chapter_sync.dart';
import '../../../shared/outline_load_error_view.dart';
import '../widget/event_type_tag.dart';
import '../widget/outline_settings_edit_sheet.dart';
import 'outline_edit_page.dart';

/// 「大纲编辑」事件选择页。
///
/// 默认不显示复选框：**点卡片进入编辑，长按卡片进入多选**；进入多选后
/// 卡片左侧才出现复选框，点卡片切换勾选，底部出现多选操作栏（编辑所选）。
/// 顶栏右侧「小说设定」可编辑书名 / 类型 / 主题 / 主角简介 / 世界观。
/// 该小说若还没在「大纲转章节」里解析过章节，会先按大纲正文解析并落库，
/// 保证「大纲编辑」可以直接使用。
class OutlineEditChapterListPage extends StatefulWidget {
  final OutlineRecord outline;

  /// 选择器模式（「小说灵感 → 导入大纲」用）：点击卡片直接勾选 / 取消，
  /// 底部「确定」返回所选事件，不进入编辑页、不显示「小说设定」。
  final bool pickerMode;

  const OutlineEditChapterListPage({
    super.key,
    required this.outline,
    this.pickerMode = false,
  });

  @override
  State<OutlineEditChapterListPage> createState() =>
      OutlineEditChapterListPageState();
}

/// State 类公开：多选底部操作栏只在勾选后出现，而勾选要经过卡片点击、
/// 卡片又要先读库——测试环境没有 sqflite，读库必失败，卡片压根渲染不出来。
/// 因此这里公开两个测试钩子（`debugSetSelectedForTest` / `debugSelectedForTest`），
/// 让 `test/outline_edit_multi_select_test.dart` 能直接摆出卡片与勾选状态。
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

  /// 是否处于多选模式（有勾选时才显示复选框与底部多选栏）
  bool get _selecting => _selected.isNotEmpty;

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
      await reconcileOutlineChapters(outlineId: id, content: record.content);
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
  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_chapters.map((c) => c.id).whereType<int>());
    });
  }

  /// 取消多选：清空已勾选的事件。
  ///
  /// 进入编辑页是「编辑所选（N）」，这个方法是**唯一的清空出口**：底部计数旁的
  /// 「取消选择」，以及返回键 / 返回手势都走它。
  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() => _selected.clear());
  }

  /// 测试钩子：直接摆出章节列表与勾选状态（见类注释）。生产代码不调用。
  ///
  /// 顺带清掉读库错误：测试环境没有 sqflite，进页时 `_load` 必失败，
  /// 不把 `_error` 清掉的话卡片永远渲染不出来，长按 / 复选框行为就没法验。
  @visibleForTesting
  void debugSetSelectedForTest(Set<int> ids, {List<OutlineChapter>? chapters}) {
    setState(() {
      if (chapters != null) _chapters = chapters;
      _error = null;
      _loading = false;
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

  /// 返回键 / 返回手势：多选时先取消多选，第二次才真正退出页面。
  /// （勾选是页面内的临时状态，返回键顺手把它清掉，免得退出去再进来还留着）
  void _onBackPressed() {
    if (!widget.pickerMode && _selecting) {
      _clearSelection();
      return;
    }
    Navigator.of(context).pop();
  }

  /// 选择器模式：确认把当前勾选的事件带回上一页。
  void _confirmPick() {
    if (_selected.isEmpty) return;
    final majorNumbers = majorEventNumbers(_chapters);
    final minorNumbers = minorEventNumbers(_chapters);
    final picked =
        <({OutlineChapter chapter, int? majorNumber, int? minorNumber})>[];
    for (var i = 0; i < _chapters.length; i++) {
      final ch = _chapters[i];
      if (ch.id != null && _selected.contains(ch.id)) {
        picked.add((
          chapter: ch,
          majorNumber: majorNumbers[i],
          minorNumber: minorNumbers[i],
        ));
      }
    }
    Navigator.of(context).pop(picked);
  }

  /// 打开「小说设定」编辑弹层并落库：书名 / 类型 / 主题 / 主角简介 / 世界观。
  ///
  /// 书名改动会同步替换大纲正文前几行里的 `书名：《…》` 行，避免列表标题
  /// 与正文里写着的书名对不上。
  Future<void> _openSettings() async {
    final id = widget.outline.id;
    if (id == null) return;
    final draft = await showOutlineSettingsEditSheet(
      context,
      initial: OutlineSettingsDraft(
        title: _outline.title,
        genre: _outline.genre,
        theme: _outline.theme,
        protagonist: _outline.protagonist,
        worldview: _outline.worldview,
      ),
    );
    if (draft == null || !mounted) return;

    final nextTitle = draft.title.trim();
    var nextContent = _outline.content;
    if (nextTitle.isNotEmpty && nextTitle != _outline.title.trim()) {
      nextContent = _replaceBookTitleLine(nextContent, nextTitle);
    }
    try {
      await OutlineRecordDbHelper().update(id, <String, dynamic>{
        'title': nextTitle.isEmpty ? _outline.title : nextTitle,
        'genre': draft.genre,
        'theme': draft.theme,
        'protagonist': draft.protagonist,
        'worldview': draft.worldview,
        if (nextContent != _outline.content) 'content': nextContent,
      });
    } catch (e, st) {
      debugPrint('[outline_edit_chapters] 保存小说设定失败 outline=$id：$e\n$st');
      if (mounted) _showMessage('保存失败：$e', error: true);
      return;
    }
    if (!mounted) return;
    await _load(showLoading: false);
    if (!mounted) return;
    _showMessage('小说设定已保存');
  }

  /// 把正文前几行里的 `书名：《…》` 行换成新书名（保留行首缩进与写法）。
  /// 没有书名行时原样返回（只有 record.title 变，正文不受影响）。
  String _replaceBookTitleLine(String content, String title) {
    final lines = content.split('\n');
    final limit = lines.length < 5 ? lines.length : 5;
    final pattern = RegExp(r'^(\s*)书名\s*[:：].*$');
    for (var i = 0; i < limit; i++) {
      final match = pattern.firstMatch(lines[i]);
      if (match == null) continue;
      lines[i] = '${match.group(1)}书名：《$title》';
      return lines.join('\n');
    }
    return content;
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final p = _palette(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12.5)),
        backgroundColor: error ? p.danger : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  AppPalette _palette(BuildContext context) =>
      widget.pickerMode ? monochromePalette(context.palette) : context.palette;

  @override
  Widget build(BuildContext context) {
    final monoPalette = widget.pickerMode
        ? monochromePalette(context.palette)
        : null;
    final p = monoPalette ?? context.palette;
    final outline = _outline;
    // 大 / 小事件序号：与大纲正文里的「大事件N」/「○ 小事件N」同一套编号
    // （大事件只数大事件；小事件在每个大事件内部从 1 重新开始），
    // 显示在卡片的类型标签上（大事件57 / 小事件2），方便对上正文与生成记录
    final majorNumbers = majorEventNumbers(_chapters);
    final minorNumbers = minorEventNumbers(_chapters);
    final content = PopScope(
      // 系统返回手势与顶栏返回键保持同一套行为：多选时先取消多选，再退出页面。
      canPop: widget.pickerMode || !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _clearSelection();
      },
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          title: Text(
            widget.pickerMode
                ? '选择注入事件'
                : (outline.title.isNotEmpty ? outline.title : '选择事件'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: p.surface,
          elevation: 0.5,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: p.textPrimary),
            onPressed: _onBackPressed,
          ),
          actions: widget.pickerMode
              ? null
              : [
                  IconButton(
                    icon: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: p.textPrimary,
                    ),
                    tooltip: '小说设定',
                    onPressed: _loading ? null : _openSettings,
                  ),
                ],
        ),
        // 多选栏只在实际勾选了事件时出现；平时列表更干净
        bottomNavigationBar: _loading || !_selecting
            ? null
            : (widget.pickerMode ? _buildPickerBottomBar() : _buildBottomBar()),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? OutlineLoadErrorView(error: _error!, onRetry: _load)
            : _chapters.isEmpty
            ? Center(
                child: Text(
                  '该小说没有可编辑的事件',
                  style: TextStyle(fontSize: 13, color: p.textTertiary),
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
                    color: p.accentSoft,
                    child: Text(
                      widget.pickerMode
                          ? '共 ${_chapters.length} 个事件 · 点击选择要注入的事件（可多选）'
                          : '共 ${_chapters.length} 个事件 · 已完成 $_completedCount'
                                ' · 点击编辑 / 长按多选',
                      style: TextStyle(fontSize: 12, color: p.textSecondary),
                    ),
                  ),
                  Expanded(
                    // 常显 + 可拖动的滚动条：事件多时按住拇指上下拖，快速到达目标位置。
                    // 贴屏幕右边缘显示（crossAxisMargin 0），视觉上就是系统滚动条的位置；
                    // 拖动热区是拇指中心 48px 的圆，按住时落点稍微往内一点再拖，
                    // 避免从最边缘起手被系统的返回手势抢走。
                    child: RawScrollbar(
                      controller: _scrollCtrl,
                      thumbVisibility: true,
                      interactive: true,
                      thickness: 5,
                      radius: const Radius.circular(2.5),
                      minThumbLength: 44,
                      thumbColor: p.textTertiary.withValues(alpha: 0.5),
                      child: ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(10),
                        itemCount: _chapters.length,
                        itemBuilder: (context, index) {
                          final ch = _chapters[index];
                          final selected =
                              ch.id != null && _selected.contains(ch.id);
                          return _ChapterSelectTile(
                            chapter: ch,
                            selected: selected,
                            selecting: _selecting,
                            majorNumber: majorNumbers[index],
                            minorNumber: minorNumbers[index],
                            // 选择器模式：点卡片直接切换勾选；平时点卡片进入编辑
                            onTap: () => widget.pickerMode
                                ? _toggleSelect(ch)
                                : (_selecting
                                      ? _toggleSelect(ch)
                                      : _openEdit([ch])),
                            // 长按进入多选（第一个被长按的事件直接选中）
                            onLongPress: () => _toggleSelect(ch),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    if (monoPalette == null) return content;
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: <ThemeExtension<dynamic>>[monoPalette],
        scaffoldBackgroundColor: monoPalette.background,
      ),
      child: content,
    );
  }

  /// 选择器模式的底部栏：已选数量 + 取消选择 + 全选 + 确定。
  Widget _buildPickerBottomBar() {
    final p = _palette(context);
    final count = _selected.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                '已选 $count 个事件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
            ),
            TextButton(
              onPressed: _clearSelection,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                '取消选择',
                style: TextStyle(fontSize: 12, color: p.textTertiary),
              ),
            ),
            TextButton(
              onPressed: (_chapters.isEmpty || _allSelected)
                  ? null
                  : _selectAll,
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
                onPressed: count == 0 ? null : _confirmPick,
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: p.onAccent,
                  disabledBackgroundColor: p.surfaceMuted,
                  disabledForegroundColor: p.textTertiary,
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
                  '确定选择（$count）',
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

  /// 底部多选操作栏：已选数量 + 取消选择 + 全选 + 编辑所选。
  ///
  /// 尺寸刻意压小：这一行在 360dp 宽的手机上本来只剩 336dp（减去左右各 12
  /// 的内边距），而「已选 N 个事件 + 取消选择 + 全选 + 大按钮」按原尺寸
  /// 实测会溢出 17px。现在：字号 12、主按钮去掉图标（标签本身已经说清是编辑）、
  /// 内边距 16 → 12。另外给两处文字都加了省略兜底。
  Widget _buildBottomBar() {
    final p = context.palette;
    final count = _selected.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Flexible(
              child: Text(
                '已选 $count 个事件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
            ),
            // 取消多选：清空勾选，退出多选模式
            TextButton(
              onPressed: _clearSelection,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                '取消选择',
                style: TextStyle(fontSize: 12, color: p.textTertiary),
              ),
            ),
            // 全选：只做全选。清空勾选交给「取消选择」
            TextButton(
              onPressed: (_chapters.isEmpty || _allSelected)
                  ? null
                  : _selectAll,
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
                  backgroundColor: p.accent,
                  foregroundColor: p.onAccent,
                  disabledBackgroundColor: p.surfaceMuted,
                  disabledForegroundColor: p.textTertiary,
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

/// 单个事件选择卡片：**平时不显示复选框**（长按才进入多选），多选模式下
/// 左侧出现复选框，点卡片切换勾选。类型标签上带序号（大事件57 / 小事件2），
/// 与大纲正文的写法一致。
class _ChapterSelectTile extends StatelessWidget {
  final OutlineChapter chapter;
  final bool selected;

  /// 是否处于多选模式（决定是否显示左侧复选框）
  final bool selecting;

  /// 大事件序号（全篇只数大事件，从 1 连续）；非大事件为 null
  final int? majorNumber;

  /// 小事件序号（在所属大事件内部从 1 重新计数）；非小事件为 null
  final int? minorNumber;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChapterSelectTile({
    required this.chapter,
    required this.selected,
    required this.selecting,
    this.majorNumber,
    this.minorNumber,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isMajor = chapter.isMajor;
    final isCompleted = chapter.status == 'completed';
    final words = chapter.content.characters.length;
    final statusText = chapter.status == 'generating'
        ? '生成中'
        : (isCompleted ? '已生成' : '待生成');
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(6, 8, 10, 8),
        decoration: BoxDecoration(
          color: isMajor ? p.accentSoft : p.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? p.accent
                : (isCompleted ? p.successSoft : p.border),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 复选框只在多选模式出现：平时隐藏，长按进入多选后才有
            if (selecting) ...[
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  activeColor: p.accent,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 2),
            ] else
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
                        color: isMajor ? p.accent : p.textTertiary,
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
                            color: p.textPrimary,
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
                        background: isMajor ? p.borderStrong : p.surfaceMuted,
                        foreground: p.textSecondary,
                        // 序号用主色加粗：长列表里一眼能扫到第几个大事件 / 小事件
                        numberColor: p.accent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    chapter.eventSummary.trim().isEmpty
                        ? '暂无概要'
                        : chapter.eventSummary.trim(),
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.35,
                      color: p.textTertiary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isMajor ? statusText : '$statusText · $words 字',
                    style: TextStyle(
                      fontSize: 9,
                      color: isCompleted ? p.success : p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
