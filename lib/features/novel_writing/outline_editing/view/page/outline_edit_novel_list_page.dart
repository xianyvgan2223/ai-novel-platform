import 'package:flutter/material.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/domain/outline_record.dart';
import 'outline_edit_chapter_list_page.dart';

/// 「大纲编辑」入口页：用小卡片网格列出「一键生成大纲」历史大纲里的每本小说。
///
/// 数据源与「历史大纲」页一致（outline_records 表）；卡片上带章节进度
/// （章节总数 / 已完成数，来自 outline_chapters 分组统计），点击卡片进入章节选择。
class OutlineEditNovelListPage extends StatefulWidget {
  const OutlineEditNovelListPage({super.key});

  @override
  State<OutlineEditNovelListPage> createState() =>
      _OutlineEditNovelListPageState();
}

class _OutlineEditNovelListPageState extends State<OutlineEditNovelListPage> {
  List<OutlineRecord> _records = [];
  Map<int, ({int total, int completed})> _stats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await OutlineRecordDbHelper().getAll();
      _records = rows.map((m) => OutlineRecord.fromMap(m)).toList();
      try {
        // 章节进度：一次分组查询取全部大纲的统计，避免逐本查库
        _stats = await OutlineChapterDbHelper().getStatsByOutline();
      } catch (_) {}
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openNovel(OutlineRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineEditChapterListPage(outline: record),
      ),
    );
    // 返回后刷新：章节标题/概要或进度有改动时卡片信息同步
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '大纲编辑',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_stories,
                    size: 64,
                    color: Color(0xFFCCCCCC),
                  ),
                  SizedBox(height: 16),
                  Text(
                    '还没有可编辑的小说',
                    style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '请先在「一键生成大纲」中创建',
                    style: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
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
                  color: const Color(0xFFF8F9FF),
                  child: Text(
                    '共 ${_records.length} 部小说 · 点卡片选择章节编辑',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF666666),
                    ),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: GridView.builder(
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
                          onTap: () => _openNovel(r),
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
  final VoidCallback onTap;

  const _OutlineCard({
    required this.record,
    required this.stat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = record.title.isNotEmpty ? record.title : '未命名大纲';
    final genre = record.genre.trim();
    final protagonist = record.protagonist.trim().replaceAll('\n', ' ');
    final total = stat?.total ?? 0;
    final completed = stat?.completed ?? 0;
    final firstChar = title.characters.isEmpty ? '书' : title.characters.first;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
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
                      gradient: const LinearGradient(
                        colors: [Color(0xFF4D6BFE), Color(0xFF8AA2FF)],
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
                    color: const Color(0xFFEFF3FF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    genre,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF4D6BFE),
                    ),
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
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFFBBBBBB),
                ),
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
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF4D6BFE),
                    ),
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
                    const Icon(
                      Icons.edit_note,
                      size: 14,
                      color: Color(0xFF4D6BFE),
                    ),
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
