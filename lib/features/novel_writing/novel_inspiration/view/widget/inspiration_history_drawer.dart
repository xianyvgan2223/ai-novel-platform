// 小说灵感 — 左侧历史对话抽屉
//
// 视觉与聊天页面的历史抽屉同构：顶部标题 + 新建 + 会话列表；
// 配色使用本功能的暖金色，不跟随聊天页。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import 'inspiration_theme.dart';

class InspirationHistoryDrawer extends StatelessWidget {
  const InspirationHistoryDrawer({super.key, required this.controller});

  final InspirationController controller;

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final width = MediaQuery.sizeOf(context).width * 0.85;
    return Drawer(
      width: width,
      backgroundColor: p.background,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 20, color: p.accent),
                  const SizedBox(width: 8),
                  Text(
                    '灵感记录',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: p.textTertiary,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.onAccent,
                    minimumSize: const Size.fromHeight(40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await controller.newSession();
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建灵感', style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
            Divider(height: 1, color: p.border),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  if (controller.sessions.isEmpty) {
                    return Center(
                      child: Text(
                        '暂无记录',
                        style: TextStyle(fontSize: 12, color: p.textTertiary),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: controller.sessions.length,
                    itemBuilder: (context, index) {
                      final s = controller.sessions[index];
                      return _SessionTile(
                        session: s,
                        active: s.id != null && s.id == controller.session?.id,
                        onTap: () async {
                          Navigator.of(context).pop();
                          if (s.id != null) await controller.openSession(s.id!);
                        },
                        onDelete: () => _confirmDelete(context, s),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    InspirationSession session,
  ) async {
    final p = inspirationPalette(context.palette);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          '删除这条灵感记录？',
          style: TextStyle(fontSize: 15, color: p.textPrimary),
        ),
        content: Text(
          '「${session.title.isEmpty ? '未命名' : session.title}」的全部对话与推演都会删除，无法恢复。',
          style: TextStyle(fontSize: 13, height: 1.6, color: p.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: p.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: p.danger)),
          ),
        ],
      ),
    );
    if (ok == true && session.id != null) {
      await controller.deleteSession(session.id!);
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.active,
    required this.onTap,
    required this.onDelete,
  });

  final InspirationSession session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final title = session.title.trim().isEmpty ? '未命名灵感' : session.title;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: active ? p.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onDelete,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 15,
                  color: active ? p.accent : p.textTertiary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: active ? p.accent : p.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_formatTime(session.updatedAt)} · ${session.hasOutline ? '已导入大纲' : '未导入大纲'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: p.textTertiary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: p.textTertiary,
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final hm =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    if (d == today) return hm;
    if (today.difference(d).inDays == 1) return '昨天 $hm';
    return '${date.month}/${date.day}';
  }
}
