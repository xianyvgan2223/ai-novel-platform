import 'package:flutter/material.dart';
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('副本经历', style: TextStyle(fontSize: 15)),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _records.isEmpty
          ? const Center(
              child: Text(
                '暂无副本经历',
                style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    copyName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
            if (hasStory)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A90D9).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '查看',
                  style: TextStyle(fontSize: 11, color: Color(0xFF4A90D9)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
