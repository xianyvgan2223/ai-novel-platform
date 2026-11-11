// 小说灵感 — 从已有大纲选择一条（导入设定 / 人物描述用）

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../service/inspiration_import_service.dart';
import 'inspiration_theme.dart';

Future<InspirationOutlineBrief?> showInspirationOutlinePicker(
  BuildContext context, {
  required List<InspirationOutlineBrief> outlines,
  String title = '选择大纲',
}) {
  final p = inspirationPalette(context.palette);
  return showModalBottomSheet<InspirationOutlineBrief>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => InspirationTheme(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
        ),
        decoration: BoxDecoration(
          color: p.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: p.textTertiary,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              if (outlines.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '还没有可用的大纲',
                    style: TextStyle(fontSize: 12.5, color: p.textTertiary),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: outlines.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.border),
                    itemBuilder: (_, i) {
                      final o = outlines[i];
                      return InkWell(
                        onTap: () => Navigator.of(ctx).pop(o),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                o.title.trim().isEmpty ? '未命名作品' : o.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: p.textPrimary,
                                ),
                              ),
                              if (o.theme.trim().isNotEmpty ||
                                  o.worldview.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    [
                                      if (o.theme.trim().isNotEmpty)
                                        '主题：${o.theme.trim()}',
                                      if (o.worldview.trim().isNotEmpty)
                                        '世界观：${o.worldview.trim()}',
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      height: 1.5,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
