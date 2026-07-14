/// lib/views/history_page.dart
/// 历史会话列表页面 — 展示、新建、删除会话

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/history_controller.dart';
import '../models/chat_session.dart';
import 'chat_page.dart'; // chatProvider
import 'novel_shelf_page.dart';

/// HistoryController Riverpod Provider
final historyProvider = ChangeNotifierProvider<HistoryController>(
  (ref) => HistoryController(),
);

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(historyProvider).loadSessions());
  }

  Future<void> _onNewSession() async {
    // 直接新建内存会话并切换到主页面，等发消息时才入库
    ref.read(chatProvider).newSession();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _onTapSession(ChatSession session) async {
    await ref.read(chatProvider).loadSession(session);
    if (mounted) {
      Navigator.of(context).pop(session);
    }
  }

  Future<void> _onDeleteSession(int id) async {
    await ref.read(historyProvider).deleteSession(id);
  }

  @override
  Widget build(BuildContext context) {
    final historyCtrl = ref.watch(historyProvider);

    if (!historyCtrl.isLoaded) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: _buildAppBar(context),
        body: const Center(
          child: CircularProgressIndicator(color: Color(0xFF4D6BFE)),
        ),
      );
    }

    final sessions = historyCtrl.sessions;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(context),
      body: sessions.isEmpty
          ? const Center(
              child: Text(
                '暂无历史会话',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: sessions.length + 1, // +1 新建按钮
              separatorBuilder: (_, _) => const Divider(
                height: 1,
                indent: 16,
                color: Color(0xFFEEEEEE),
              ),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _NewSessionButton(onTap: _onNewSession);
                }
                final session = sessions[index - 1];
                return _SessionTile(
                  session: session,
                  onTap: () => _onTapSession(session),
                  onDelete: () => _showDeleteConfirm(session),
                );
              },
            ),
    );
  }

  AppBar _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text(
        '历史会话',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Color(0xFF333333),
        ),
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.auto_stories, color: Color(0xFF333333)),
          tooltip: '游戏',
          onPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const NovelShelfPage()));
          },
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
      ),
    );
  }

  void _showDeleteConfirm(ChatSession session) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          '删除对话',
          style: TextStyle(fontSize: 16, color: Color(0xFF333333)),
        ),
        content: const Text(
          '确定要删除该对话记录吗？',
          style: TextStyle(fontSize: 14, color: Color(0xFF666666)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () {
              _onDeleteSession(session.id!);
              Navigator.of(ctx).pop();
            },
            child: const Text('删除', style: TextStyle(color: Color(0xFFFF4D4F))),
          ),
        ],
      ),
    );
  }
}

/// ─── 新建会话按钮 ───

class _NewSessionButton extends StatelessWidget {
  final VoidCallback onTap;
  const _NewSessionButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: const Row(
          children: [
            Icon(Icons.add_circle_outline, size: 22, color: Color(0xFF4D6BFE)),
            SizedBox(width: 12),
            Text(
              '新建对话',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF4D6BFE),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ─── 单条会话记录 ───

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onDelete,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatTime(session.createTime),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFBBBBBB),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              session.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
    );
  }

  /// ISO 时间 → 简短显示格式
  String _formatTime(String isoTime) {
    try {
      final dt = DateTime.parse(isoTime);
      return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoTime;
    }
  }
}
