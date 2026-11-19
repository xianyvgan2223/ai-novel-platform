// lib/game/trpg/data/trpg_ai_service.dart
// AI 主持人（DM）服务 — 构建 DM 上下文并解析结构化回复

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import '../model/character_sheet.dart';
import '../model/dm_response.dart';

class TrpgAiService {
  final ApiService _apiService;

  TrpgAiService({ApiService? apiService})
    : _apiService = apiService ?? ApiService();

  /// 构建 DM system prompt（**只含每轮请求都相同的固定内容**：
  /// DM 定位 + 规则 + 输出格式）。
  ///
  /// 玩家角色卡 / 当前场景 / 剧情标记这些每轮会变的状态不放进 system，
  /// 改由 [buildStateBlock] 拼到本轮用户消息末尾 —— 否则 system 每轮都不同，
  /// system 之后的历史消息会全部失去前缀缓存。
  static String buildSystemPrompt() {
    return '''
你是一名经验丰富的 TRPG 主持人（DM），主持一场 DnD 风格的单人冒险。你负责描述场景、扮演 NPC、根据玩家行动与骰子判定结果推进剧情。你不替玩家做决定，也不直接决定骰子点数（点数由客户端本地掷出）。

【规则】
1. 用第二人称对玩家叙事，生动但克制。
2. 当玩家的行动结果不确定、需要考验角色能力时，不要自己脑补结果，而是返回 need_check=true，并在 check 中给出：type（六维属性之一，如 dexterity）、可选 skill（标准技能名）、dc（难度等级 5~25）。
3. 当玩家已给出骰子判定结果（消息里会带「[判定结果]」），你要据此叙述成功或失败，并给出对应的状态变更。
4. 战斗、伤害、道具得失等都要通过 state_changes 反馈。

【输出格式】
先不要输出，只在最后输出一段严格的 JSON（不要 markdown 包裹），字段如下：
{
  "narration": "旁白/结果叙事",
  "npc_dialogue": "NPC 说的话（没有则空字符串）",
  "need_check": false,
  "check": {"type": "dexterity", "skill": "sleight_of_hand", "dc": 15, "description": "说明这次判定"},
  "state_changes": {"hp_delta": 0, "add_flag": [], "add_item": []},
  "scene_update": "若剧情推进到新场景则填写，否则空字符串"
}
''';
  }

  /// 构建每轮变化的状态块：玩家角色卡 + 当前场景 + 剧情标记。
  /// 由调用方追加到本轮用户消息末尾（不放进 system，保证 system 前缀稳定）。
  static String buildStateBlock(
    CharacterSheet character, {
    String scene = '',
    Map<String, String> flags = const {},
  }) {
    final abilities = [
      '力量 ${character.str}(${_signed(character.strMod)})',
      '敏捷 ${character.dex}(${_signed(character.dexMod)})',
      '体质 ${character.con}(${_signed(character.conMod)})',
      '智力 ${character.intl}(${_signed(character.intMod)})',
      '感知 ${character.wis}(${_signed(character.wisMod)})',
      '魅力 ${character.cha}(${_signed(character.chaMod)})',
    ].join('，');

    final skills = character.skilledSkills.isEmpty
        ? '无'
        : character.skilledSkills
              .map((s) => CharacterSheet.skillLabels[s] ?? s)
              .join('、');

    final flagText = flags.isEmpty
        ? '（暂无）'
        : flags.entries.map((e) => '${e.key}: ${e.value}').join('；');

    return '''
【玩家角色卡】
- 姓名：${character.name}
- 种族/职业：${character.race} ${character.charClass}
- 等级：${character.level}（熟练加值 +${character.proficiencyBonus}）
- 属性（值/调整值）：$abilities
- 生命值：${character.currentHp}/${character.maxHp}
- 护甲等级 AC：${character.ac}
- 熟练技能：$skills
- 背包物品：${character.inventory.isEmpty ? '无' : character.inventory.join('、')}
- 背景：${character.background.isEmpty ? '无' : character.background}

【当前场景】
${scene.isEmpty ? '（待定，由你开局引入）' : scene}

【剧情标记（已发生的关键事件）】
$flagText''';
  }

  static String _signed(int v) => v >= 0 ? '+$v' : '$v';

  /// 生成一轮 DM 回复（非流式，返回结构化结果）
  Future<DmResponse> generate({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
  }) async {
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: messages,
      cancelToken: cancelToken,
    );
    final content = _extractContent(response);
    if (content.isEmpty) {
      throw Exception('AI 响应内容为空');
    }
    return parse(content);
  }

  /// 解析 DM 回复文本为结构化对象（含容错）
  static DmResponse parse(String text) {
    final jsonStr = _extractJson(text);
    if (jsonStr != null) {
      try {
        final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
        return DmResponse(
          narration: (parsed['narration'] as String?)?.trim() ?? '',
          npcDialogue: (parsed['npc_dialogue'] as String?)?.trim() ?? '',
          needCheck: parsed['need_check'] == true,
          check: _parseCheck(parsed['check']),
          stateChanges: _parseStateChanges(parsed['state_changes']),
          sceneUpdate: (parsed['scene_update'] as String?)?.trim() ?? '',
        );
      } catch (_) {}
    }
    // 解析失败时把全文当作叙事，避免卡死
    return DmResponse(narration: text.trim());
  }

  static CheckInfo? _parseCheck(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final dc = raw['dc'];
    return CheckInfo(
      type: (raw['type'] as String?) ?? 'strength',
      skill: raw['skill'] as String?,
      dc: dc is int ? dc : (int.tryParse('$dc') ?? 12),
      description: (raw['description'] as String?) ?? '',
    );
  }

  static StateChanges _parseStateChanges(dynamic raw) {
    if (raw is! Map<String, dynamic>) return const StateChanges();
    List<String> toList(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return const [];
    }

    final hp = raw['hp_delta'];
    return StateChanges(
      hpDelta: hp is int ? hp : (int.tryParse('$hp') ?? 0),
      addFlags: toList(raw['add_flag']),
      addItems: toList(raw['add_item']),
    );
  }

  static String _extractContent(Map<String, dynamic> response) {
    final choices = response['choices'] as List<dynamic>?;
    if (choices != null && choices.isNotEmpty) {
      final msg = choices[0]['message'] as Map<String, dynamic>?;
      if (msg != null) {
        return msg['content'] as String? ?? '';
      }
    }
    return '';
  }

  /// 从文本中提取 JSON（处理 AI 可能返回 markdown 包裹的情况）
  static String? _extractJson(String text) {
    final jsonBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final match = jsonBlock.firstMatch(text);
    if (match != null) return match.group(1);
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start != -1 && end != -1 && end > start) {
      return text.substring(start, end + 1);
    }
    return null;
  }
}
