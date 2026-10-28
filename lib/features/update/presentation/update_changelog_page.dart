// lib/features/update/presentation/update_changelog_page.dart
// 更新日志：按版本从新到旧回看每次的更新公告，供设置页入口打开。

import 'package:flutter/material.dart';

import '../../../core/config/app_version.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/widgets/settings_kit.dart';
import '../data/update_announcement.dart';

class UpdateChangelogPage extends StatelessWidget {
  const UpdateChangelogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: const SettingsAppBar(title: '更新日志'),
      body: ListView(
        padding: EdgeInsets.only(
          top: 2,
          left: kSettingsCardMarginH,
          right: kSettingsCardMarginH,
          bottom: 40 + MediaQuery.paddingOf(context).bottom,
        ),
        children: <Widget>[
          const SettingsSectionHeader(
            icon: Icons.history_rounded,
            title: '版本记录',
            subtitle: '每个版本的更新公告，最新的在上',
            isFirst: true,
          ),
          for (var i = 0; i < updateAnnouncementHistory.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _ChangelogCard(
              announcement: updateAnnouncementHistory[i],
              isCurrent:
                  updateAnnouncementHistory[i].releaseId == kAppReleaseId,
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangelogCard extends StatelessWidget {
  const _ChangelogCard({required this.announcement, required this.isCurrent});

  final UpdateAnnouncement announcement;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SettingsCard(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSettingsCardPadH,
            16,
            kSettingsCardPadH,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    'v${announcement.version}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                      height: 1.25,
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: p.accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '当前版本',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: p.accent,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (announcement.date.isNotEmpty)
                    Text(
                      announcement.date,
                      style: TextStyle(
                        fontSize: 11,
                        color: p.textTertiary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                announcement.subtitle,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: p.textSecondary,
                ),
              ),
              for (final item in announcement.items) ...[
                const SizedBox(height: 9),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
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
                        item,
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
            ],
          ),
        ),
      ],
    );
  }
}
