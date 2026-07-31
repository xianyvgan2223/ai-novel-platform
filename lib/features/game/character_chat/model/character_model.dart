// lib/game/character_chat/model/character_model.dart
// 角色卡模型 — 仿 SillyTavern 角色卡结构

class CharacterModel {
  /// 角色名称
  final String name;

  /// 角色描述（外貌、身份等）
  final String description;

  /// 性格特征
  final String personality;

  /// 场景设定
  final String scenario;

  /// 初次见面开场白
  final String firstMes;

  /// 示例对话（可选），用于few-shot
  final String? mesExample;

  /// 额外系统指令
  final String? systemPrompt;

  /// 角色标签，用于搜索筛选
  final List<String> tags;

  const CharacterModel({
    required this.name,
    required this.description,
    this.personality = '',
    this.scenario = '',
    required this.firstMes,
    this.mesExample,
    this.systemPrompt,
    this.tags = const [],
  });

  /// 构建 system prompt（类似 SillyTavern 的 context 模板）
  String buildSystemPrompt() {
    final parts = <String>[];
    if (systemPrompt != null && systemPrompt!.isNotEmpty) {
      parts.add(systemPrompt!);
    }
    if (description.isNotEmpty) {
      parts.add(description);
    }
    if (personality.isNotEmpty) {
      parts.add(personality);
    }
    if (scenario.isNotEmpty) {
      parts.add(scenario);
    }
    if (mesExample != null && mesExample!.isNotEmpty) {
      parts.add(mesExample!);
    }
    return parts.join('\n\n');
  }
}
