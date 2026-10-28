// lib/features/update/presentation/update_announcement_dialog.dart
// 首次打开新版本时展示的更新公告：小卡片 + 发丝边框 + 小字号 + 右下角文字按钮。

import 'package:flutter/material.dart';

import '../../../core/theme/app_palette.dart';
import '../data/update_announcement.dart';

Future<void> showUpdateAnnouncementDialog(
  BuildContext context,
  UpdateAnnouncement announcement,
) {
  final p = context.palette;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '更新公告',
    barrierColor: p.overlay,
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (context, animation, secondaryAnimation) {
      return _UpdateAnnouncementCard(announcement: announcement);
    },
  );
}

class _UpdateAnnouncementCard extends StatelessWidget {
  const _UpdateAnnouncementCard({required this.announcement});

  final UpdateAnnouncement announcement;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      // 视觉重心略高于几何中心，避免卡片「压在下半屏」。
      alignment: const Alignment(0, -0.18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: p.surfaceElevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: p.border),
                boxShadow: p.isDark
                    ? null
                    : <BoxShadow>[
                        BoxShadow(
                          color: p.shadow,
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '更新公告',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.3,
                            color: p.textTertiary,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: p.surfaceMuted,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'v${announcement.version}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      announcement.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      announcement.subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: p.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: p.border),
                    const SizedBox(height: 12),
                    for (var i = 0; i < announcement.items.length; i++) ...[
                      if (i > 0) const SizedBox(height: 9),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 3,
                            height: 3,
                            margin: const EdgeInsets.only(top: 7),
                            decoration: BoxDecoration(
                              color: p.textTertiary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              announcement.items[i],
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.5,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: p.accent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('知道了'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
