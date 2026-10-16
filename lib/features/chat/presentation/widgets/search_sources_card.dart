// lib/features/chat/presentation/widgets/search_sources_card.dart
// 联网搜索「来源卡片」——历史消息气泡与流式回答共用同一份渲染。
//
// 为什么要抽出来：这段 UI 原先在 message_bubble.dart 与 chat_page.dart 各抄了
// 一份（约 80 行 × 2），加一个字段就要改两处、还容易改漏一处。DeepSeek 官方
// 搜索比百度多出站点名/发布时间/权威性等字段，正好借这次合并。

import 'package:flutter/material.dart';

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

/// 来源卡片
///
/// [collapsible] 为 true 时用于历史消息：默认收起、点击标题栏展开；
/// 为 false 时用于正在流式输出的回答：始终展开，且不显示折叠箭头。
class SearchSourcesCard extends StatefulWidget {
  final List<Map<String, dynamic>> results;
  final bool collapsible;

  /// 最多展示几条（其余只在弹窗/上下文里体现）
  final int maxItems;

  const SearchSourcesCard({
    super.key,
    required this.results,
    this.collapsible = true,
    this.maxItems = 5,
  });

  @override
  State<SearchSourcesCard> createState() => _SearchSourcesCardState();
}

class _SearchSourcesCardState extends State<SearchSourcesCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final views = widget.results
        .map(SearchResultView.fromMap)
        .take(widget.maxItems)
        .toList(growable: false);
    final showList = !widget.collapsible || _expanded;

    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEFF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFB3C5FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.public, size: 14, color: Color(0xFF4D6BFE)),
              const SizedBox(width: 4),
              Text(
                '搜索来源（${widget.results.length}）',
                style: const TextStyle(fontSize: 11, color: Color(0xFF4D6BFE)),
              ),
              if (widget.collapsible) ...[
                const Spacer(),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 14,
                  color: const Color(0xFF4D6BFE),
                ),
              ],
            ],
          ),
          if (showList) ...[
            const SizedBox(height: 6),
            ...views.map(
              (r) => GestureDetector(
                onTap: () => showSearchDetailDialog(context, r),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF333333),
                        ),
                      ),
                      if (r.meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            r.meta,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFF888888),
                            ),
                          ),
                        ),
                      if (r.snippet.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            r.snippet,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF666666),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (r.url.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            r.url,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFF4D6BFE),
                              decoration: TextDecoration.underline,
                            ),
                            // 有些来源链接带 accessToken 之类的查询串，长度能到几百字符，
                            // 不限制的话一张卡片会被 URL 撑满（真机实测），这里压成一行
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (!widget.collapsible) return card;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: card,
    );
  }
}
