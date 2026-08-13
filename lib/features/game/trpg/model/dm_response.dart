// lib/game/trpg/model/dm_response.dart
// AI 主持人（DM）的结构化输出模型

/// 一次判定请求（DM 要求玩家进行技能/属性检定）
class CheckInfo {
  final String type; // 属性 key，如 dexterity
  final String? skill; // 技能 key，可为空
  final int dc; // 难度等级
  final String description; // 判定说明

  const CheckInfo({
    required this.type,
    this.skill,
    required this.dc,
    this.description = '',
  });
}

/// 状态变更（DM 返回，应用到游戏状态）
class StateChanges {
  final int hpDelta;
  final List<String> addFlags;
  final List<String> addItems;

  const StateChanges({
    this.hpDelta = 0,
    this.addFlags = const [],
    this.addItems = const [],
  });

  bool get isEmpty => hpDelta == 0 && addFlags.isEmpty && addItems.isEmpty;
}

/// DM 一轮完整回复
class DmResponse {
  final String narration;
  final String npcDialogue;
  final bool needCheck;
  final CheckInfo? check;
  final StateChanges stateChanges;
  final String sceneUpdate;

  const DmResponse({
    required this.narration,
    this.npcDialogue = '',
    this.needCheck = false,
    this.check,
    this.stateChanges = const StateChanges(),
    this.sceneUpdate = '',
  });

  /// 面向玩家展示的正文（含 NPC 对话）
  String get displayText {
    if (npcDialogue.isNotEmpty) {
      return '$narration\n\n$npcDialogue';
    }
    return narration;
  }
}
