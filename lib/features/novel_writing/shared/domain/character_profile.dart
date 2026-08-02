/// 人物档案（剧情状态账本中的角色条目）
///
/// 描述/能力可由 AI 在章节提炼时更新；
/// [personality]（性格）仅允许用户修改，AI 提炼时不会携带该字段，代码层也会按姓名回填保留。
/// [isProtagonist] 主角标记：主角档案直接注入章节提示词，其他人物由模型按需调用工具查询。
class CharacterProfile {
  final String name;
  final String description; // 人物描述：外貌/身份/背景/现状
  final String abilities; // 人物能力：天赋/技能/成长
  final String personality; // 性格：仅用户可改
  final bool isProtagonist; // 是否主角

  const CharacterProfile({
    this.name = '',
    this.description = '',
    this.abilities = '',
    this.personality = '',
    this.isProtagonist = false,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'abilities': abilities,
    'personality': personality,
    'is_protagonist': isProtagonist,
  };

  factory CharacterProfile.fromJson(Map<String, dynamic> m) => CharacterProfile(
    name: m['name'] as String? ?? '',
    description: m['description'] as String? ?? '',
    abilities: m['abilities'] as String? ?? '',
    personality: m['personality'] as String? ?? '',
    isProtagonist: m['is_protagonist'] == true || m['is_protagonist'] == 1,
  );
}
