// lib/game/trpg/view/page/trpg_character_create_page.dart
// 跑团角色卡创建页 — 六维属性 / 职业 / 技能熟练

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../model/character_sheet.dart';
import '../../data/trpg_db_service.dart';
import 'trpg_game_page.dart';

class TrpgCharacterCreatePage extends StatefulWidget {
  final int campaignId;

  const TrpgCharacterCreatePage({super.key, required this.campaignId});

  @override
  State<TrpgCharacterCreatePage> createState() =>
      _TrpgCharacterCreatePageState();
}

class _TrpgCharacterCreatePageState extends State<TrpgCharacterCreatePage> {
  final _nameCtrl = TextEditingController();
  final _backgroundCtrl = TextEditingController();

  String _race = '人类';
  String _charClass = '战士';
  final Map<String, int> _abilities = {
    'strength': 10,
    'dexterity': 10,
    'constitution': 10,
    'intelligence': 10,
    'wisdom': 10,
    'charisma': 10,
  };
  int _armorBonus = 0;
  final Set<String> _skilledSkills = {};

  static const _races = ['人类', '精灵', '矮人', '半身人', '龙裔', '提夫林', '半兽人'];
  static const _classes = [
    '战士',
    '野蛮人',
    '游侠',
    '圣武士',
    '法师',
    '术士',
    '牧师',
    '德鲁伊',
    '游荡者',
    '吟游诗人',
    '武僧',
  ];
  static const _classHitDice = <String, int>{
    '战士': 10,
    '野蛮人': 12,
    '游侠': 10,
    '圣武士': 10,
    '法师': 6,
    '术士': 6,
    '牧师': 8,
    '德鲁伊': 8,
    '游荡者': 8,
    '吟游诗人': 8,
    '武僧': 8,
  };

  @override
  void dispose() {
    _nameCtrl.dispose();
    _backgroundCtrl.dispose();
    super.dispose();
  }

  int get _conMod => CharacterSheet.modifierOf(_abilities['constitution']!);
  int get _maxHp => (_classHitDice[_charClass] ?? 8) + _conMod;
  int get _dexMod => CharacterSheet.modifierOf(_abilities['dexterity']!);
  int get _ac => 10 + _dexMod + _armorBonus;

  void _rollAbilities() {
    setState(() {
      _abilities.addAll(CharacterSheet.generateRandomAbilities());
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写角色姓名')));
      return;
    }

    final sheet = CharacterSheet(
      campaignId: widget.campaignId,
      name: name,
      race: _race,
      charClass: _charClass,
      level: 1,
      str: _abilities['strength']!,
      dex: _abilities['dexterity']!,
      con: _abilities['constitution']!,
      intl: _abilities['intelligence']!,
      wis: _abilities['wisdom']!,
      cha: _abilities['charisma']!,
      maxHp: _maxHp,
      currentHp: _maxHp,
      armorBonus: _armorBonus,
      skilledSkills: _skilledSkills,
      background: _backgroundCtrl.text.trim(),
      isPlayer: true,
    );

    await TrpgDbService.saveCharacter(sheet);

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TrpgGamePage(campaignId: widget.campaignId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        toolbarHeight: 44,
        backgroundColor: p.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '创建角色',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              '开始冒险',
              style: TextStyle(fontSize: 13, color: p.accent),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('基本信息'),
          _card(
            Column(
              children: [
                _textField(_nameCtrl, '姓名'),
                const SizedBox(height: 12),
                _dropdown('种族', _race, _races, (v) => setState(() => _race = v)),
                const SizedBox(height: 12),
                _dropdown(
                  '职业',
                  _charClass,
                  _classes,
                  (v) => setState(() => _charClass = v),
                ),
                const SizedBox(height: 12),
                _infoRow(
                  '生命值上限',
                  '$_maxHp（职业生命骰 + 体质调整）',
                ),
                const SizedBox(height: 8),
                _infoRow('护甲等级 AC', '$_ac'),
                const SizedBox(height: 12),
                _armorSlider(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('六维属性'),
          _card(
            Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _rollAbilities,
                    icon: const Icon(Icons.casino, size: 16),
                    label: const Text('随机生成（4d6取高3）'),
                    style: TextButton.styleFrom(
                      foregroundColor: p.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                  ),
                ),
                ...CharacterSheet.abilityLabels.entries.map(
                  (e) => _abilitySlider(e.key, e.value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('熟练技能'),
          _card(
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: CharacterSheet.skillLabels.entries.map((e) {
                final selected = _skilledSkills.contains(e.key);
                return FilterChip(
                  label: Text(e.value, style: const TextStyle(fontSize: 12)),
                  selected: selected,
                  onSelected: (v) => setState(() {
                    if (v) {
                      _skilledSkills.add(e.key);
                    } else {
                      _skilledSkills.remove(e.key);
                    }
                  }),
                  selectedColor: p.accent.withValues(alpha: 0.15),
                  checkmarkColor: p.accent,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('背景故事'),
          _card(
            TextField(
              controller: _backgroundCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '角色的背景、动机等（喂给主持人）',
                hintStyle: TextStyle(fontSize: 13, color: p.textTertiary),
                border: InputBorder.none,
              ),
              style: TextStyle(fontSize: 13, color: p.textPrimary),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.onAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('开始冒险', style: TextStyle(fontSize: 14)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: p.textSecondary,
        ),
      ),
    );
  }

  Widget _card(Widget child) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: p.isDark ? Border.all(color: p.border) : null,
        boxShadow: p.isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _textField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 13),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> items,
    ValueChanged<String> onChanged,
  ) {
    final p = context.palette;
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: p.textSecondary)),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: value,
            items: items
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => onChanged(v ?? value),
            style: TextStyle(fontSize: 13, color: p.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    final p = context.palette;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: p.textSecondary)),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _abilitySlider(String key, String label) {
    final p = context.palette;
    final value = _abilities[key]!;
    final mod = CharacterSheet.modifierOf(value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: 3,
              max: 18,
              divisions: 15,
              label: '$value',
              activeColor: p.accent,
              onChanged: (v) => setState(() => _abilities[key] = v.round()),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '$value (${mod >= 0 ? '+' : ''}$mod)',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _armorSlider() {
    final p = context.palette;
    return Row(
      children: [
        Text(
          '护甲加值',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
        Expanded(
          child: Slider(
            value: _armorBonus.toDouble(),
            min: 0,
            max: 5,
            divisions: 5,
            label: '$_armorBonus',
            activeColor: p.accent,
            onChanged: (v) => setState(() => _armorBonus = v.round()),
          ),
        ),
        Text(
          '$_armorBonus',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
      ],
    );
  }
}
