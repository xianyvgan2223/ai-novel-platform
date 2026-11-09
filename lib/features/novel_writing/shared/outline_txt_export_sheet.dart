import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import 'domain/outline_record.dart';

/// 显示「选择要导出的作品」底部弹层。
///
/// 返回用户点的那部作品摘要（只含轻字段，正文由调用方按 id 再读）；
/// 点空白处 / 返回键关闭时返回 null（页面据此静默结束，不提示）。
Future<OutlineRecord?> showOutlineTxtExportSheet(
  BuildContext context,
  List<OutlineRecord> novels,
) {
  return showModalBottomSheet<OutlineRecord>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _OutlineTxtExportSheet(novels: novels),
  );
}

class _OutlineTxtExportSheet extends StatelessWidget {
  final List<OutlineRecord> novels;

  const _OutlineTxtExportSheet({required this.novels});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部拖动条：给系统手势一个视觉落点
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: p.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择要导出的作品',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 20, color: p.textTertiary),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '导出该作品的大纲正文为 txt 文件（UTF-8）· 自动统一事件编号',
                style: TextStyle(fontSize: 11.5, color: p.textTertiary),
              ),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                bottom: 12 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: novels.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: p.border,
              ),
              itemBuilder: (context, index) {
                final novel = novels[index];
                return _NovelTile(
                  novel: novel,
                  onTap: () => Navigator.of(context).pop(novel),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NovelTile extends StatelessWidget {
  final OutlineRecord novel;
  final VoidCallback onTap;

  const _NovelTile({required this.novel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = novel.title.trim().isEmpty ? '未命名大纲' : novel.title.trim();
    final genre = novel.genre.trim();
    final meta = genre.isEmpty
        ? novel.formattedDate
        : '${novel.formattedDate} · $genre';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.accentSoft,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                title.characters.isEmpty ? '书' : title.characters.first,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: p.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: TextStyle(fontSize: 11, color: p.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.file_download_outlined, size: 18, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}
