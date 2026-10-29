/// lib/features/sync/presentation/sync_page.dart
///
/// 整库同步页：找电脑（USB 隧道 / 局域网自动识别）→ 点一下双向同步整库数据。
///
/// 连接通道按可靠性自动挑：
///   USB 隧道（电脑上跑着 Java 后端，默认自动建隧道）→ 上次的地址 → 历史地址 → 热点网关 →
///   广播自报 → 扫描局域网。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../../core/db/database_helper.dart';
import '../application/sync_service.dart';
import '../data/address_resolver.dart';
import '../data/server_discovery.dart';
import '../data/sync_store.dart';

/// USB 隧道地址：adb reverse 建好后，手机上的这个地址就是电脑
const String _kUsbUrl = 'http://127.0.0.1:3210';

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

  // ── 连接通道 ──
  /// USB 隧道是否已就绪（后端已启动并自动建好隧道，且手机插着数据线）
  bool _usbReady = false;
  /// 当前通道种类
  ChannelKind? _channelKind;
  /// 正在「找电脑」
  bool _finding = false;
  String _findMessage = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadSaved());
    // 进页面就顺手探一次通道状态，用户不用点任何按钮
    unawaited(_refreshChannelStatus());
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

  /// 探一下当前通道：USB 隧道通不通、当前用的是哪种
  Future<void> _refreshChannelStatus() async {
    try {
      final status = await SyncService.channelStatus();
      if (!mounted) return;
      setState(() {
        _usbReady = status.usbReady;
        _channelKind = status.kind;
      });
    } catch (_) {
      // 探测失败不影响使用
    }
  }

  /// 「自动找电脑」：走完整的通道链（USB 隧道 → 历史 → 网关 → 广播 → 扫描）
  Future<void> _autoFind() async {
    if (_busy || _finding) return;
    setState(() {
      _finding = true;
      _findMessage = '正在找电脑…';
      _error = null;
    });
    try {
      final resolved = await SyncService.resolveAddress(
        force: true,
        onProgress: (message, {int? current, int? total}) {
          if (!mounted) return;
          setState(() => _findMessage = message);
        },
      );
      if (!mounted) return;
      if (resolved == null) {
        setState(() {
          _finding = false;
          _findMessage = '';
        });
        _toast('没找到电脑，看下面的两种连接方式', error: true);
        return;
      }
      setState(() {
        _finding = false;
        _findMessage = '';
        _urlCtrl.text = resolved.baseUrl;
        _channelKind = resolved.kind;
      });
      _toast('已找到：${resolved.kind.label} · ${resolved.baseUrl}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _finding = false;
        _findMessage = '';
        _error = SyncService.describeError(e);
      });
      _toast('查找失败', error: true);
    }
  }

  /// 一键切到 USB 隧道地址（并验证隧道是否真的通）
  Future<void> _useUsbTunnel() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = '正在检查 USB 隧道…';
      _error = null;
    });
    try {
      await SyncService.setToken(_tokenCtrl.text);
      final token = _tokenCtrl.text.trim();
      final ready = await AddressResolver.usbTunnelReady(token: token);
      if (!ready) {
        if (!mounted) return;
        setState(() {
          _progress = '';
          _usbReady = false;
        });
        _toast('USB 隧道还没通：确认电脑上后端已启动、手机插着数据线后重试', error: true);
        return;
      }
      await SyncService.useUrl(_kUsbUrl, kind: ChannelKind.usb);
      final info = await SyncService.testConnection(baseUrl: _kUsbUrl, token: token);
      if (!mounted) return;
      setState(() {
        _progress = '';
        _usbReady = true;
        _channelKind = ChannelKind.usb;
        _urlCtrl.text = _kUsbUrl;
      });
      _toast(info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = '';
        _error = SyncService.describeError(e);
      });
      _toast('USB 隧道连接失败', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final p = context.palette;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: p.onAccent)),
        backgroundColor: error ? p.danger : p.accent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _testConnection() async {
    var url = _urlCtrl.text.trim();
    setState(() {
      _busy = true;
      _progress = url.isEmpty ? '正在找电脑…' : '正在测试连接…';
      _error = null;
    });
    try {
      await SyncService.setToken(_tokenCtrl.text);
      // 地址留空时先自动找一台
      if (url.isEmpty) {
        final resolved = await SyncService.resolveAddress(
          force: true,
          onProgress: (message, {int? current, int? total}) {
            if (!mounted) return;
            setState(() => _progress = message);
          },
        );
        if (resolved == null) {
          if (!mounted) return;
          setState(() {
            _progress = '';
            _error = '没找到电脑。USB 方式：确认电脑上后端已启动（默认自动建隧道），'
                '手机地址填 $_kUsbUrl；Wi-Fi 方式：确认两边在同一网络。';
          });
          _toast('连接失败', error: true);
          return;
        }
        url = resolved.baseUrl;
      }

      final info = await SyncService.testConnection(
        baseUrl: url,
        token: _tokenCtrl.text.trim(),
      );
      await SyncService.useUrl(url);
      final status = await SyncService.channelStatus();
      if (!mounted) return;
      setState(() {
        _progress = '';
        _urlCtrl.text = SyncService.cachedUrl.isEmpty ? url : SyncService.cachedUrl;
        _usbReady = status.usbReady || SyncService.cachedKind == ChannelKind.usb;
        _channelKind = SyncService.cachedKind;
      });
      _toast(info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = '';
        _error = SyncService.describeError(e);
      });
      _toast('连接失败', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _progress = '正在找电脑…';
    });

    void onProgress(String message, {int? current, int? total}) {
      if (!mounted) return;
      setState(() {
        _progress = message;
        _progressCurrent = current;
        _progressTotal = total;
      });
    }

    try {
      await SyncService.setToken(_tokenCtrl.text);

      // 优先用输入框里的地址（用户可能手填了）；留空时走通道链自动找
      final typed = _urlCtrl.text.trim();
      final report = await SyncService.quickSync(
        preferredUrl: typed.isEmpty ? null : typed,
        deviceName: '我的手机',
        onProgress: onProgress,
      );

      if (!mounted) return;
      setState(() {
        _report = report;
        _progress = '';
        _lastSyncAt = report.finishedAt?.millisecondsSinceEpoch;
        _lastSummary = report.summary;
        _error = report.hasError ? report.errors.join('\n') : null;
        // 同步成功后把实际用上的地址回填到输入框
        final used = SyncService.cachedUrl;
        if (used.isNotEmpty) _urlCtrl.text = used;
        _channelKind = SyncService.cachedKind;
      });
      _toast(report.hasError ? '同步完成，但有部分问题' : '同步完成');
      unawaited(_refreshChannelStatus());
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
            child: Text(
              '确定重置',
              style: TextStyle(color: ctx.palette.danger),
            ),
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
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '整库同步',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          _buildIntro(),
          const SizedBox(height: 14),
          _buildChannelPanel(),
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
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cable, size: 17, color: p.accent),
              const SizedBox(width: 7),
              Text(
                '两种连接方式（推荐第一种）',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bullet('USB 数据线：电脑上启动后端即可（隧道会自动建立）；'
              '不看 Wi-Fi、不怕防火墙，地址固定填 $_kUsbUrl'),
          _bullet('Wi-Fi / 热点：手机与电脑连同一个网络，点下面的「自动找电脑」即可'),
        ],
      ),
    );
  }

  /// 连接通道面板：USB 隧道状态 + 自动找电脑 + 当前通道
  Widget _buildChannelPanel() {
    final p = context.palette;
    final kind = _channelKind;
    final currentUrl = _urlCtrl.text.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _usbReady ? p.successSoft : p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _usbReady
              ? (p.isDark ? p.border : const Color(0xFFCDEBD8))
              : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _usbReady ? Icons.usb : Icons.usb_off,
                size: 16,
                color: _usbReady ? p.success : p.textTertiary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _usbReady ? 'USB 隧道已就绪' : 'USB 隧道未连接',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _usbReady ? p.success : p.textPrimary,
                  ),
                ),
              ),
              if (kind != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '当前：${kind.label}',
                    style: TextStyle(fontSize: 11, color: p.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _usbReady
                ? '手机正通过数据线连接电脑（地址 $currentUrl）'
                : '插上数据线后，启动电脑上的后端即可（USB 隧道会自动建立）',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: p.textSecondary,
            ),
          ),
          if (_findMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: p.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _findMessage,
                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_busy || _finding) ? null : _autoFind,
                  icon: const Icon(Icons.travel_explore, size: 15),
                  label: const Text('自动找电脑', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.accent,
                    side: BorderSide(color: p.accent),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _useUsbTunnel,
                  icon: const Icon(Icons.usb, size: 15),
                  label: const Text('用 USB 连', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.success,
                    side: BorderSide(
                      color: p.isDark ? p.border : const Color(0xFFCDEBD8),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bullet(String text) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 6),
            child: SizedBox(
              width: 4,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.textTertiary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: p.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerForm() {
    final p = context.palette;
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
            hintText: '留空则自动找（USB 隧道固定为 $_kUsbUrl）',
            hintStyle: TextStyle(color: p.textTertiary, fontSize: 13.5),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: p.accent),
            ),
          ),
          style: TextStyle(fontSize: 13.5, color: p.textPrimary),
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
                  foregroundColor: p.accent,
                  side: BorderSide(color: p.accent),
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
                  foregroundColor: p.textTertiary,
                  side: BorderSide(color: p.border),
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
              hintStyle: TextStyle(color: p.textTertiary, fontSize: 13.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: p.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: p.border),
              ),
            ),
            style: TextStyle(fontSize: 13.5, color: p.textPrimary),
          ),
          const SizedBox(height: 16),
          const _Label('设备 SQLite 版本'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.border),
            ),
            child: Text(
              _sqliteVersion.isEmpty ? '（读取中…）' : _sqliteVersion,
              style: TextStyle(
                fontSize: 12.5,
                color: p.textSecondary,
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
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.border),
              ),
              child: Text(
                _deviceId.isEmpty ? '（生成中…）' : _deviceId,
                style: TextStyle(
                  fontSize: 12.5,
                  color: p.textSecondary,
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
    final p = context.palette;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : _sync,
        icon: _busy
            ? SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: p.onAccent),
              )
            : const Icon(Icons.sync, size: 18),
        label: Text(
          _busy ? '同步中…' : '整库同步',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          disabledBackgroundColor: p.accent.withValues(alpha: 0.45),
          disabledForegroundColor: p.onAccent,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildProgress() {
    final p = context.palette;
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
          backgroundColor: p.accentSoft,
          valueColor: AlwaysStoppedAnimation<Color>(p.accent),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _progress,
                style: TextStyle(fontSize: 12.5, color: p.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (ratio != null)
              Text(
                '${(ratio * 100).round()}%',
                style: TextStyle(
                  fontSize: 12.5,
                  color: p.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildReport(SyncReport report) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.successSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: p.isDark ? p.border : const Color(0xFFCDEFD8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, size: 17, color: p.success),
              const SizedBox(width: 7),
              Text(
                '同步完成',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: p.success,
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
          Text(
            '提示：同步完成后返回首页重新进入，列表才会显示最新数据。',
            style: TextStyle(fontSize: 12, color: p.success, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _reportRow(String label, String value) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: p.textSecondary)),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              color: p.success,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.dangerSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: p.isDark ? p.border : const Color(0xFFFFD9D9),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 17, color: p.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.65,
                color: p.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final p = context.palette;
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
            style: TextStyle(fontSize: 12, color: p.textTertiary, height: 1.6),
          ),
          const SizedBox(height: 12),
        ],
        TextButton(
          onPressed: _busy ? null : _resetState,
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          child: Text(
            '重置同步状态',
            style: TextStyle(fontSize: 12.5, color: p.textTertiary),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '整库同步是双向的：手机会把整库数据的变化上传到电脑，电脑上改过的内容也会拉回手机。'
          'API Key 等敏感字段不在同步范围内。电脑发起同步时，手机会先弹窗让你确认。',
          style: TextStyle(fontSize: 12, color: p.textTertiary, height: 1.7),
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
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: p.textSecondary,
        ),
      ),
    );
  }
}
