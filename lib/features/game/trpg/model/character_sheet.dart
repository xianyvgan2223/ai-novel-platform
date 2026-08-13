// lib/game/trpg/model/character_sheet.dart
// TRPG 角色卡 — DnD d20 风格的六维属性卡（玩家与 NPC 共用）

import 'dart:convert';
import 'dice.dart';

class CharacterSheet {
  final int? id;
  final int campaignId;
  final String name;
  final String race;
  final String charClass;
  final int level;

  // 六维属性（3~18）
  final int str;
  final int dex;
  final int con;
  final int intl;
  final int wis;
  final int cha;

  final int maxHp;
  final int currentHp;
  final int armorBonus;
  final Set<String> skilledSkills;
  final List<String> inventory;
  final String background;
  final bool isPlayer;

  const CharacterSheet({
    this.id,
    required this.campaignId,
    required this.name,
    this.race = '',
    this.charClass = '',
    this.level = 1,
    this.str = 10,
    this.dex = 10,
    this.con = 10,
    this.intl = 10,
    this.wis = 10,
    this.cha = 10,
    this.maxHp = 10,
    this.currentHp = 10,
    this.armorBonus = 0,
    this.skilledSkills = const {},
    this.inventory = const [],
    this.background = '',
    this.isPlayer = true,
  });

  /// 属性调整值：(属性 - 10) / 2（向下取整，DnD 规则）
  static int modifierOf(int score) => (score - 10) ~/ 2;

  int get strMod => modifierOf(str);
  int get dexMod => modifierOf(dex);
  int get conMod => modifierOf(con);
  int get intMod => modifierOf(intl);
  int get wisMod => modifierOf(wis);
  int get chaMod => modifierOf(cha);

  /// 熟练加值：2 + (等级-1)/4（1~4 级为 +2）
  int get proficiencyBonus => 2 + (level - 1) ~/ 4;

  /// 护甲等级：10 + 敏捷调整 + 护甲加值
  int get ac => 10 + dexMod + armorBonus;

  /// 先攻加值
  int get initiative => dexMod;

  // ── 属性名称与技能映射 ──

  /// 属性 key → 中文名
  static const abilityLabels = <String, String>{
    'strength': '力量',
    'dexterity': '敏捷',
    'constitution': '体质',
    'intelligence': '智力',
    'wisdom': '感知',
    'charisma': '魅力',
  };

  /// 属性 key → 技能名列表（标准 DnD 18 技能）
  static const skillsByAbility = <String, List<String>>{
    'strength': ['athletics'],
    'dexterity': ['acrobatics', 'sleight_of_hand', 'stealth'],
    'intelligence': ['arcana', 'history', 'investigation', 'nature', 'religion'],
    'wisdom': [
      'animal_handling',
      'insight',
      'medicine',
      'perception',
      'survival',
    ],
    'charisma': ['deception', 'intimidation', 'performance', 'persuasion'],
  };

  /// 技能 key → 中文名
  static const skillLabels = <String, String>{
    'athletics': '运动',
    'acrobatics': '体操',
    'sleight_of_hand': '巧手',
    'stealth': '潜行',
    'arcana': '奥秘',
    'history': '历史',
    'investigation': '调查',
    'nature': '自然',
    'religion': '宗教',
    'animal_handling': '驯兽',
    'insight': '洞悉',
    'medicine': '医疗',
    'perception': '察觉',
    'survival': '生存',
    'deception': '欺瞒',
    'intimidation': '威吓',
    'performance': '表演',
    'persuasion': '说服',
  };

  /// 获取某项属性的调整值（按 key）
  int abilityModifier(String ability) {
    switch (ability.toLowerCase()) {
      case 'strength':
        return strMod;
      case 'dexterity':
        return dexMod;
      case 'constitution':
        return conMod;
      case 'intelligence':
        return intMod;
      case 'wisdom':
        return wisMod;
      case 'charisma':
        return chaMod;
      default:
        return 0;
    }
  }

  /// 技能检定加值 = 属性调整 + （熟练则加熟练加值）
  int skillBonus(String ability, String skill) {
    final base = abilityModifier(ability);
    if (skilledSkills.contains(skill)) {
      return base + proficiencyBonus;
    }
    return base;
  }

  /// 用 4d6 取高 3 生成随机属性（返回 6 维属性 key→值 映射）
  static Map<String, int> generateRandomAbilities() {
    final result = <String, int>{};
    for (final ability in abilityLabels.keys) {
      final rolls = List.generate(4, (_) => Dice.roll(6))..sort();
      final total = rolls.sublist(1).fold(0, (a, b) => a + b);
      result[ability] = total;
    }
    return result;
  }

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'campaign_id': campaignId,
    'name': name,
    'race': race,
    'char_class': charClass,
    'level': level,
    'str': str,
    'dex': dex,
    'con': con,
    'intl': intl,
    'wis': wis,
    'cha': cha,
    'max_hp': maxHp,
    'current_hp': currentHp,
    'armor_bonus': armorBonus,
    'skilled_skills': jsonEncode(skilledSkills.toList()),
    'inventory': jsonEncode(inventory),
    'background': background,
    'is_player': isPlayer ? 1 : 0,
  };

  factory CharacterSheet.fromMap(Map<String, dynamic> map) {
    List<String> parseList(String raw) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        return decoded.map((e) => e.toString()).toList();
      } catch (_) {
        return <String>[];
      }
    }

    return CharacterSheet(
      id: map['id'] as int?,
      campaignId: map['campaign_id'] as int? ?? 0,
      name: map['name'] as String? ?? '',
      race: map['race'] as String? ?? '',
      charClass: map['char_class'] as String? ?? '',
      level: map['level'] as int? ?? 1,
      str: map['str'] as int? ?? 10,
      dex: map['dex'] as int? ?? 10,
      con: map['con'] as int? ?? 10,
      intl: map['intl'] as int? ?? 10,
      wis: map['wis'] as int? ?? 10,
      cha: map['cha'] as int? ?? 10,
      maxHp: map['max_hp'] as int? ?? 10,
      currentHp: map['current_hp'] as int? ?? 10,
      armorBonus: map['armor_bonus'] as int? ?? 0,
      skilledSkills: parseList(map['skilled_skills'] as String? ?? '[]').toSet(),
      inventory: parseList(map['inventory'] as String? ?? '[]'),
      background: map['background'] as String? ?? '',
      isPlayer: (map['is_player'] as int?) == 1,
    );
  }
}
