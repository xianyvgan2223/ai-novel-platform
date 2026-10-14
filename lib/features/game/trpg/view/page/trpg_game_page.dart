// lib/game/trpg/view/page/trpg_game_page.dart
// 跑团模拟器主游戏页 — 叙事流 + 骰子判定 + 行动输入

import 'package:flutter/material.dart';
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
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8F8F8),
        body: Center(
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
      backgroundColor: const Color(0xFFF8F8F8),
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
    return AppBar(
      toolbarHeight: 44,
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20, color: Color(0xFF333333)),
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
              color: const Color(0xFF4D6BFE).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(13),
            ),
            alignment: Alignment.center,
            child: Text(
              character?.name.characters.first ?? '?',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4D6BFE),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            character == null
                ? '冒险'
                : '${character.name}（${character.charClass}）',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        IconButton(
          icon: const Icon(
            Icons.badge_outlined,
            size: 20,
            color: Color(0xFF333333),
          ),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: () => _showCharacterSheet(character),
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
      ),
    );
  }

  Widget _buildErrorBar(String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFFFEBEE),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 14, color: Colors.red),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(fontSize: 11, color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSceneBar() {
    final scene = _controller.campaign?.scene ?? '';
    final hp = _controller.character;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFFF0F2FF),
      child: Row(
        children: [
          const Icon(Icons.place_outlined, size: 14, color: Color(0xFF4D6BFE)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              scene.isEmpty ? '冒险即将开始…' : scene,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
            ),
          ),
          if (hp != null)
            Text(
              'HP ${hp.currentHp}/${hp.maxHp}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE74C3C),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<TrpgMessage> messages, bool isLoading) {
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.casino, size: 40, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 10),
            const Text(
              '输入行动，开始你的冒险',
              style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
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
      color: const Color(0xFFFFF9E6),
      child: Row(
        children: [
          const Icon(Icons.casino, size: 18, color: Color(0xFF997A00)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '需要 $abilityName${skillName != null ? '($skillName)' : ''}检定，DC $dc',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF997A00),
                  ),
                ),
                if (desc.isNotEmpty)
                  Text(
                    desc,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFB08A00),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _controller.isLoading ? null : _controller.rollCheck,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF997A00),
              foregroundColor: Colors.white,
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
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
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
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF333333),
                    ),
                    decoration: InputDecoration(
                      hintText: '描述你的行动…',
                      hintStyle: const TextStyle(
                        color: Color(0xFFBBBBBB),
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF5F5F5),
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
                      color: _controller.isLoading
                          ? Colors.redAccent
                          : const Color(0xFF4D6BFE),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      _controller.isLoading ? Icons.stop : Icons.arrow_upward,
                      size: 16,
                      color: Colors.white,
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
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: _controller.isLoading ? null : () => _send(action),
        backgroundColor: const Color(0xFFF0F2FF),
        labelStyle: const TextStyle(color: Color(0xFF4D6BFE), fontSize: 12),
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${character.name}（${character.race} ${character.charClass}）',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
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
                const Text(
                  '熟练技能',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF666666),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  character.skilledSkills
                      .map((s) => CharacterSheet.skillLabels[s] ?? s)
                      .join('、'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF333333),
                  ),
                ),
              ],
              if (character.inventory.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  '背包',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF666666),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  character.inventory.join('、'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF333333),
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
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Color(0xFF333333),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Color(0xFF999999)),
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
    // 骰子判定结果：居中卡片
    if (_isRoll) {
      final roll = message.meta['roll'] as Map<String, dynamic>? ?? {};
      final success = roll['success'] == true;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: success ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.cancel,
              size: 16,
              color: success
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFC62828),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message.content,
                style: TextStyle(
                  fontSize: 12,
                  color: success
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFC62828),
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
              color: isUser ? const Color(0xFF4D6BFE) : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(isUser ? 14 : 4),
                topRight: Radius.circular(isUser ? 4 : 14),
                bottomLeft: const Radius.circular(14),
                bottomRight: const Radius.circular(14),
              ),
              boxShadow: isUser
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
                color: isUser ? Colors.white : const Color(0xFF333333),
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
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(),
                  SizedBox(width: 4),
                  _Dot(),
                  SizedBox(width: 4),
                  _Dot(),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '主持人正在叙述…',
              style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 6,
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFF999999),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
