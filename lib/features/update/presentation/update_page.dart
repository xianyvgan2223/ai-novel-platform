import 'package:flutter/material.dart';

import '../../../core/config/app_version.dart';
import '../data/app_update_service.dart';

/// 设置 → 数据管理 → 检查更新
///
/// 只做三件事：向电脑同步服务查最新版本、下载 APK、调起系统安装器。
/// 真正的安装确认仍由 Android 系统完成（无法静默安装）。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final AppUpdateService _service = AppUpdateService();

  bool _checking = true;
  bool _downloading = false;
  double _progress = 0;
  int _currentVersionCode = 0;
  AppUpdateInfo? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final current = await _service.currentVersionCode();
      final info = await _service.check();
      if (!mounted) return;
      setState(() {
        _currentVersionCode = current;
        _info = info;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _checking = false;
      });
    }
  }

  Future<void> _install() async {
    final info = _info;
    if (info == null || _downloading) return;

    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      await _service.downloadAndInstall(
        info,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _progress = (received / total).clamp(0, 1));
        },
      );
      if (!mounted) return;
      _toast('已调起安装，请按系统提示完成');
    } on AppUpdateException catch (e) {
      if (!mounted) return;
      if (e.needPermission) {
        await _askInstallPermission();
      } else {
        _toast(e.message);
      }
    } catch (e) {
      if (!mounted) return;
      _toast('安装失败：$e');
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
      }
    }
  }

  Future<void> _askInstallPermission() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要安装权限'),
        content: const Text(
          'Android 要求由你手动允许本应用「安装未知应用」。\n'
          '打开系统设置并在列表里允许 deepseekapp，然后返回这里再点一次「下载并安装」即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go == true) {
      try {
        await _service.openInstallPermission();
      } catch (e) {
        _toast(e.toString());
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          _currentVersionCard(context),
          const SizedBox(height: 16),
          if (_checking)
            _checkingCard(context)
          else if (_error != null)
            _errorCard(context)
          else if (info != null)
            info.hasUpdate ? _updateCard(context, info) : _latestCard(info),
        ],
      ),
    );
  }

  Widget _currentVersionCard(BuildContext context) {
    return _panel(
      context,
      child: Row(
        children: [
          const Icon(Icons.phone_android_rounded, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('当前版本', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  'v$kAppVersion${_currentVersionCode > 0 ? '（versionCode $_currentVersionCode）' : ''}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkingCard(BuildContext context) {
    return _panel(
      context,
      child: const Column(
        children: [
          SizedBox(height: 8),
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在向电脑检查最新版本…'),
          SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _errorCard(BuildContext context) {
    return _panel(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.red.shade600),
              const SizedBox(width: 8),
              const Text('检查失败', style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Text('$_error', style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(onPressed: _check, child: const Text('重试')),
          ),
        ],
      ),
    );
  }

  Widget _latestCard(AppUpdateInfo info) {
    return _panel(
      context,
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Colors.green.shade600, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '已是最新版本（v${info.versionName}）',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateCard(BuildContext context, AppUpdateInfo info) {
    return _panel(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_rounded, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '发现新版本 v${info.versionName}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              if (info.force)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '必须更新',
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '安装包 ${info.sizeText} · versionCode ${info.versionCode}',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          if (info.changelog.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                info.changelog,
                style: const TextStyle(height: 1.6, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (_downloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            ),
            const SizedBox(height: 8),
            Text(
              _progress > 0
                  ? '正在下载 ${(_progress * 100).toStringAsFixed(1)}%'
                  : '正在连接电脑…',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _install,
                icon: const Icon(Icons.download_rounded),
                label: const Text('下载并安装'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.18)),
      ),
      child: child,
    );
  }
}
