import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../model/entity/copy_entity.dart';
import '../../model/entity/copy_record_entity.dart';
import '../../model/repo/copy_repository.dart';
import 'copy_detail_page.dart';

class CopyHistoryPage extends StatefulWidget {
  final List<CopyEntity> copies;

  const CopyHistoryPage({super.key, required this.copies});

  @override
  State<CopyHistoryPage> createState() => _CopyHistoryPageState();
}

class _CopyHistoryPageState extends State<CopyHistoryPage> {
  final _repo = CopyRepository();
  List<CopyRecordEntity> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    try {
      final allRecords = await _repo.getAllRecords();
      setState(() {
        _records = allRecords;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _copyName(int copyId) {
    final copy = widget.copies.where((c) => c.id == copyId);
    return copy.isNotEmpty ? copy.first.copyName : '未知副本';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('副本经历', style: TextStyle(fontSize: 15)),
        backgroundColor: p.surface,
        elevation: p.isDark ? 0 : 0.5,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _records.isEmpty
          ? Center(
              child: Text(
                '暂无副本经历',
                style: TextStyle(fontSize: 13, color: p.textTertiary),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadRecords,
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: _records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final record = _records[index];
                  return _RecordCard(
                    copyName: _copyName(record.copyId),
                    time: _formatTime(record.createTime),
                    hasStory:
                        record.totalStory != null &&
                        record.totalStory!.isNotEmpty,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CopyDetailPage(copyId: record.copyId),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  final String copyName;
  final String time;
  final bool hasStory;
  final VoidCallback onTap;

  const _RecordCard({
    required this.copyName,
    required this.time,
    required this.hasStory,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(8),
          border: p.isDark ? Border.all(color: p.border) : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    copyName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 11,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (hasStory)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '查看',
                  style: TextStyle(fontSize: 11, color: p.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
