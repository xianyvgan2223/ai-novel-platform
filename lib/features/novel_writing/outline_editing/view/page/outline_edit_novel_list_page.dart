import 'package:flutter/material.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import 'outline_edit_chapter_list_page.dart';

/// 「大纲编辑」入口页：列出「一键生成大纲」历史大纲里的每本小说。
///
/// 数据源与「历史大纲」页一致（outline_records 表），点击小说进入章节选择。
class OutlineEditNovelListPage extends StatefulWidget {
  const OutlineEditNovelListPage({super.key});

  @override
  State<OutlineEditNovelListPage> createState() =>
      _OutlineEditNovelListPageState();
}

class _OutlineEditNovelListPageState extends State<OutlineEditNovelListPage> {
  List<OutlineRecord> _records = [];
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
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
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
                  child: const Text(
                    '选择一部小说，再选择要编辑的章节',
                    style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _records.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final r = _records[index];
                      return _NovelTile(
                        record: r,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  OutlineEditChapterListPage(outline: r),
                            ),
                          );
                          // 返回后刷新（章节标题/概要有改动时列表信息同步）
                          if (mounted) _load();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _NovelTile extends StatelessWidget {
  final OutlineRecord record;
  final VoidCallback onTap;

  const _NovelTile({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title.isNotEmpty ? record.title : '未命名大纲',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${record.genre} · ${record.protagonist}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.formattedDate,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFBBBBBB),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
          ],
        ),
      ),
    );
  }
}
