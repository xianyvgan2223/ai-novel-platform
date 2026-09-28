import 'package:flutter/material.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/outline_load_error_view.dart';
import 'chapter_write_page.dart';

/// 选择大纲 → 进入章节写作页面
class ChapterListPage extends StatefulWidget {
  const ChapterListPage({super.key});

  @override
  State<ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<ChapterListPage> {
  List<OutlineRecord> _records = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // 列表只取小字段：带 content / skeleton 的 SELECT * 遇到超大行会抛
      // "Row too big to fit into CursorWindow"（Android CursorWindow 仅 2 MB）。
      final rows = await OutlineRecordDbHelper().getAllSummaries();
      _records = rows.map((m) => OutlineRecord.fromMap(m)).toList();
    } catch (e, st) {
      debugPrint('[chapter_list] 加载大纲列表失败：$e\n$st');
      _records = [];
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 列表里只有摘要（不含正文 / 骨架），点开时按 id 取完整记录再进页面。
  Future<void> _openOutline(OutlineRecord summary) async {
    final id = summary.id;
    if (id == null) return;
    try {
      final row = await OutlineRecordDbHelper().getById(id);
      if (row == null) {
        _showMessage('这条大纲已不存在，可能已被删除');
        await _load();
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChapterWritePage(outline: OutlineRecord.fromMap(row)),
        ),
      );
    } catch (e, st) {
      debugPrint('[chapter_list] 读取大纲 id=$id 失败：$e\n$st');
      _showMessage('读取大纲失败：$e');
    }
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
        title: const Text('大纲转章节',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
          : _error != null
          ? OutlineLoadErrorView(error: _error!, onRetry: _load)
          : _records.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_stories, size: 64, color: Color(0xFFCCCCCC)),
                      SizedBox(height: 16),
                      Text('还没有大纲',
                          style: TextStyle(fontSize: 14, color: Color(0xFF999999))),
                      SizedBox(height: 8),
                      Text('请先在「一键生成大纲」中创建',
                          style: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB))),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final r = _records[index];
                    return _OutlineTile(
                      record: r,
                      onTap: () => _openOutline(r),
                    );
                  },
                ),
    );
  }
}

class _OutlineTile extends StatelessWidget {
  final OutlineRecord record;
  final VoidCallback onTap;
  const _OutlineTile({required this.record, required this.onTap});

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
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${record.genre} · ${record.protagonist}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.formattedDate,
                    style: const TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
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
