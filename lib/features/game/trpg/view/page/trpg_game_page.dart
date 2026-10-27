// lib/game/trpg/view/page/trpg_game_page.dart
// 跑团模拟器主游戏页 — 叙事流 + 骰子判定 + 行动输入

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../controller/trpg_controller.dart';
import '../../model/character_sheet.dart';
import '../../model/dm_response.dart';
import '../../data/trpg_db_service.dart';

class TrpgGamePage extends StatefulWidget {
  final int campaignId;

  const TrpgGamePage({super.key, required this.campaignId});

  @override
  State<TrpgGamePage> createState() => _TrpgGamePageState();
}

class _TrpgGamePageState extends State<TrpgGamePage> {
  late final TrpgController _controller;
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = TrpgController();
    _controller.addListener(_onChanged);
    _load();
  }

  Future<void> _load() async {
    await _controller.loadCampaign(widget.campaignId);
    if (mounted) setState(() => _loaded = true);
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final t = text ?? _inputCtrl.text;
    if (t.trim().isEmpty || _controller.isLoading) return;
    _inputCtrl.clear();
    _controller.sendAction(t);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!_loaded) {
      return Scaffold(
        backgroundColor: p.background,
        body: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final character = _controller.character;
    final messages = _controller.messages;
    final pendingCheck = _controller.pendingCheck;
    final error = _controller.error;

    return Scaffold(
      backgroundColor: p.background,
      appBar: _buildAppBar(character),
      body: Column(
        children: [
          if (error != null) _buildErrorBar(error),
          _buildSceneBar(),
          Expanded(child: _buildMessageList(messages, _controller.isLoading)),
          if (pendingCheck != null) _buildCheckBar(pendingCheck),
          _buildInputArea(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(CharacterSheet? character) {
    final p = context.palette;
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: p.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back, size: 20, color: p.textPrimary),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(13),
            ),
            alignment: Alignment.center,
            child: Text(
              character?.name.characters.first ?? '?',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: p.accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            character == null
                ? '冒险'
                : '${character.name}（${character.charClass}）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: Icon(
            Icons.badge_outlined,
            size: 20,
            color: p.textPrimary,
          ),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: () => _showCharacterSheet(character),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, color: p.border),
      ),
    );
  }

  Widget _buildErrorBar(String error) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: p.dangerSoft,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              error,
              style: TextStyle(fontSize: 11, color: p.danger),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSceneBar() {
    final p = context.palette;
    final scene = _controller.campaign?.scene ?? '';
    final hp = _controller.character;
    final hpColor = p.isDark
        ? const Color(0xFFFF8A80)
        : const Color(0xFFE74C3C);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: p.accentSoft,
      child: Row(
        children: [
          Icon(Icons.place_outlined, size: 14, color: p.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              scene.isEmpty ? '冒险即将开始…' : scene,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: p.accent),
            ),
          ),
          if (hp != null)
            Text(
              'HP ${hp.currentHp}/${hp.maxHp}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: hpColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<TrpgMessage> messages, bool isLoading) {
    final p = context.palette;
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.casino, size: 40, color: p.textTertiary),
            const SizedBox(height: 10),
            Text(
              '输入行动，开始你的冒险',
              style: TextStyle(fontSize: 13, color: p.textTertiary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: messages.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          return _MessageBubble(message: messages[index]);
        }
        return const _TypingIndicator();
      },
    );
  }

  Widget _buildCheckBar(CheckInfo check) {
    final p = context.palette;
    final accentGold = p.isDark ? p.warning : const Color(0xFF997A00);
    final type = check.type;
    final skill = check.skill;
    final dc = check.dc;
    final desc = check.description;
    final abilityName = CharacterSheet.abilityLabels[type] ?? type;
    final skillName = skill != null
        ? CharacterSheet.skillLabels[skill] ?? skill
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: p.isDark
          ? p.warning.withValues(alpha: 0.14)
          : const Color(0xFFFFF9E6),
      child: Row(
        children: [
          Icon(Icons.casino, size: 18, color: accentGold),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '需要 $abilityName${skillName != null ? '($skillName)' : ''}检定，DC $dc',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: accentGold,
                  ),
                ),
                if (desc.isNotEmpty)
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11,
                      color: p.isDark ? p.warning : const Color(0xFFB08A00),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _controller.isLoading ? null : _controller.rollCheck,
            style: ElevatedButton.styleFrom(
              backgroundColor: accentGold,
              foregroundColor: p.isDark ? p.onAccent : Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('掷骰', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border, width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _actionChip('观察', '我仔细观察周围的环境'),
                  _actionChip('调查', '我调查当前区域'),
                  _actionChip('潜行', '我尝试悄悄地行动'),
                  _actionChip('说服', '我尝试说服对方'),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    style: TextStyle(
                      fontSize: 13,
                      color: p.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: '描述你的行动…',
                      hintStyle: TextStyle(
                        color: p.textTertiary,
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: p.surfaceMuted,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _controller.isLoading
                      ? _controller.cancelRequest
                      : _send,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _controller.isLoading ? p.danger : p.accent,
                      borderRadius: BorderRadius.circular(17),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _controller.isLoading ? Icons.stop : Icons.arrow_upward,
                      size: 16,
                      color: p.onAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(String label, String action) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: _controller.isLoading ? null : () => _send(action),
        backgroundColor: p.accentSoft,
        labelStyle: TextStyle(color: p.accent, fontSize: 12),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  void _showCharacterSheet(CharacterSheet? character) {
    if (character == null) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final p = ctx.palette;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${character.name}（${character.race} ${character.charClass}）',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _statBox('HP', '${character.currentHp}/${character.maxHp}'),
                  _statBox('AC', '${character.ac}'),
                  _statBox('熟练', '+${character.proficiencyBonus}'),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: CharacterSheet.abilityLabels.entries.map((e) {
                  final score = _abilityScore(character, e.key);
                  final mod = character.abilityModifier(e.key);
                  return _statBox(
                    e.value,
                    '$score (${mod >= 0 ? '+' : ''}$mod)',
                  );
                }).toList(),
              ),
              if (character.skilledSkills.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '熟练技能',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  character.skilledSkills
                      .map((s) => CharacterSheet.skillLabels[s] ?? s)
                      .join('、'),
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textPrimary,
                  ),
                ),
              ],
              if (character.inventory.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '背包',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  character.inventory.join('、'),
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textPrimary,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  int _abilityScore(CharacterSheet c, String ability) {
    switch (ability) {
      case 'strength':
        return c.str;
      case 'dexterity':
        return c.dex;
      case 'constitution':
        return c.con;
      case 'intelligence':
        return c.intl;
      case 'wisdom':
        return c.wis;
      case 'charisma':
        return c.cha;
      default:
        return 0;
    }
  }

  Widget _statBox(String label, String value) {
    final p = context.palette;
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: p.textTertiary),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final TrpgMessage message;

  const _MessageBubble({required this.message});

  bool get _isRoll => message.meta.containsKey('roll');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 骰子判定结果：居中卡片
    if (_isRoll) {
      final roll = message.meta['roll'] as Map<String, dynamic>? ?? {};
      final success = roll['success'] == true;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: success ? p.successSoft : p.dangerSoft,
          borderRadius: BorderRadius.circular(10),
          border: p.isDark
              ? Border.all(
                  color: success
                      ? p.success.withValues(alpha: 0.35)
                      : p.danger.withValues(alpha: 0.35),
                )
              : null,
        ),
        child: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.cancel,
              size: 16,
              color: success ? p.success : p.danger,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message.content,
                style: TextStyle(
                  fontSize: 12,
                  color: success ? p.success : p.danger,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.widthOf(context) * 0.82,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUser ? p.bubbleUser : p.bubbleAssistant,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(isUser ? 14 : 4),
                topRight: Radius.circular(isUser ? 4 : 14),
                bottomLeft: const Radius.circular(14),
                bottomRight: const Radius.circular(14),
              ),
              border: !isUser && p.isDark
                  ? Border.all(color: p.border)
                  : null,
              boxShadow: isUser || p.isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
            ),
            child: SelectableText(
              message.content,
              style: TextStyle(
                fontSize: 13,
                color: isUser ? p.bubbleUserText : p.bubbleAssistantText,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: p.bubbleAssistant,
                borderRadius: BorderRadius.circular(16),
                border: p.isDark ? Border.all(color: p.border) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(p.textTertiary),
                  const SizedBox(width: 4),
                  _Dot(p.textTertiary),
                  const SizedBox(width: 4),
                  _Dot(p.textTertiary),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '主持人正在叙述…',
              style: TextStyle(fontSize: 11, color: p.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot(this.color);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 6,
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
