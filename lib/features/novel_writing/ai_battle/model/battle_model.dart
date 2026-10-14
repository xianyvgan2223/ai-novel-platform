/// 战斗场景模型
class BattleScene {
  final int? id;
  final String userInput; // 用户输入的完整描述
  final String aiResult; // AI 生成的战斗场景
  final String characterSkills; // 双方人物技能
  final String battleSceneDesc; // 战斗场景描述
  final String battleResult; // 战斗结果
  final BattleStatus status;
  final String createdAt;

  BattleScene({
    this.id,
    this.userInput = '',
    this.aiResult = '',
    this.characterSkills = '',
    this.battleSceneDesc = '',
    this.battleResult = '',
    this.status = BattleStatus.completed,
    String? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String();

  Map<String, dynamic> toMap() => {
    'user_input': userInput,
    'ai_result': aiResult,
    'character_skills': characterSkills,
    'battle_scene_desc': battleSceneDesc,
    'battle_result': battleResult,
    'status': status.name,
    'created_at': createdAt,
  };

  factory BattleScene.fromMap(Map<String, dynamic> map) => BattleScene(
    id: map['id'] as int?,
    userInput: map['user_input'] as String? ?? '',
    aiResult: map['ai_result'] as String? ?? '',
    characterSkills: map['character_skills'] as String? ?? '',
    battleSceneDesc: map['battle_scene_desc'] as String? ?? '',
    battleResult: map['battle_result'] as String? ?? '',
    status: BattleStatus.values.firstWhere(
      (s) => s.name == map['status'],
      orElse: () => BattleStatus.completed,
    ),
    createdAt: map['created_at'] as String?,
  );
}

/// 战斗状态
enum BattleStatus { draft, generating, completed, failed }

/// 战斗设置模型
class BattleSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String systemPrompt;

  const BattleSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-flash',
    this.systemPrompt = '',
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'system_prompt': systemPrompt,
  };

  factory BattleSetting.fromMap(Map<String, dynamic> map) => BattleSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-flash',
    systemPrompt: map['system_prompt'] as String? ?? '',
  );

  BattleSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? systemPrompt,
  }) => BattleSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
  );
}
