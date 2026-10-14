/// lib/views/history_page.dart
/// 历史会话抽屉 — 展示、新建、删除会话（从左侧滑出，占屏幕宽度 70%）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/history_controller.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../domain/chat_session.dart';
import '../../sync/application/sync_service.dart';
import '../../sync/data/sync_store.dart';
import '../../sync/presentation/sync_page.dart';

/// HistoryController Riverpod Provider
final historyProvider = ChangeNotifierProvider<HistoryController>(
  (ref) => HistoryController(),
);

/// 历史会话抽屉：点击聊天页左上角菜单按钮后从左侧滑出。
///
/// 选中会话 / 新建对话后自动关闭抽屉（Drawer 是 Navigator 上的一层路由，
/// 直接 pop 即可收起），并切换 chatProvider 中的当前会话。
class HistoryDrawer extends ConsumerStatefulWidget {
  const HistoryDrawer({
    super.key,
    this.sessionTitleFontSize = defaultSessionTitleFontSize,
    this.sessionPreviewFontSize = defaultSessionPreviewFontSize,
    this.sessionTimeFontSize = defaultSessionTimeFontSize,
  });

  /// 抽屉宽度占屏幕宽度的比例
  static const double widthFactor = 0.8;

  /// 会话条目标题的默认字号
  static const double defaultSessionTitleFontSize = 10;

  /// 会话条目预览行（最后一条消息）的默认字号
  static const double defaultSessionPreviewFontSize = 8;

  /// 会话条目时间戳的默认字号（略小于标题、略大于预览行）
  static const double defaultSessionTimeFontSize = 9;

  /// 会话条目标题字号；留出参数是为了截图工具能对比别的字号
  final double sessionTitleFontSize;

  /// 会话条目预览行字号，同上留出参数备用
  final double sessionPreviewFontSize;

  /// 会话条目时间戳字号，同上留出参数备用
  final double sessionTimeFontSize;

  @override
  ConsumerState<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends ConsumerState<HistoryDrawer> {
  /// 数据同步状态
  bool _syncing = false;
  String _syncStatus = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(historyProvider).loadSessions());
    _loadLastSyncTime();
  }

  Future<void> _loadLastSyncTime() async {
    try {
      final at = await SyncStore.getInt(SyncService.kLastSyncAtKey);
      if (!mounted || at <= 0) return;
      setState(() => _syncStatus = '上次同步 ${_formatSyncTime(at)}');
    } catch (_) {
      // 读不到就不显示，不影响使用
    }
  }

  String _formatSyncTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// 收起抽屉（Drawer 是 Navigator 上的路由，pop 即关闭）
  void _closeDrawer() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// 一键同步：优先用已保存的地址；没配过就自动在局域网里找电脑
  Future<void> _quickSync() async {
    if (_syncing) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _syncing = true;
      _syncStatus = '正在同步…';
    });

    try {
      final report = await SyncService.quickSync(
        deviceName: '我的手机',
        onProgress: (message, {int? current, int? total}) {
          if (!mounted) return;
          setState(() {
            _syncStatus = (current != null && total != null && total > 0)
                ? '$message  ${((current / total) * 100).round()}%'
                : message;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _syncStatus = report.finishedAt == null
            ? ''
            : '上次同步 ${_formatSyncTime(report.finishedAt!.millisecondsSinceEpoch)}';
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('同步完成：${report.summary}'),
          duration: const Duration(seconds: 4),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncStatus = '');
      messenger.showSnackBar(
        SnackBar(
          content: Text(SyncService.describeError(e)),
          duration: const Duration(seconds: 8),
          backgroundColor: const Color(0xFFFF4D4F),
          action: SnackBarAction(
            label: '同步设置',
            textColor: Colors.white,
            onPressed: _openSyncPage,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 打开同步设置页：先收起抽屉再进入，避免返回时抽屉仍展开
  void _openSyncPage() {
    final navigator = Navigator.of(context);
    _closeDrawer();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const SyncPage()),
    );
  }

  Future<void> _onNewSession() async {
    // 直接新建内存会话并切换到主页面，等发消息时才入库
    ref.read(chatProvider).newSession();
    _closeDrawer();
  }

  Future<void> _onTapSession(ChatSession session) async {
    final chat = ref.read(chatProvider);
    _closeDrawer();
    await chat.loadSession(session);
  }

  Future<void> _onDeleteSession(int id) async {
    await ref.read(historyProvider).deleteSession(id);
  }

  @override
  Widget build(BuildContext context) {
    // 占屏幕宽度 70%，超出屏幕时留出右侧间隙
    final screenWidth = MediaQuery.widthOf(context);
    final width = screenWidth * HistoryDrawer.widthFactor;

    return Drawer(
      width: width,
      backgroundColor: Colors.white,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final historyCtrl = ref.watch(historyProvider);

    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: !historyCtrl.isLoaded
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4D6BFE)),
                )
              : Column(
                  children: [
                    // 「新建对话」始终可用，没有历史会话时也能新建
                    _NewSessionButton(onTap: _onNewSession),
                    const Divider(height: 1, color: Color(0xFFEEEEEE)),
                    Expanded(child: _buildSessionList(historyCtrl.sessions)),
                  ],
                ),
        ),
        // 底部固定的数据同步入口
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        SafeArea(
          top: false,
          child: _SyncEntry(
            syncing: _syncing,
            status: _syncStatus,
            onTap: _quickSync,
          ),
        ),
      ],
    );
  }

  /// 抽屉顶部标题栏
  Widget _buildHeader() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  '历史会话',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: Color(0xFF999999),
                ),
                tooltip: '关闭',
                onPressed: _closeDrawer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionList(List<ChatSession> sessions) {
    if (sessions.isEmpty) {
      return const Center(
        child: Text(
          '暂无历史会话',
          style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const Divider(
        height: 1,
        indent: 16,
        color: Color(0xFFEEEEEE),
      ),
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _SessionTile(
          session: session,
          titleFontSize: widget.sessionTitleFontSize,
          previewFontSize: widget.sessionPreviewFontSize,
          timeFontSize: widget.sessionTimeFontSize,
          onTap: () => _onTapSession(session),
          onDelete: () => _showDeleteConfirm(session),
        );
      },
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

/// ─── 数据同步入口（放在汉堡菜单底部） ───

class _SyncEntry extends StatelessWidget {
  final bool syncing;
  final String status;
  final VoidCallback onTap;

  const _SyncEntry({
    required this.syncing,
    required this.status,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: syncing ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.cloud_sync_outlined,
                    size: 20,
                    color: Color(0xFF4D6BFE),
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '数据同步',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status.isEmpty ? '与电脑上的 Web 服务双向同步' : status,
                    style: TextStyle(
                      fontSize: 12,
                      color: status.isEmpty
                          ? const Color(0xFF999999)
                          : const Color(0xFF4D6BFE),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Color(0xFFCCCCCC)),
          ],
        ),
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

  /// 标题字号，默认取 [HistoryDrawer.defaultSessionTitleFontSize]（抽屉会传实际字号）
  final double titleFontSize;

  /// 预览行字号，默认取 [HistoryDrawer.defaultSessionPreviewFontSize]
  final double previewFontSize;

  /// 时间戳字号，默认取 [HistoryDrawer.defaultSessionTimeFontSize]
  final double timeFontSize;

  const _SessionTile({
    required this.session,
    required this.onTap,
    required this.onDelete,
    this.titleFontSize = HistoryDrawer.defaultSessionTitleFontSize,
    this.previewFontSize = HistoryDrawer.defaultSessionPreviewFontSize,
    this.timeFontSize = HistoryDrawer.defaultSessionTimeFontSize,
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
                    style: TextStyle(
                      fontSize: titleFontSize,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF333333),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatTime(session.createTime),
                  style: TextStyle(
                    fontSize: timeFontSize,
                    color: const Color(0xFFBBBBBB),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              session.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: previewFontSize,
                color: const Color(0xFF999999),
              ),
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
