/// 战斗场景 AI 提示词服务
class BattleAiService {
  /// 构建战斗场景生成的 system prompt
  /// [customPrompt] 可传入用户自定义的系统提示，为空时使用默认提示
  static String buildSystemPrompt({String customPrompt = ''}) {
    if (customPrompt.trim().isNotEmpty) return customPrompt;

    return '你是一位专业的战斗场景描写作家。请根据用户提供的战斗要素（双方人物技能、战斗场景氛围、战斗结果），'
        '生成一段精彩具体的战斗场景描写。\n\n'
        '要求：\n'
        '1. 紧扣用户提供的要素，不要偏离设定\n'
        '2. 描写要生动具体，包含动作、环境、心理等细节\n'
        '3. 合理运用打斗过程的起承转合\n'
        '4. 战斗结果必须与用户指定的结果一致\n'
        '5. 用中文创作，使用纯文本格式\n'
        '6. 篇幅在 1000-3000 字之间';
  }

  /// 构建用户消息
  static String buildUserMessage({
    required String skills,
    required String scene,
    required String result,
  }) {
    final parts = <String>[];
    if (skills.trim().isNotEmpty) {
      parts.add('【双方人物技能】$skills');
    }
    if (scene.trim().isNotEmpty) {
      parts.add('【战斗场景】$scene');
    }
    if (result.trim().isNotEmpty) {
      parts.add('【战斗结果】$result');
    }
    return parts.join('\n\n');
  }
}
