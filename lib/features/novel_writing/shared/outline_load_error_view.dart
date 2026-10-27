import 'package:flutter/material.dart';

import 'package:deepseekapp/core/theme/app_palette.dart';

/// 大纲数据加载失败时的占位视图。
///
/// 以前这些页面把异常 `catch (_) {}` 吞掉，界面直接显示「还没有大纲」，
/// 让人误以为库里没有数据（实际是查询抛了 "Row too big to fit into
/// CursorWindow" 之类的错）。现在把错误显示出来，并提供重试。
class OutlineLoadErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const OutlineLoadErrorView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: p.danger),
            const SizedBox(height: 12),
            Text(
              '大纲加载失败',
              style: TextStyle(fontSize: 15, color: p.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.textTertiary),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
