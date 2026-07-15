import 'package:flutter/material.dart';
import '../../model/outline_record.dart';
import '../../model/db/outline_record_db_helper.dart';

/// 历史生成大纲列表页面
class OutlineHistoryPage extends StatefulWidget {
  const OutlineHistoryPage({super.key});

  @override
  State<OutlineHistoryPage> createState() => _OutlineHistoryPageState();
}

class _OutlineHistoryPageState extends State<OutlineHistoryPage> {
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

  Future<void> _delete(int id) async {
    await OutlineRecordDbHelper().delete(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '历史大纲',
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
              child: Text(
                '暂无大纲记录',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final r = _records[index];
                return _RecordTile(
                  record: r,
                  onTap: () => _showDetail(r),
                  onDelete: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认删除'),
                        content: Text('确定要删除「${r.title}」吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) _delete(r.id!);
                  },
                );
              },
            ),
    );
  }

  void _showDetail(OutlineRecord r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _OutlineEditPage(record: r, onSaved: _load),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label：',
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 大纲编辑页面（独立 StatefulWidget，正确管理控制器生命周期）
class _OutlineEditPage extends StatefulWidget {
  final OutlineRecord record;
  final VoidCallback onSaved;

  const _OutlineEditPage({required this.record, required this.onSaved});

  @override
  State<_OutlineEditPage> createState() => _OutlineEditPageState();
}

class _OutlineEditPageState extends State<_OutlineEditPage> {
  late final TextEditingController _contentCtrl;

  @override
  void initState() {
    super.initState();
    _contentCtrl = TextEditingController(text: widget.record.content);
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newContent = _contentCtrl.text;
    final r = widget.record;
    if (newContent != r.content) {
      await OutlineRecordDbHelper().update(r.id!, {
        'content': newContent,
        'title': r.title,
        'genre': r.genre,
        'theme': r.theme,
        'protagonist': r.protagonist,
        'worldview': r.worldview,
      });
      widget.onSaved();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('大纲已更新')));
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          r.title.isNotEmpty ? r.title : '大纲详情',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '📖 ${r.title}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            _infoRow('类型', r.genre),
            _infoRow('主题', r.theme),
            _infoRow('主角', r.protagonist),
            _infoRow('世界观', r.worldview),
            _infoRow('生成时间', r.formattedDate),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE8ECF4)),
              ),
              child: TextField(
                controller: _contentCtrl,
                maxLines: null,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Color(0xFF444444),
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label：',
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final OutlineRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RecordTile({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

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
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 20,
                color: Color(0xFFCCCCCC),
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
