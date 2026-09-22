/// lib/features/sync/presentation/sync_page.dart
///
/// 数据同步页：填写电脑上的服务地址 → 点一下就和手机数据双向同步。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/db/database_helper.dart';
import '../application/sync_service.dart';
import '../data/sync_store.dart';

const Color _kPrimary = Color(0xFF4D6BFE);
const Color _kInk = Color(0xFF333333);
const Color _kMuted = Color(0xFF888888);
const Color _kLine = Color(0xFFEEEEEE);

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();

  String _deviceId = '';
  int? _lastSyncAt;
  String _lastSummary = '';
  /// 设备自带 SQLite 的版本，排查兼容性问题时很有用
  String _sqliteVersion = '';

  bool _busy = false;
  String _progress = '';
  int? _progressCurrent;
  int? _progressTotal;
  SyncReport? _report;
  String? _error;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSaved());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final url = await SyncService.getBaseUrl();
    final token = await SyncService.getToken();
    final deviceId = await SyncService.ensureDeviceId();
    final at = await SyncStore.getInt(SyncService.kLastSyncAtKey);
    final summary = await SyncStore.getValue(SyncService.kLastSyncSummaryKey);

    // 顺便读一下设备自带 SQLite 的版本：老版本缺一些 SQL 语法，
    // 出兼容问题时这里是第一手线索
    var sqliteVersion = '';
    try {
      final db = await DatabaseHelper.database;
      final rows = await db.rawQuery('SELECT sqlite_version() AS v');
      sqliteVersion = (rows.first['v'] ?? '').toString();
    } catch (_) {
      // 读不到就算了
    }

    if (!mounted) return;
    setState(() {
      _urlCtrl.text = url;
      _tokenCtrl.text = token;
      _deviceId = deviceId;
      _lastSyncAt = at > 0 ? at : null;
      _lastSummary = summary ?? '';
      _sqliteVersion = sqliteVersion;
    });
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFFFF4D4F) : _kPrimary,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _testConnection() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写服务地址', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _progress = '正在测试连接…';
      _error = null;
    });
    try {
      await SyncService.setBaseUrl(url);
      await SyncService.setToken(_tokenCtrl.text);
      final info = await SyncService.testConnection(
        baseUrl: url,
        token: _tokenCtrl.text.trim(),
      );
      setState(() => _progress = '');
      _toast(info);
    } catch (e) {
      setState(() {
        _progress = '';
        _error = e.toString();
      });
      _toast('连接失败', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写服务地址（电脑上启动服务后会打印）', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _progress = '准备同步…';
    });

    try {
      await SyncService.setBaseUrl(url);
      await SyncService.setToken(_tokenCtrl.text);

      final report = await SyncService.run(
        baseUrl: url,
        token: _tokenCtrl.text.trim(),
        deviceName: '我的手机',
        onProgress: (message, {int? current, int? total}) {
          if (!mounted) return;
          setState(() {
            _progress = message;
            _progressCurrent = current;
            _progressTotal = total;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _report = report;
        _progress = '';
        _lastSyncAt = report.finishedAt?.millisecondsSinceEpoch;
        _lastSummary = report.summary;
        _error = report.hasError ? report.errors.join('\n') : null;
      });
      _toast(report.hasError ? '同步完成，但有部分问题' : '同步完成');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = '';
        // 数据库异常原文很长，用 SyncService.describeError 压成一行
        _error = SyncService.describeError(e);
      });
      _toast('同步失败', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetState() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置同步状态'),
        content: const Text(
          '只会清空「同步到哪了」的记录（设备号、游标、行版本），'
          '不会删除任何对话或作品数据。下次同步会重新比对一遍。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定重置', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SyncStore.reset();
    await _loadSaved();
    if (!mounted) return;
    setState(() {
      _report = null;
      _lastSummary = '';
      _lastSyncAt = null;
      _error = null;
    });
    _toast('已重置同步状态');
  }

  String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: _kInk),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '数据同步',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kInk),
        ),
        centerTitle: true,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kLine),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          _buildIntro(),
          const SizedBox(height: 20),
          _buildServerForm(),
          const SizedBox(height: 20),
          _buildSyncButton(),
          if (_progress.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildProgress(),
          ],
          if (_report != null) ...[
            const SizedBox(height: 16),
            _buildReport(_report!),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildError(_error!),
          ],
          const SizedBox(height: 24),
          _buildFooter(),
        ],
      ),
    );
  }

  // ─────────────────────────── 各区块 ───────────────────────────

  Widget _buildIntro() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F7FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE3E8FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.wifi_tethering, size: 17, color: _kPrimary),
              SizedBox(width: 7),
              Text(
                '使用前提',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _kPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bullet('电脑和手机连同一个 Wi-Fi，或者电脑连手机热点'),
          _bullet('电脑上启动同步服务：web/server 目录执行 npm start'),
          _bullet('把启动时打印的「手机请填」地址抄到下面'),
        ],
      ),
    );
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 6),
            child: SizedBox(
              width: 4,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _kMuted,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, height: 1.6, color: Color(0xFF555555)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('服务地址'),
        TextField(
          controller: _urlCtrl,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'http://192.168.43.5:3210',
            hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13.5),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _kLine),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _kLine),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _kPrimary),
            ),
          ),
          style: const TextStyle(fontSize: 13.5, color: _kInk),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _testConnection,
                icon: const Icon(Icons.link, size: 15),
                label: const Text('测试连接', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kPrimary,
                  side: const BorderSide(color: _kPrimary),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => setState(() => _showAdvanced = !_showAdvanced),
                icon: Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                ),
                label: const Text('高级选项', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kMuted,
                  side: const BorderSide(color: _kLine),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: 16),
          const _Label('访问令牌（服务端未开启鉴权时留空）'),
          TextField(
            controller: _tokenCtrl,
            enabled: !_busy,
            obscureText: true,
            decoration: InputDecoration(
              hintText: '与 server/.env 里的 API_TOKEN 一致',
              hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kLine),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kLine),
              ),
            ),
            style: const TextStyle(fontSize: 13.5, color: _kInk),
          ),
          const SizedBox(height: 16),
          const _Label('设备 SQLite 版本'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kLine),
            ),
            child: Text(
              _sqliteVersion.isEmpty ? '（读取中…）' : _sqliteVersion,
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF666666),
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _Label('本机设备标识'),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _deviceId));
              _toast('设备标识已复制');
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kLine),
              ),
              child: Text(
                _deviceId.isEmpty ? '（生成中…）' : _deviceId,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF666666),
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSyncButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : _sync,
        icon: _busy
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.sync, size: 18),
        label: Text(
          _busy ? '同步中…' : '立即同步',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _kPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFB9C4FF),
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildProgress() {
    final current = _progressCurrent;
    final total = _progressTotal;
    final ratio = (current != null && total != null && total > 0)
        ? (current / total).clamp(0.0, 1.0)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          minHeight: 3,
          value: ratio,
          backgroundColor: const Color(0xFFEEF1FF),
          valueColor: const AlwaysStoppedAnimation<Color>(_kPrimary),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _progress,
                style: const TextStyle(fontSize: 12.5, color: _kMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (ratio != null)
              Text(
                '${(ratio * 100).round()}%',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: _kPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildReport(SyncReport report) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FDF9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCDEFD8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.check_circle, size: 17, color: Color(0xFF10B981)),
              SizedBox(width: 7),
              Text(
                '同步完成',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF065F46),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _reportRow('拉取变更', '${report.pulled} 条'),
          _reportRow('　新增', '${report.newRows} 条'),
          _reportRow('　更新', '${report.updatedRows} 条'),
          _reportRow('　删除', '${report.deletedRows} 条'),
          _reportRow('上传本机', '${report.pushed} 条'),
          _reportRow('内容未变', '${report.unchanged} 条'),
          if (report.conflicts > 0)
            _reportRow('冲突', '${report.conflicts} 条（已保留服务端版本）'),
          _reportRow('服务端水位', 'seq = ${report.serverSeq}'),
          if (report.skippedTables > 0)
            _reportRow('跳过', '${report.skippedTables} 张本机不存在的表'),
          const SizedBox(height: 8),
          const Text(
            '提示：同步完成后返回首页重新进入，列表才会显示最新数据。',
            style: TextStyle(fontSize: 12, color: Color(0xFF059669), height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _reportRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF065F46),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFD9D9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 17, color: Color(0xFFFF4D4F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.65,
                color: Color(0xFFB91C1C),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    // 注意：首次进入时 _lastSyncAt 为 null，必须先判空再格式化
    final lastSyncAt = _lastSyncAt;
    final lastLine = lastSyncAt == null
        ? ''
        : (_lastSummary.isEmpty
            ? '上次同步：${_formatTime(lastSyncAt)}'
            : '上次同步：${_formatTime(lastSyncAt)} · $_lastSummary');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lastSyncAt != null) ...[
          Text(
            lastLine,
            style: const TextStyle(fontSize: 12, color: _kMuted, height: 1.6),
          ),
          const SizedBox(height: 12),
        ],
        TextButton(
          onPressed: _busy ? null : _resetState,
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          child: const Text(
            '重置同步状态',
            style: TextStyle(fontSize: 12.5, color: _kMuted),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '同步是双向的：服务端上被网页改过的内容会更新到手机，'
          '手机上新增的内容也会上传到服务端。API Key 等敏感字段不在同步范围内。',
          style: TextStyle(fontSize: 12, color: Color(0xFFAAAAAA), height: 1.7),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Color(0xFF555555),
        ),
      ),
    );
  }
}
