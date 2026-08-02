import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import 'package:deepseekapp/core/config/user_setting_service.dart';
import '../../shared/domain/outline_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/character_profile.dart';
import '../../shared/data/outline_db_helper.dart';

/// 章节写作工具：按需查询人物档案。
/// 章节生成时不注入全部人物，主角直接注入；模型遇到其他人物时调用本工具获取其档案。
const List<Map<String, dynamic>> characterLookupTools = [
  {
    'type': 'function',
    'function': {
      'name': 'get_character_profiles',
      'description':
          '查询一个或多个人物的人物档案（外貌/身份/能力/性格）。当剧情中涉及主角以外的人物、'
          '或需要确认某个人物的设定细节时调用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'names': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '要查询的人物姓名或关键词列表',
          },
        },
        'required': ['names'],
      },
    },
  },
];

/// 章节写作 — 提示词模板
class ChapterWritePromptTemplate {
  /// 构建章节写作提示词
  ///
  /// [outlineExcerpt] 当前事件附近的大纲片段（避免整篇注入）
  /// [nextEvents] 当前事件之后的若干事件（含下个大事件），强化衔接
  /// [isLastOfMajor] 当前事件是否为所属大事件的最后一个事件，
  ///                  为 true 时追加「禁止提前完结」约束
  /// [prevEnding] 上一章小结（AI 提炼的整章小结，缺失时回退正文末尾片段）
  /// [storyState] 剧情状态账本（开启后随章节累积）
  /// [characters] 直接注入的人物档案（主角等关键人物）；其他人物由模型调用工具按需查询
  /// [foreshadows] 一键生成时的伏笔清单
  /// [gapCount] 当前事件之前未完成的事件数量（乱序提示）
  static String buildWritePrompt({
    required OutlineRecord outline,
    required String outlineExcerpt,
    required OutlineChapter ch,
    required String prevContent,
    OutlineChapter? parentMajor,
    String prevEventTitle = '',
    List<OutlineChapter> nextEvents = const [],
    bool isLastOfMajor = false,
    String prevEnding = '',
    String storyState = '',
    String characters = '',
    String foreshadows = '',
    int gapCount = 0,
  }) {
    final isMinor = ch.eventType == 'minor';
    final isMajor = ch.eventType == 'major';
    final parentSection = parentMajor != null && isMinor
        ? '\n【所属大事件】${parentMajor.eventTitle}\n${parentMajor.eventSummary}'
        : '';
    final prevSection = prevEventTitle.isEmpty ? '' : '\n【前一事件】$prevEventTitle';
    final nextSection = nextEvents.isEmpty
        ? ''
        : '\n【后续事件】\n${nextEvents.map((e) => '${e.eventType == 'major' ? "【大事件】" : "【小事件】"}${e.eventTitle}：${e.eventSummary.isEmpty ? "（无概要）" : e.eventSummary}').join('\n')}';
    final lastOfMajorHint = isLastOfMajor
        ? '；当前事件是所属大事件的最后一个事件，结尾必须为后续事件留出衔接（场景过渡、伏笔暗示或冲突升级），严禁在此处收尾或完结整个故事'
        : '';
    // 大事件写「阶段总结/过渡」章节，与其下小事件的详写章节区分，避免内容重叠
    final roleInstruction = isMajor
        ? '''- 本章是「阶段总结/过渡」章节：概括本阶段（当前大事件覆盖的范围）的进展、核心冲突与人物变化，承上启下
- 不要展开小事件的具体情节细节（其下小事件将单独成章详写），避免与后续章节内容重复
- 字数 1500-2500 字'''
        : '''- 以文学性强的叙述方式展开，包含场景描写、对话、心理活动
- 字数 2000-3000 字''';
    final prevEndingSection = prevEnding.isEmpty
        ? ''
        : '\n\n【上一章小结】\n$prevEnding';
    final storyStateSection = storyState.trim().isEmpty
        ? ''
        : '\n\n【全局剧情状态】\n${storyState.trim()}';
    final charactersSection = characters.trim().isEmpty
        ? ''
        : '\n\n【人物档案】\n${characters.trim()}';
    final foreshadowsSection = foreshadows.trim().isEmpty
        ? ''
        : '\n\n【伏笔清单】\n${foreshadows.trim()}';
    final gapWarning = gapCount > 0
        ? '\n- ⚠️ 注意：有 $gapCount 个前序事件尚未生成，上文可能不连续，请以【前文内容】与【上一章小结】中已有的内容为准，不要自行脑补缺失情节'
        : '';
    final charactersRule = characters.trim().isEmpty
        ? ''
        : '\n- 人物行为、言谈必须符合【人物档案】中设定的性格与能力，禁止擅自改变角色性格';
    return '''
你是一位小说作家。请根据以下大纲设定，完整写出指定事件的详细章节内容。

【小说设定】
类型：${outline.genre}
主题：${outline.theme}
主角：${outline.protagonist}
世界观：${outline.worldview}

【大纲结构（所属大事件部分）】
$outlineExcerpt

【当前事件】${ch.eventTitle}
【事件概要】${ch.eventSummary}
$parentSection
$prevSection
$nextSection

【前文内容】$prevContent$prevEndingSection$storyStateSection$charactersSection$foreshadowsSection

要求：
- 本章开头必须承接【上一章小结】中的场景、时间与人物状态，禁止突兀跳转；如需切换时间/地点，先用一小段过渡衔接
- 本章内容必须严格围绕【当前事件】与【事件概要】展开，禁止偏离大纲或编造大纲中不存在的情节
$roleInstruction
- 结尾自然衔接【后续事件】中的下一个事件（若存在）$lastOfMajorHint
- 若当前事件涉及【伏笔清单】中的伏笔，按其计划埋设或回收；清单未涉及的不要强行引入
- 角色状态、位置与悬念需与【全局剧情状态】保持连续一致$charactersRule
- 剧情中涉及主角以外的其他人物时，先调用 get_character_profiles 工具查询其人物档案，再结合档案写作；未查询到的人物不要凭空设定其外貌、能力或性格$gapWarning
- 只写当前事件的内容，不要超出范围
- 直接输出正文，不要添加注释说明
''';
  }
}

/// 章节写作服务层
/// 职责：加载配置、调用流式 API。
class ChapterWriteService {
  final ApiService _apiService;

  ChapterWriteService({ApiService? apiService})
    : _apiService = apiService ?? ApiService();

  /// 加载全局设置（API Key 等）和大纲专属设置
  Future<({String apiKey, OutlineSetting outlineSetting})>
  loadSettings() async {
    final global = await UserSettingService.getSettings();
    OutlineSetting outlineSetting = const OutlineSetting();
    try {
      final row = await OutlineDbHelper().getSettings();
      if (row != null) outlineSetting = OutlineSetting.fromMap(row);
    } catch (_) {}
    return (apiKey: global.apiKey, outlineSetting: outlineSetting);
  }

  /// 调用流式章节生成 API
  Future<void> streamWrite({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
    required void Function(Map<String, dynamic> chunk) onChunk,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    await _apiService.streamChat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: messages,
      cancelToken: cancelToken,
      tools: tools,
      onChunk: onChunk,
      onDone: onDone,
      onError: onError,
    );
  }

  /// 剧情状态账本提炼 — 非流式轻量调用（JSON 结构化输出）。
  ///
  /// 根据前序状态 + 当前人物档案 + 本章正文，输出：
  /// - story_state：剧情状态（角色处境/时间地点/伏笔/悬念/冲突）
  /// - characters：人物档案（姓名/描述/能力），**不含性格**——性格仅由用户维护，
  ///   模型不输出该字段，控制器在代码层按姓名回填保留。
  /// 返回 JSON 字符串，解析失败由调用方兜底。
  Future<String> extractStoryState({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String prevState,
    required List<CharacterProfile> characters,
    required String eventTitle,
    required String eventSummary,
    required String chapterContent,
  }) async {
    final characterText = characters.isEmpty
        ? '（暂无）'
        : characters
              .map(
                (c) =>
                    '· ${c.name}\n  描述：${c.description}\n  能力：${c.abilities}',
              )
              .join('\n');
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: {
        ...apiParams,
        'response_format': {'type': 'json_object'},
      },
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说剧情状态与人物档案提炼助手。根据前序剧情状态、当前人物档案与本章正文，'
              '输出更新后的**最新剧情状态**与**人物档案**，以严格的 JSON 格式输出，不要输出 JSON 以外的任何文字。\n'
              '剧情状态需覆盖：1) 各主要角色当前处境与变化 2) 当前时间与地点 3) 已埋设尚未回收的伏笔 '
              '4) 尚未解决的悬念 5) 未解决的冲突。\n'
              '人物档案：每位角色给出 name（姓名）、description（外貌/身份/背景/现状描述）、'
              'abilities（能力，含本章新增或变化的能力）。\n'
              '性格规则：当前人物档案中**已存在**的人物，禁止输出 personality 字段，'
              '禁止修改或推断其性格（性格由用户维护）；对于当前人物档案中**未出现的新人物**，'
              '可依据正文推断其性格并填入 personality 字段（仅此首次提炼，之后由用户维护）。\n'
              '输出格式：{"story_state": "剧情状态纯文本", "characters": [{"name": "...", "description": "...", "abilities": "...", "personality": "..."}]}',
        },
        {
          'role': 'user',
          'content':
              '【前序剧情状态】\n${prevState.isEmpty ? '（暂无）' : prevState}\n\n'
              '【当前人物档案】\n$characterText\n\n'
              '【本章事件】$eventTitle\n'
              '【本章概要】$eventSummary\n\n'
              '【本章正文】\n$chapterContent',
        },
      ],
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    final content = msg?['content'] as String? ?? '';
    return content.trim();
  }

  /// 主角人物档案提炼 — 非流式轻量调用（JSON 结构化输出）。
  /// 从「主角完整人设 + 大纲内容」提炼并**补全优化**主角描述（缺失部分结合大纲补全），
  /// 性格留空由用户维护。
  Future<String> extractProtagonist({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String protagonistSetting,
    required String outlineContent,
  }) async {
    final concept = outlineContent.length > 1200
        ? outlineContent.substring(0, 1200)
        : outlineContent;
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: {
        ...apiParams,
        'response_format': {'type': 'json_object'},
      },
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说人物档案提炼助手。请根据主角完整人设与大纲内容，提炼并**补全优化**主角的人物档案，'
              '输出 JSON。\n'
              'name：主角姓名；\n'
              'description：主角完整描述（外貌/身份/背景/当前处境），若人设中描述缺失或不完整，'
              '结合大纲内容合理补全优化；\n'
              'abilities：主角能力与特长（含成长潜力）。\n'
              '不要输出性格字段，性格由用户维护；不要输出 JSON 以外的任何文字。\n'
              '输出格式：{"protagonist": {"name": "...", "description": "...", "abilities": "..."}}',
        },
        {
          'role': 'user',
          'content':
              '【主角完整人设】\n$protagonistSetting\n\n'
              '【大纲内容（供参考补全描述）】\n${concept.isEmpty ? '（无）' : concept}',
        },
      ],
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    final content = msg?['content'] as String? ?? '';
    return content.trim();
  }

  /// 整章提炼 — 非流式轻量调用。
  /// 把一整章压缩为简明小结（保留核心进展与结尾状态），供下一章开头承接。
  Future<String> summarizeChapter({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String eventTitle,
    required String eventSummary,
    required String chapterContent,
  }) async {
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说章节提炼助手。请把给定的章节正文压缩为一份简明小结（200字以内），'
              '保留：本章核心进展、结尾处的场景/时间/人物状态、结尾抛出的悬念或伏笔。'
              '只输出小结本身，纯文本，不要任何多余说明。',
        },
        {
          'role': 'user',
          'content':
              '【本章事件】$eventTitle\n'
              '【本章概要】$eventSummary\n\n'
              '【本章正文】\n$chapterContent',
        },
      ],
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    final content = msg?['content'] as String? ?? '';
    return content.trim();
  }
}
