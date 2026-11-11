// 小说灵感 — AI 提示词与流式调用
//
// 推演内容严格按作者本轮指令输出：作者要正文就写正文，要大纲 / 分析 /
// 方案 / 其它形式就按相应形式输出，不再强制写成小说正文。

import 'package:dio/dio.dart';
import '../../../../core/config/user_setting_service.dart';
import '../../../../core/network/api_service.dart';
import '../domain/inspiration_models.dart';
import '../data/inspiration_db_helper.dart';

class NovelInspirationPromptTemplate {
  /// 默认系统提示词（设置页把它作为「留空时的回填值」）
  static const String defaultSystemPrompt =
      '你是一位中文小说作家，正在和作者一起推演小说剧情。'
      '请严格按照作者本轮指令的要求输出。';

  /// 输出规则：每次生成都追加在系统提示词之后（不限定输出形式）
  static const String _writingRules =
      '【最高优先级】严格按照作者本轮指令的要求输出：作者要求正文就写正文；'
      '要求大纲、分析、方案、条目、对话或其它形式，就按相应形式输出。'
      '不要自行添加作者没有要求的内容。\n'
      '内容要求：\n'
      '- 承接【故事前文】最后的结果，保持人物、时间、地点、伤势与情绪连续（作者另有要求时以作者要求为准）；\n'
      '- 遵守【世界观】【主题】；人物言行符合【人物卡】；\n'
      '- 若给出【大纲事件】，只在这些事件的范围内推进，不提前写后续事件、不改动既定剧情；\n'
      '- 除作者要求外，不要自行添加标题、章节编号或解释说明。';

  /// 拼系统提示词：用户的设置（为空用默认）+ 本功能世界观 / 主题 / 人物卡 / 大纲事件。
  static String buildSystemPrompt({
    required InspirationSettings settings,
    String worldView = '',
    String theme = '',
    List<InspirationOutlineEvent> events = const [],
    List<InspirationCharacterCard> cards = const [],
  }) {
    final configured = settings.systemPrompt.trim();
    final base = configured.isEmpty ? defaultSystemPrompt : configured;
    final buf = StringBuffer()
      ..writeln(base)
      ..writeln()
      ..writeln(_writingRules);

    if (worldView.trim().isNotEmpty || theme.trim().isNotEmpty) {
      buf.writeln('\n【本作设定】');
      if (worldView.trim().isNotEmpty) {
        buf.writeln('世界观：${worldView.trim()}');
      }
      if (theme.trim().isNotEmpty) {
        buf.writeln('主题：${theme.trim()}');
      }
    }

    final activeCards = cards
        .where((c) => c.inject && c.hasContent)
        .toList(growable: false);
    if (activeCards.isNotEmpty) {
      buf.writeln('\n【人物卡】');
      for (final c in activeCards) {
        buf.writeln('· ${c.name.trim()}');
        if (c.description.trim().isNotEmpty) {
          buf.writeln('  描述：${c.description.trim()}');
        }
        if (c.personality.trim().isNotEmpty) {
          buf.writeln('  性格：${c.personality.trim()}');
        }
        if (c.experiences.trim().isNotEmpty) {
          buf.writeln('  经历过的事件：${c.experiences.trim()}');
        }
        if (c.skills.trim().isNotEmpty) {
          buf.writeln('  技能：${c.skills.trim()}');
        }
        if (c.status.trim().isNotEmpty) {
          buf.writeln('  当前状态：${c.status.trim()}');
        }
      }
    }

    if (events.isNotEmpty) {
      buf.writeln('\n【大纲事件（只允许写这些事件范围内的剧情，不要提前写后续事件）】');
      for (final e in events) {
        final label = e.isMajor ? '大事件' : '小事件';
        buf.writeln('· $label《${e.title.trim()}》');
        if (e.summary.trim().isNotEmpty) {
          buf.writeln('  ${e.summary.trim()}');
        }
      }
    }
    return buf.toString().trim();
  }

  /// 对话模式的系统提示：单 AI 交流，不续写正文；注入对话历史 + 推演结果。
  static String buildChatSystemPrompt({
    required InspirationSettings settings,
    String worldView = '',
    String theme = '',
    List<InspirationOutlineEvent> events = const [],
    List<InspirationCharacterCard> cards = const [],
    List<String> deductionResults = const [],
  }) {
    final buf = StringBuffer()
      ..writeln('你是作者的小说创作助手，正在和作者讨论这部小说。')
      ..writeln('你的任务是回答问题、讨论剧情 / 人物 / 设定、给建议；除非作者明确要求，不要续写正文。')
      ..writeln('回答要简洁、具体，直接回应作者的问题。')
      ..writeln('不要编造与已确立的设定、已采用的推演结果相矛盾的内容。');
    if (worldView.trim().isNotEmpty || theme.trim().isNotEmpty) {
      buf.writeln('\n【本作设定】');
      if (worldView.trim().isNotEmpty) {
        buf.writeln('世界观：${worldView.trim()}');
      }
      if (theme.trim().isNotEmpty) {
        buf.writeln('主题：${theme.trim()}');
      }
    }
    final activeCards = cards
        .where((c) => c.inject && c.hasContent)
        .toList(growable: false);
    if (activeCards.isNotEmpty) {
      buf.writeln('\n【人物卡】');
      for (final c in activeCards) {
        buf.writeln('· ${c.name.trim()}');
        if (c.description.trim().isNotEmpty) {
          buf.writeln('  描述：${c.description.trim()}');
        }
        if (c.personality.trim().isNotEmpty) {
          buf.writeln('  性格：${c.personality.trim()}');
        }
        if (c.status.trim().isNotEmpty) {
          buf.writeln('  当前状态：${c.status.trim()}');
        }
      }
    }
    if (events.isNotEmpty) {
      buf.writeln('\n【已导入的大纲事件】');
      for (final e in events) {
        buf.writeln('· ${e.isMajor ? '大事件' : '小事件'}《${e.title.trim()}》');
        if (e.summary.trim().isNotEmpty) {
          buf.writeln('  ${e.summary.trim()}');
        }
      }
    }
    if (deductionResults.isNotEmpty) {
      buf.writeln('\n【已采用的推演结果（只作为故事事实参考，不要续写）】');
      for (var i = 0; i < deductionResults.length; i++) {
        buf.writeln('· 第 ${i + 1} 轮：${deductionResults[i].trim()}');
      }
    }
    return buf.toString().trim();
  }

  /// 对话模式请求消息：对话历史 + 当前输入（不包含推演模式的分支上下文）。
  static List<Map<String, dynamic>> buildChatMessages({
    required InspirationSettings settings,
    String worldView = '',
    String theme = '',
    List<InspirationOutlineEvent> events = const [],
    List<InspirationCharacterCard> cards = const [],
    List<String> deductionResults = const [],
    List<InspirationChatMessage> history = const [],
    required String userText,
  }) {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': buildChatSystemPrompt(
          settings: settings,
          worldView: worldView,
          theme: theme,
          events: events,
          cards: cards,
          deductionResults: deductionResults,
        ),
      },
    ];
    for (final m in history) {
      if (m.content.trim().isEmpty) continue;
      messages.add({
        'role': m.isUser ? 'user' : 'assistant',
        'content': m.content,
      });
    }
    messages.add({'role': 'user', 'content': userText});
    return messages;
  }

  /// 生成一次「并行推演」的请求消息。
  ///
  /// [history] 只放已经产出的**结果**（用户指令 + 被采用的正文），
  /// 未采用的推演不进入对话上下文。
  static List<Map<String, dynamic>> buildGenerateMessages({
    required InspirationSettings settings,
    String worldView = '',
    String theme = '',
    List<InspirationOutlineEvent> events = const [],
    List<InspirationCharacterCard> cards = const [],
    List<({String instruction, String result})> history = const [],
    required String instruction,
    required int variantIndex,
    required int variantCount,
  }) {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': buildSystemPrompt(
          settings: settings,
          worldView: worldView,
          theme: theme,
          events: events,
          cards: cards,
        ),
      },
    ];
    for (final h in history) {
      messages.add({'role': 'user', 'content': h.instruction});
      messages.add({'role': 'assistant', 'content': h.result});
    }
    final variantNote = variantCount > 1
        ? '\n\n（本次是第 $variantIndex 个候选推演，共 $variantCount 个；'
              '在合理范围内选择一个与其它候选不同的思路或侧重点，但仍要完整满足作者本轮指令的要求。）'
        : '';
    messages.add({'role': 'user', 'content': '$instruction$variantNote'});
    return messages;
  }

  /// 把同一轮里选中的多个推演结果合并成一个结果（格式按用户指令）。
  ///
  /// [mergeRequirement] 是用户附加的合并要求（可空）。
  static List<Map<String, dynamic>> buildMergeMessages({
    required InspirationSettings settings,
    String worldView = '',
    String theme = '',
    List<InspirationOutlineEvent> events = const [],
    List<InspirationCharacterCard> cards = const [],
    List<({String instruction, String result})> history = const [],
    required String instruction,
    required List<String> branches,
    String mergeRequirement = '',
  }) {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': buildSystemPrompt(
          settings: settings,
          worldView: worldView,
          theme: theme,
          events: events,
          cards: cards,
        ),
      },
    ];
    for (final h in history) {
      messages.add({'role': 'user', 'content': h.instruction});
      messages.add({'role': 'assistant', 'content': h.result});
    }
    final content = StringBuffer()
      ..writeln('请把下面 ${branches.length} 个推演结果合并成一个结果。')
      ..writeln('要求：')
      ..writeln('- 保留每个结果里最好的冲突、转折、场景与细节，去掉重复和矛盾；')
      ..writeln('- 合并后的人物、时间、地点、因果必须连贯；')
      ..writeln('- 只输出合并后的结果，格式与详略严格按照【用户本轮指令】的要求；')
      ..writeln('- 用户要求正文就写正文，要求大纲、分析、方案或其它形式就按相应形式输出；')
      ..writeln()
      ..writeln('【用户本轮指令】$instruction')
      ..writeln()
      ..writeln('【待合并的推演结果】');
    for (var i = 0; i < branches.length; i++) {
      content
        ..writeln('—— 推演 ${i + 1} ——')
        ..writeln(branches[i].trim())
        ..writeln();
    }
    final requirement = mergeRequirement.trim();
    if (requirement.isNotEmpty) {
      content
        ..writeln('【额外要求（优先遵守）】')
        ..writeln(requirement);
    }
    messages.add({'role': 'user', 'content': content.toString().trim()});
    return messages;
  }

  /// 对推演正文里选中段落做 AI 改写，只返回替换段落。
  static List<Map<String, dynamic>> buildSegmentMessages({
    required InspirationSettings settings,
    required String fullText,
    required String selectedText,
    required String instruction,
  }) {
    return [
      {
        'role': 'system',
        'content':
            '你是中文小说作家。只输出改写后的选中段落正文，不要解释、不要标题、'
            '不要编号、不要 Markdown 代码块。改写要贴合前后文。',
      },
      {
        'role': 'user',
        'content':
            '【完整正文（仅供理解上下文，不要重写整篇）】\n$fullText\n\n'
            '【需要改写的选中段落】\n$selectedText\n\n'
            '【改写要求】\n${instruction.trim().isEmpty ? '把选中段落改写得更完整、更有画面感，保持剧情不变。' : instruction.trim()}\n\n'
            '只输出改写后的选中段落。',
      },
    ];
  }

  /// 对话式段落改写：可多轮追加要求，每次只返回改写后的选中段落。
  static List<Map<String, dynamic>> buildSegmentChatMessages({
    required InspirationSettings settings,
    required String fullText,
    required String selectedText,
    List<({String instruction, String result})> turns = const [],
    required String instruction,
  }) {
    final base =
        '【完整正文（仅供理解上下文，不要重写整篇）】\n$fullText\n\n'
        '【需要改写的选中段落】\n$selectedText';
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '你是中文小说作家。只输出改写后的选中段落正文，不要解释、不要标题、'
            '不要编号、不要 Markdown 代码块。改写要贴合前后文。',
      },
    ];
    String effective(String text) =>
        text.trim().isEmpty ? '把选中段落改写得更完整、更有画面感，保持剧情不变。' : text.trim();
    if (turns.isEmpty) {
      messages.add({
        'role': 'user',
        'content': '$base\n\n【改写要求】\n${effective(instruction)}\n\n只输出改写后的选中段落。',
      });
      return messages;
    }
    messages.add({
      'role': 'user',
      'content':
          '$base\n\n【改写要求】\n${effective(turns.first.instruction)}\n\n只输出改写后的选中段落。',
    });
    for (var i = 0; i < turns.length; i++) {
      messages.add({'role': 'assistant', 'content': turns[i].result});
      if (i + 1 < turns.length) {
        messages.add({
          'role': 'user',
          'content':
              '【改写要求】\n${effective(turns[i + 1].instruction)}\n\n只输出改写后的选中段落。',
        });
      }
    }
    messages.add({
      'role': 'user',
      'content': '【改写要求】\n${effective(instruction)}\n\n只输出改写后的选中段落。',
    });
    return messages;
  }

  /// 根据本功能里选中注入的事件，生成某个角色「当前状态」。
  static List<Map<String, dynamic>> buildCardStatusMessages({
    String worldView = '',
    String theme = '',
    required InspirationCharacterCard card,
    List<InspirationOutlineEvent> events = const [],
  }) {
    final buf = StringBuffer()
      ..writeln('你是小说人物设定助手。请根据世界观、人物卡与已选大纲事件，')
      ..writeln('写出这个人物**当前的状态**（处境、目标、情绪、伤势/能力变化、与关键人物的关系）。')
      ..writeln('要求：只输出状态正文，80~150 字，不要解释、不要标题。')
      ..writeln();
    if (worldView.trim().isNotEmpty) {
      buf.writeln('【世界观】${worldView.trim()}');
    }
    if (theme.trim().isNotEmpty) {
      buf.writeln('【主题】${theme.trim()}');
    }
    buf
      ..writeln('【人物卡】')
      ..writeln('姓名：${card.name.trim()}');
    if (card.description.trim().isNotEmpty) {
      buf.writeln('描述：${card.description.trim()}');
    }
    if (card.personality.trim().isNotEmpty) {
      buf.writeln('性格：${card.personality.trim()}');
    }
    if (card.experiences.trim().isNotEmpty) {
      buf.writeln('经历过的事件：${card.experiences.trim()}');
    }
    if (card.skills.trim().isNotEmpty) {
      buf.writeln('技能：${card.skills.trim()}');
    }
    if (events.isNotEmpty) {
      buf.writeln('\n【已选大纲事件（只依据这些事件推演）】');
      for (final e in events) {
        buf.writeln('· ${e.title.trim()}：${e.summary.trim()}');
      }
    }
    return [
      {'role': 'system', 'content': '你是小说人物设定助手，只输出人物状态正文。'},
      {'role': 'user', 'content': buf.toString().trim()},
    ];
  }
}

/// 小说灵感服务层：加载设置、发起流式 / 非流式请求。
class NovelInspirationService {
  final ApiService _apiService;
  final InspirationDbHelper _db;

  NovelInspirationService({ApiService? apiService, InspirationDbHelper? db})
    : _apiService = apiService ?? ApiService(),
      _db = db ?? InspirationDbHelper();

  Future<({String apiKey, InspirationSettings settings})> loadSettings() async {
    final global = await UserSettingService.getSettings();
    InspirationSettings settings = const InspirationSettings();
    try {
      settings = await _db.getSettings();
    } catch (_) {}
    return (apiKey: global.apiKey, settings: settings);
  }

  Map<String, dynamic> buildApiParams(InspirationSettings settings) => {
    'model': settings.model,
    'temperature': settings.temperature,
    'max_tokens': settings.maxTokens,
    if (!settings.enableThinking) 'thinking': {'type': 'disabled'},
  };

  Future<void> stream({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
    required void Function(String content) onContent,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    await _apiService.streamChat(
      apiKey: apiKey,
      apiParams: {...apiParams, 'stream': true},
      messages: messages,
      cancelToken: cancelToken,
      onChunk: (chunk) {
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) return;
        final delta = choices[0]['delta'] as Map<String, dynamic>?;
        final content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) onContent(content);
      },
      onDone: onDone,
      onError: onError,
    );
  }

  Future<String> complete({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
  }) async {
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: messages,
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    return (msg?['content'] as String? ?? '').trim();
  }
}
