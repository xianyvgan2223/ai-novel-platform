// 小说灵感 — 人物卡（只在本功能生效）
//
// 人物卡包含姓名 / 性格 / 经历过的事件 / 技能 / 当前状态，可勾选注入推演；
// 「AI 生成状态」会依据本功能里选中的大纲事件推演人物当前状态。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../widget/inspiration_card_editor_sheet.dart';
import '../widget/inspiration_theme.dart';

class InspirationCharacterCardsPage extends StatefulWidget {
  const InspirationCharacterCardsPage({super.key, required this.controller});

  final InspirationController controller;

  @override
  State<InspirationCharacterCardsPage> createState() =>
      _InspirationCharacterCardsPageState();
}

class _InspirationCharacterCardsPageState
    extends State<InspirationCharacterCardsPage> {
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

  Future<void> _openEditor({InspirationCharacterCard? card}) async {
    final sessionId = widget.controller.session?.id;
    if (sessionId == null) return;
    await showInspirationCardEditor(
      context,
      controller: widget.controller,
      sessionId: sessionId,
      card: card,
    );
  }

  Future<void> _toggleInject(InspirationCharacterCard card) async {
    await widget.controller.saveCard(card.copyWith(inject: !card.inject));
  }

  Future<void> _delete(InspirationCharacterCard card) async {
    final p = inspirationPalette(context.palette);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          '删除人物卡？',
          style: TextStyle(fontSize: 15, color: p.textPrimary),
        ),
        content: Text(
          '「${card.name}」会从本功能中删除，不影响其它功能。',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: p.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: p.danger)),
          ),
        ],
      ),
    );
    if (ok == true && card.id != null) {
      await widget.controller.deleteCard(card.id!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final cards = widget.controller.cards;
    return InspirationTheme(
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          title: Text(
            '人物卡',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: p.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            IconButton(
              tooltip: '新增人物卡',
              icon: Icon(Icons.person_add_alt_1_rounded, color: p.accent),
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        body: cards.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.people_outline_rounded,
                        size: 44,
                        color: p.textTertiary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '还没有人物卡',
                        style: TextStyle(fontSize: 14, color: p.textSecondary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '仅在本功能生效',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.7,
                          color: p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                itemCount: cards.length,
                itemBuilder: (context, index) {
                  final card = cards[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: p.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  card.name.trim().isEmpty
                                      ? '未命名人物'
                                      : card.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: p.textPrimary,
                                  ),
                                ),
                              ),
                              Text(
                                card.inject ? '注入中' : '不注入',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: card.inject
                                      ? p.accent
                                      : p.textTertiary,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: card.inject,
                                  activeTrackColor: p.accent,
                                  onChanged: (_) => _toggleInject(card),
                                ),
                              ),
                            ],
                          ),
                          if (card.description.trim().isNotEmpty)
                            _line(context, '描述', card.description),
                          if (card.personality.trim().isNotEmpty)
                            _line(context, '性格', card.personality),
                          if (card.experiences.trim().isNotEmpty)
                            _line(context, '经历', card.experiences),
                          if (card.skills.trim().isNotEmpty)
                            _line(context, '技能', card.skills),
                          if (card.status.trim().isNotEmpty)
                            _line(context, '当前状态', card.status),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => _openEditor(card: card),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: p.accent,
                                ),
                                icon: const Icon(Icons.edit_outlined, size: 15),
                                label: const Text(
                                  '编辑',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => _openEditor(card: card),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: p.textSecondary,
                                ),
                                icon: const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 15,
                                ),
                                label: const Text(
                                  'AI 生成状态',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: '删除',
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                  color: p.textTertiary,
                                ),
                                onPressed: () => _delete(card),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    final p = inspirationPalette(context.palette);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: RichText(
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: TextStyle(fontSize: 12, height: 1.55, color: p.textSecondary),
          children: [
            TextSpan(
              text: '$label：',
              style: TextStyle(
                color: p.textTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: value.trim()),
          ],
        ),
      ),
    );
  }
}
