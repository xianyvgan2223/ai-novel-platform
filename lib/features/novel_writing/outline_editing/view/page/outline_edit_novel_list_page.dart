import 'package:flutter/material.dart';
import '../../../../../core/widgets/settings_kit.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/list_scroll_offset.dart';
import '../../../shared/outline_load_error_view.dart';
import 'outline_edit_chapter_list_page.dart';

/// 通用的「选择大纲」入口页：用小卡片网格列出「一键生成大纲」历史大纲里的
/// 每本小说。
///
/// 数据源与「历史大纲」页一致（outline_records 表）；卡片上带章节进度
/// （章节总数 / 已完成数，来自 outline_chapters 分组统计）。
/// 「大纲编辑」「大纲转章节」「一键生成大纲」历史入口共用此页，只有点开
/// 卡片后的去向不同（见 [onOpenNovel]）。
class OutlineEditNovelListPage extends StatefulWidget {
  /// 页面标题（三个入口只在这里区分）
  final String title;

  /// 列表顶部统计条上的提示语
  final String hint;

  /// 空列表时的标题与说明
  final String emptyTitle;
  final String emptyHint;

  /// 点卡片后的去向；为 null 时进入「大纲编辑」的章节选择页。
  /// 回调返回后列表会自动刷新，章节标题 / 进度改动能同步到卡片。
  final Future<void> Function(BuildContext context, OutlineRecord outline)?
  onOpenNovel;

  /// 是否允许长按卡片删除这条大纲（带确认弹窗）。
  /// 只有「一键生成大纲」的历史入口开启，保持旧「历史大纲」列表页的删除能力。
  final bool allowDelete;

  /// 中性配色：只给「一键生成大纲」的历史入口用。
  /// 其余入口（大纲编辑 / 大纲转章节）保持原来的主色蓝。
  final bool mutedAccent;

  const OutlineEditNovelListPage({
    super.key,
    this.title = '大纲编辑',
    this.hint = '点卡片选择章节编辑',
    this.emptyTitle = '还没有可编辑的小说',
    this.emptyHint = '请先在「一键生成大纲」中创建',
    this.onOpenNovel,
    this.allowDelete = false,
    this.mutedAccent = false,
  });

  @override
  State<OutlineEditNovelListPage> createState() =>
      _OutlineEditNovelListPageState();
}

class _OutlineEditNovelListPageState extends State<OutlineEditNovelListPage> {
  List<OutlineRecord> _records = [];
  Map<int, ({int total, int completed})> _stats = {};

  /// 卡片网格的滚动控制器：进入「选择章节」页前记下位置，返回时停回同一区域
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

  /// 读取大纲列表。
  ///
  /// [showLoading] 为 false 时保留当前网格、不切成整页 loading：从下级页面
  /// 返回后的刷新与下拉刷新都走这条路径——整页 loading 会把 GridView 从树上
  /// 拆掉，滚动位置随之丢失，返回时卡片列表就跳回顶部了。
  Future<void> _load({bool showLoading = true}) async {
    if (mounted) {
      setState(() {
        if (showLoading) _loading = true;
        _error = null;
      });
    }
    try {
      // 列表只取小字段：带 content / skeleton 的 SELECT * 遇到超大行会抛
      // "Row too big to fit into CursorWindow"（Android CursorWindow 仅 2 MB）。
      final rows = await OutlineRecordDbHelper().getAllSummaries();
      _records = rows.map((m) => OutlineRecord.fromMap(m)).toList();
      try {
        // 章节进度：一次分组查询取全部大纲的统计，避免逐本查库。
        // 它失败只影响进度显示，不该把整个列表判成空。
        _stats = await OutlineChapterDbHelper().getStatsByOutline();
      } catch (e, st) {
        debugPrint('[outline_edit_list] 加载章节进度失败：$e\n$st');
        _stats = {};
      }
    } catch (e, st) {
      debugPrint('[outline_edit_list] 加载大纲列表失败：$e\n$st');
      _records = [];
      _stats = {};
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 卡片上只有摘要（不含正文 / 骨架），点开时按 id 取完整记录。
  ///
  /// 返回后静默刷新（章节标题 / 进度可能已变），并把网格定位回点开卡片时
  /// 所显示的区域，而不是跳回顶部。
  Future<void> _openNovel(OutlineRecord summary) async {
    final id = summary.id;
    if (id == null) return;
    final offset = captureScrollOffset(_scrollCtrl);
    final OutlineRecord record;
    try {
      final row = await OutlineRecordDbHelper().getById(id);
      if (row == null) {
        _showMessage('这部小说已不存在，可能已被删除');
        await _load(showLoading: false);
        if (mounted) restoreScrollOffset(_scrollCtrl, offset);
        return;
      }
      record = OutlineRecord.fromMap(row);
    } catch (e, st) {
      debugPrint('[outline_edit_list] 读取大纲 id=$id 失败：$e\n$st');
      _showMessage('读取大纲失败：$e');
      return;
    }
    if (!mounted) return;
    final open = widget.onOpenNovel;
    if (open != null) {
      await open(context, record);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OutlineEditChapterListPage(outline: record),
        ),
      );
    }
    if (!mounted) return;
    // 返回后刷新：章节标题/概要或进度有改动时卡片信息同步（保留滚动位置）
    await _load(showLoading: false);
    if (!mounted) return;
    restoreScrollOffset(_scrollCtrl, offset);
  }

  /// 长按卡片删除这条大纲记录（删除后无法恢复，仅历史入口开启）
  Future<void> _confirmDelete(OutlineRecord summary) async {
    final id = summary.id;
    if (id == null) return;
    final title = summary.title.isNotEmpty ? summary.title : '未命名大纲';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「$title」吗？删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: false),
            child: const Text('取消'),
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
    // 删掉一张卡片后列表不该跳回顶部：记下当前位置，刷新完再定位回去
    final offset = captureScrollOffset(_scrollCtrl);
    try {
      await OutlineRecordDbHelper().delete(id);
      _showMessage('已删除「$title」');
    } catch (e, st) {
      debugPrint('[outline_edit_list] 删除大纲 id=$id 失败：$e\n$st');
      _showMessage('删除失败：$e');
    }
    await _load(showLoading: false);
    if (!mounted) return;
    restoreScrollOffset(_scrollCtrl, offset);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: widget.mutedAccent ? kSettingsLabel : const Color(0xFF333333),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? OutlineLoadErrorView(error: _error!, onRetry: _load)
          : _records.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_stories,
                    size: 64,
                    color: Color(0xFFCCCCCC),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.emptyTitle,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF999999),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.emptyHint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFBBBBBB),
                    ),
                  ),
                ],
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
                  color: widget.mutedAccent
                      ? kSettingsChipBg
                      : const Color(0xFFF8F9FF),
                  child: Text(
                    '共 ${_records.length} 部小说 · ${widget.hint}'
                    '${widget.allowDelete ? ' · 长按卡片删除' : ''}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF666666),
                    ),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    // 下拉刷新同样保留网格：切成整页 loading 会把
                    // RefreshIndicator 一起拆掉，刷新动画与滚动位置都会丢
                    onRefresh: () => _load(showLoading: false),
                    child: GridView.builder(
                      controller: _scrollCtrl,
                      // 内容不足一屏时也能下拉刷新
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 200,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.85,
                          ),
                      itemCount: _records.length,
                      itemBuilder: (context, index) {
                        final r = _records[index];
                        return _OutlineCard(
                          record: r,
                          stat: r.id == null ? null : _stats[r.id!],
                          mutedAccent: widget.mutedAccent,
                          onTap: () => _openNovel(r),
                          onLongPress: widget.allowDelete
                              ? () => _confirmDelete(r)
                              : null,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 单部小说的小卡片：封面首字 + 书名 + 类型 + 主角简介 + 生成时间 + 章节进度
class _OutlineCard extends StatelessWidget {
  final OutlineRecord record;
  final ({int total, int completed})? stat;

  /// 中性配色（仅「一键生成大纲」历史入口）
  final bool mutedAccent;
  final VoidCallback onTap;

  /// 长按回调（为 null 时不响应长按）
  final VoidCallback? onLongPress;

  const _OutlineCard({
    required this.record,
    required this.stat,
    required this.onTap,
    this.mutedAccent = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final title = record.title.isNotEmpty ? record.title : '未命名大纲';
    final genre = record.genre.trim();
    final protagonist = record.protagonist.trim().replaceAll('\n', ' ');
    final total = stat?.total ?? 0;
    final completed = stat?.completed ?? 0;
    final firstChar = title.characters.isEmpty ? '书' : title.characters.first;
    // 默认保持原来的主色蓝；历史入口传 mutedAccent 时换成中性灰阶
    final accent = mutedAccent ? kSettingsTitle : const Color(0xFF4D6BFE);
    final avatarColors = mutedAccent
        ? const [Color(0xFF2B303A), Color(0xFF6B7385)]
        : const [Color(0xFF4D6BFE), Color(0xFF8AA2FF)];
    final tagBg = mutedAccent ? kSettingsChipBg : const Color(0xFFEFF3FF);
    final tagFg = mutedAccent ? kSettingsValue : const Color(0xFF4D6BFE);
    final statIconColor = mutedAccent
        ? kSettingsSubtitle
        : const Color(0xFF4D6BFE);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE8ECF4)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: avatarColors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      firstChar,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (genre.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: tagBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    genre,
                    style: TextStyle(fontSize: 10, color: tagFg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (protagonist.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  protagonist,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: Color(0xFF999999),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const Spacer(),
              Text(
                record.formattedDate,
                style: const TextStyle(fontSize: 10, color: Color(0xFFBBBBBB)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              if (total > 0) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: completed / total,
                    minHeight: 3,
                    backgroundColor: const Color(0xFFF0F2F6),
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 $total 章 · 已完成 $completed',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF999999),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.edit_note, size: 14, color: statIconColor),
                  ],
                ),
              ] else
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        '未解析章节',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFBBBBBB),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: Color(0xFFCCCCCC),
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
