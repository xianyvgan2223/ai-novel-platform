// 小说灵感 — 「AI 当前会看到的全部内容」查看页
//
// 只读展示：世界观/主题、已导入大纲及选中事件、注入的人物卡、
// 以及按顺序拼进对话上下文的所有「已采用剧情」。黑白极简排版。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../widget/inspiration_theme.dart';

class InspirationContextPage extends StatefulWidget {
  const InspirationContextPage({super.key, required this.controller});

  final InspirationController controller;

  @override
  State<InspirationContextPage> createState() => _InspirationContextPageState();
}

class _InspirationContextPageState extends State<InspirationContextPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    return InspirationTheme(
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          title: Text(
            '已选内容',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_rounded,
              size: 20,
              color: p.textPrimary,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            _sectionTitle(p, '设定'),
            _kv(p, '世界观', widget.controller.session?.worldView.trim() ?? ''),
            const SizedBox(height: 10),
            _kv(p, '主题', widget.controller.session?.theme.trim() ?? ''),
            const SizedBox(height: 28),
            _sectionTitle(p, '已导入大纲'),
            _buildOutline(p),
            const SizedBox(height: 28),
            _sectionTitle(p, '人物卡'),
            _buildCards(p),
            const SizedBox(height: 28),
            _sectionTitle(p, '已采用剧情（对话上下文）'),
            _buildChosenStory(p),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(AppPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: p.textTertiary,
        ),
      ),
    );
  }

  Widget _kv(AppPalette p, String key, String value) {
    final v = value.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              key,
              style: TextStyle(fontSize: 12, color: p.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              v.isEmpty ? '未填写' : v,
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: v.isEmpty ? p.textTertiary : p.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOutline(AppPalette p) {
    final session = widget.controller.session;
    if (session == null || session.outlineTitle.isEmpty) {
      return Text('未导入', style: TextStyle(fontSize: 13, color: p.textTertiary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '《${session.outlineTitle}》',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${session.events.length} 个事件',
          style: TextStyle(fontSize: 11, color: p.textTertiary),
        ),
        const SizedBox(height: 10),
        if (session.events.isEmpty)
          Text('没有选中事件', style: TextStyle(fontSize: 12, color: p.textTertiary))
        else
          for (var i = 0; i < session.events.length; i++)
            _eventItem(p, session.events[i], i + 1),
      ],
    );
  }

  Widget _eventItem(AppPalette p, InspirationOutlineEvent e, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                e.isMajor ? '大事件' : '小事件',
                style: TextStyle(fontSize: 10, color: p.textTertiary),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (e.summary.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 1),
              child: Text(
                e.summary.trim(),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.65,
                  color: p.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCards(AppPalette p) {
    final cards = widget.controller.cards;
    if (cards.isEmpty) {
      return Text('无', style: TextStyle(fontSize: 13, color: p.textTertiary));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in cards)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.inject ? '注入' : '不注入',
                  style: TextStyle(
                    fontSize: 10,
                    color: c.inject ? p.textPrimary : p.textTertiary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.name.trim().isEmpty ? '未命名人物' : c.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: p.textPrimary,
                        ),
                      ),
                      if (c.personality.trim().isNotEmpty ||
                          c.status.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            [
                              if (c.personality.trim().isNotEmpty)
                                c.personality.trim(),
                              if (c.status.trim().isNotEmpty)
                                '当前：${c.status.trim()}',
                            ].join(' · '),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildChosenStory(AppPalette p) {
    final rounds = <({String instruction, String result})>[];
    for (final m in widget.controller.messages) {
      final chosen = m.branches
          .where((b) => b.chosen && b.content.trim().isNotEmpty)
          .toList();
      if (chosen.isEmpty) continue;
      rounds.add((
        instruction: m.content,
        result: chosen.map((b) => b.content.trim()).join('\n\n'),
      ));
    }
    if (rounds.isEmpty) {
      return Text(
        '暂无已采用剧情',
        style: TextStyle(fontSize: 13, color: p.textTertiary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '共 ${rounds.length} 轮',
          style: TextStyle(fontSize: 11, color: p.textTertiary),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < rounds.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rounds[i].instruction,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textTertiary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  rounds[i].result,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.8,
                    color: p.textPrimary,
                  ),
                ),
                if (i < rounds.length - 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Divider(height: 1, color: p.border),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
