// lib/features/chat/presentation/widgets/search_sources_card.dart
// 联网搜索「来源入口」——回答结束后显示的一枚小胶囊，点击打开来源列表。
//
// 样式参考豆包：聊天里只留一行很轻的「参考 N 篇资料」，中性灰底、按内容
// 宽度，不占满气泡；来源列表放进底部弹层，避免一张高饱和色块压在回答下面。
//
// 兼容百度链路（name/link）与 DeepSeek 官方搜索（title/url/site_name/date）。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

/// 搜索结果在界面上的视图模型。
///
/// 兼容两种来源的键名：百度链路写 `name`，DeepSeek 官方搜索写 `title`；
/// 链接同理有 `url` / `link`。summary / site_name / date 是 DeepSeek 独有的
/// 附加字段，老数据读不到就是空串。
class SearchResultView {
  final String title;
  final String url;
  final String snippet;
  final String summary;
  final String content;
  final String siteName;
  final String date;

  const SearchResultView({
    required this.title,
    required this.url,
    required this.snippet,
    required this.summary,
    required this.content,
    required this.siteName,
    required this.date,
  });

  factory SearchResultView.fromMap(Map<String, dynamic> r) {
    String str(String key) => r[key]?.toString() ?? '';
    return SearchResultView(
      title: r['name']?.toString() ?? str('title'),
      url: r['url']?.toString() ?? str('link'),
      snippet: str('snippet'),
      summary: str('summary'),
      content: str('content'),
      siteName: str('site_name'),
      date: str('date'),
    );
  }

  /// 详情里优先展示正文，没有正文时退回长摘要（两者内容重叠，不重复列）
  String get longText => content.isNotEmpty ? content : summary;

  /// 「站点 · 日期」一行元信息；日期只取到天（接口给的是 UTC RFC 3339）
  String get meta {
    final day = date.length >= 10 ? date.substring(0, 10) : date;
    return [siteName, day].where((s) => s.isNotEmpty).join(' · ');
  }
}

/// 搜索详情弹窗：点开单条来源看完整摘要/正文
void showSearchDetailDialog(BuildContext context, SearchResultView r) {
  final buffer = StringBuffer();
  if (r.title.isNotEmpty) buffer.writeln('标题：${r.title}');
  if (r.url.isNotEmpty) buffer.writeln('链接：${r.url}');
  if (r.meta.isNotEmpty) buffer.writeln('来源：${r.meta}');
  if (r.snippet.isNotEmpty) buffer.writeln('\n摘要：\n${r.snippet}');
  if (r.longText.isNotEmpty) {
    buffer.writeln('\n${r.content.isNotEmpty ? '正文' : '详细摘要'}：\n${r.longText}');
  }
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('搜索详情', style: TextStyle(fontSize: 14)),
      content: SingleChildScrollView(
        child: SelectableText(
          buffer.toString(),
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭', style: TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

/// 来源入口：回答气泡下方的一枚小胶囊。
///
/// 只展示「参考 N 篇资料」，不再在聊天流里平铺来源列表；点击后从底部弹层
/// 查看来源，点单条来源再打开完整摘要/正文。
class SearchSourcesCard extends StatelessWidget {
  final List<Map<String, dynamic>> results;

  /// 弹层里最多列几条（其余只计入总数）
  final int maxItems;

  const SearchSourcesCard({
    super.key,
    required this.results,
    this.maxItems = 30,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    final views = results
        .map(SearchResultView.fromMap)
        .take(maxItems)
        .toList(growable: false);

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openSourcesSheet(context, views, results.length),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.travel_explore_rounded,
                  size: 12,
                  color: p.textTertiary,
                ),
                const SizedBox(width: 4),
                Text(
                  '参考 ${results.length} 篇资料',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: p.textSecondary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 13,
                  color: p.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSourcesSheet(
    BuildContext context,
    List<SearchResultView> views,
    int total,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = ctx.palette;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
          ),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: p.borderStrong,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            '参考来源',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '$total 篇',
                            style: TextStyle(
                              fontSize: 11,
                              color: p.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.border),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    itemCount: views.length,
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: p.border),
                    itemBuilder: (context, index) =>
                        _SourceRow(view: views[index], index: index),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 弹层里的一条来源：序号 + 标题 + 站点/日期 + 摘要。
class _SourceRow extends StatelessWidget {
  final SearchResultView view;
  final int index;

  const _SourceRow({required this.view, required this.index});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showSearchDetailDialog(context, view),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: p.border),
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: p.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    view.title.isEmpty ? '未命名来源' : view.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: p.textPrimary,
                    ),
                  ),
                  if (view.meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      view.meta,
                      style: TextStyle(fontSize: 10, color: p.textTertiary),
                    ),
                  ],
                  if (view.snippet.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      view.snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 14, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}
