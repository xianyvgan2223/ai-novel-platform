import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../controller/battle_controller.dart';
import '../../model/battle_model.dart';
import 'battle_edit_page.dart';

/// 战斗场景历史页面 — 查看所有已生成记录，点击进入编辑
class BattleHistoryPage extends StatefulWidget {
  final BattleController controller;

  const BattleHistoryPage({super.key, required this.controller});

  @override
  State<BattleHistoryPage> createState() => _BattleHistoryPageState();
}

class _BattleHistoryPageState extends State<BattleHistoryPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    widget.controller.loadHistory();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _openEdit(BattleScene scene) async {
    if (scene.id == null) return;
    final modified = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BattleEditPage(
          sceneId: scene.id!,
          controller: widget.controller,
        ),
      ),
    );
    if (modified == true) {
      widget.controller.loadHistory();
    }
  }

  Future<void> _confirmDelete(BattleScene scene) async {
    if (scene.id == null) return;
    final p = context.palette;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('删除后不可恢复，确定要删除这条记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: p.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true && scene.id != null) {
      await widget.controller.deleteScene(scene.id!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final history = widget.controller.history;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text(
          '历史记录',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: p.surface,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 48, color: p.textTertiary),
                  const SizedBox(height: 12),
                  Text(
                    '暂无历史记录',
                    style: TextStyle(fontSize: 14, color: p.textTertiary),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: history.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final scene = history[index];
                return _buildCard(scene);
              },
            ),
    );
  }

  Widget _buildCard(BattleScene scene) {
    final p = context.palette;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: p.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openEdit(scene),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：时间 + 删除
              Row(
                children: [
                  Icon(Icons.access_time,
                      size: 12, color: p.textTertiary),
                  const SizedBox(width: 4),
                  Text(
                    _formatTime(scene.createdAt),
                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => _confirmDelete(scene),
                    child: Icon(Icons.delete_outline,
                        size: 16, color: p.textTertiary),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.edit_outlined,
                      size: 14, color: p.textTertiary),
                ],
              ),
              const SizedBox(height: 8),
              // 战斗要素摘要
              Text(
                scene.userInput,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: p.textSecondary),
              ),
              if (scene.aiResult.isNotEmpty) ...[
                const SizedBox(height: 8),
                Divider(height: 1, color: p.border),
                const SizedBox(height: 8),
                Text(
                  scene.aiResult,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: p.textPrimary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
