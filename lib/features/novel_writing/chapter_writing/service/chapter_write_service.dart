import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import 'package:deepseekapp/core/config/user_setting_service.dart';
import '../../shared/domain/chapter_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/character_profile.dart';
import '../../shared/data/outline_db_helper.dart';
import '../../shared/outline_foreshadow_filter.dart';

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
  /// [minWords]/[maxWords] 单章字数范围（来自章节设置，默认 2000-3000）
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
    int minWords = 2000,
    int maxWords = 3000,
    bool enableCharacterLookup = true,
  }) {
    final isMinor = ch.eventType == 'minor';
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
    // 章节字数范围来自设置；最少字数大于最多字数时退化为按最少数约束
    final wordCountText = minWords <= maxWords
        ? (minWords == maxWords ? '字数 $minWords 字' : '字数 $minWords-$maxWords 字')
        : '字数 $minWords 字';
    // 仅小事件详写为章节正文；大事件是结构节点，不单独生成章节。
    // 明确限定文风：平实自然、克制修辞，避免模型堆砌比喻导致每章都像散文
    final roleInstruction = '''- 以自然流畅的叙述方式展开，包含场景描写、对话、心理活动
- 语言平实克制，贴近通俗小说文风；全篇比喻、排比等修辞手法不超过 1-2 处，禁止堆砌辞藻、空泛抒情
- 用具体的动作、环境细节和人物对话推进情节，不要用比喻或抽象修辞来渲染气氛
- $wordCountText''';
    final prevEndingSection = prevEnding.isEmpty
        ? ''
        : '\n\n【上一个小事件小结】\n$prevEnding';
    final storyStateSection = storyState.trim().isEmpty
        ? ''
        : '\n\n【全局剧情状态】\n${storyState.trim()}';
    final charactersSection = characters.trim().isEmpty
        ? ''
        : '\n\n【人物档案】\n${characters.trim()}';
    // 已回收 / 已实现的伏笔不再注入（旧记录里的清单可能是历史纯文本）
    final activeForeshadows = filterResolvedForeshadowText(foreshadows);
    final foreshadowsSection = activeForeshadows.isEmpty
        ? ''
        : '\n\n【伏笔清单】\n$activeForeshadows';
    final charactersRule = characters.trim().isEmpty
        ? ''
        : '\n- 人物行为、言谈必须符合【人物档案】中设定的性格与能力，禁止擅自改变角色性格';
    // 存在可查询的配角档案时提示模型调用工具；只有主角档案时禁用工具，
    // 避免模型为查询并不存在的配角而多轮调用工具导致正文生成失败
    final characterLookupRule = enableCharacterLookup
        ? '- 剧情中涉及主角以外的其他人物时，先调用 get_character_profiles 工具查询其人物档案，再结合档案写作；未查询到的人物不要凭空设定其外貌、能力或性格'
        : '- 剧情中涉及主角以外的人物时，其外貌、能力与性格等设定细节尽量从简或保持模糊，不要展开设定';
    return '''
你是一位小说作家。请根据以下大纲设定，完整写出指定事件的详细正文。

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
- 本小事件开头必须承接【上一个小事件小结】中的场景、时间与人物状态，禁止突兀跳转；如需切换时间/地点，先用一小段过渡衔接
- 本小事件内容必须严格围绕【当前事件】与【事件概要】展开，禁止偏离大纲或编造大纲中不存在的情节
$roleInstruction
- 结尾自然衔接【后续事件】中的下一个事件（若存在）$lastOfMajorHint
- 若当前事件涉及【伏笔清单】中的伏笔，按其计划埋设或回收；清单未涉及的不要强行引入
- 角色状态、位置与悬念需与【全局剧情状态】保持连续一致$charactersRule
$characterLookupRule
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

  /// 加载全局设置（API Key 等）和章节专属设置
  Future<({String apiKey, ChapterSetting chapterSetting})>
  loadSettings() async {
    final global = await UserSettingService.getSettings();
    ChapterSetting chapterSetting = const ChapterSetting();
    try {
      final row = await OutlineDbHelper().getChapterSettings();
      if (row != null) chapterSetting = ChapterSetting.fromMap(row);
    } catch (_) {}
    return (apiKey: global.apiKey, chapterSetting: chapterSetting);
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

  /// 剧情状态账本提炼 — 构建请求消息（流式调用由控制器执行，过程可实时查看）。
  ///
  /// 根据前序状态 + 当前人物档案 + 本章正文，输出：
  /// - story_state：剧情状态（角色处境/时间地点/伏笔/悬念/冲突）
  /// - characters：人物档案（姓名/描述/能力），**不含性格**——性格仅由用户维护，
  ///   模型不输出该字段，控制器在代码层按姓名回填保留。
  /// 返回 JSON 字符串，解析失败由调用方兜底。
  List<Map<String, dynamic>> buildStoryStateMessages({
    required String prevState,
    required List<CharacterProfile> characters,
    required String eventTitle,
    required String eventSummary,
    required String chapterContent,
  }) {
    final characterText = characters.isEmpty
        ? '（暂无）'
        : characters
              .map(
                (c) =>
                    '· ${c.name}\n  描述：${c.description}\n  能力：${c.abilities}',
              )
              .join('\n');
    return [
      {
        'role': 'system',
        'content':
            '你是小说剧情状态与人物档案提炼助手。根据前序剧情状态、当前人物档案与本章正文，'
            '输出更新后的**最新剧情状态**与**人物档案**，以严格的 JSON 格式输出，不要输出 JSON 以外的任何文字。\n'
            '剧情状态需覆盖并按以下五个分区输出，每个分区占一行（标题+内容），分区之间空一行：\n'
            '【角色处境】各主要角色当前处境与变化\n'
            '【时间地点】当前时间与地点\n'
            '【伏笔】已埋设尚未回收的伏笔\n'
            '【悬念】尚未解决的悬念\n'
            '【冲突】未解决的冲突\n'
            '某分区没有内容时写「无」，不要合并、省略或改写分区标题。\n'
            '人物档案：每位角色给出 name（姓名）、description（外貌/身份/背景/现状描述）、'
            'abilities（能力，含本小事件新增或变化的能力）。\n'
            '档案提炼规则：description 与 abilities 只提炼人物自身的**稳定设定**'
            '（外貌/身份/背景/能力名称、类型、特点与强弱定位），'
            '禁止写入具体情节片段、战例或能力施展场景举例'
            '（如"凭借一根树枝点杀丧尸"这类具体事例），避免后续小事件生成时照搬这些例子。\n'
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
            '【本小事件】$eventTitle\n'
            '【本小事件概要】$eventSummary\n\n'
            '【本小事件正文】\n$chapterContent',
      },
    ];
  }

  /// 非流式对话（兜底）— 流式不可用/失败时回退。返回 message.content，失败返回空串。
  Future<String> chatOnce({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
  }) async {
    try {
      final response = await _apiService.chat(
        apiKey: apiKey,
        apiParams: apiParams,
        messages: messages,
      );
      final choices = response['choices'] as List?;
      if (choices == null || choices.isEmpty) return '';
      final msg = choices[0]['message'] as Map<String, dynamic>?;
      return (msg?['content'] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 主角人物档案提炼 — 构建请求消息（流式调用由控制器执行，过程可实时查看）。
  /// 从「主角完整人设 + 大纲内容」提炼并**补全优化**主角描述（缺失部分结合大纲补全），
  /// 若人设/大纲中明确提到性格则一并提炼录入（仅首次种入，之后由用户维护）。
  /// 提炼完成后由控制器再执行一轮 AI 审查（见 [buildProtagonistReviewMessages]）。
  List<Map<String, dynamic>> buildProtagonistMessages({
    required String protagonistSetting,
    required String outlineContent,
  }) {
    final concept = outlineContent.length > 3000
        ? outlineContent.substring(0, 3000)
        : outlineContent;
    return [
      {
        'role': 'system',
        'content':
            '你是小说人物档案提炼助手。请根据主角完整人设与大纲内容，提炼并**补全优化**主角的人物档案，'
            '输出 JSON。\n'
            'name：主角姓名；\n'
            'description：主角完整描述（外貌/身份/背景/当前处境），若人设中描述缺失或不完整，'
            '结合大纲内容合理补全优化；只写稳定的设定，不要写入具体情节或战例\n'
            'abilities：主角能力与特长（含成长潜力），只描述能力本身的名称、类型、特点与强弱定位，'
            '**禁止**举例能力的施展场景或战绩（如"凭借一根树枝点杀丧尸"这类具体事例），'
            '避免小事件生成时照搬这些例子；\n'
            'personality：主角性格。若人设或大纲中明确描述了性格（如性格、脾气、处世方式等），'
            '如实提炼录入；完全没有提及则输出空字符串，不要自行编造。\n'
            '不要输出 JSON 以外的任何文字。\n'
            '输出格式：{"protagonist": {"name": "...", "description": "...", "abilities": "...", "personality": "..."}}',
      },
      {
        'role': 'user',
        'content':
            '【主角完整人设】\n$protagonistSetting\n\n'
            '【大纲内容（供参考补全描述）】\n${concept.isEmpty ? '（无）' : concept}',
      },
    ];
  }

  /// 主角人物档案 AI 审查 — 构建请求消息（流式调用由控制器执行）。
  /// 在提炼完成后执行：依据提炼约束复核档案是否合理，将不合理处修正。
  /// 输出格式：【审查意见】+【修正后档案】（JSON，结构同提炼结果）。
  List<Map<String, dynamic>> buildProtagonistReviewMessages({
    required String protagonistSetting,
    required String profileJson,
  }) {
    return [
      {
        'role': 'system',
        'content':
            '你是小说人物档案审校助手。请审校给定的主角人物档案 JSON，检查并修正不合理之处。\n'
            '审校规则（必须遵循提炼约束）：\n'
            '- description 只描述人物稳定设定（外貌/身份/背景/当前处境），不得写入具体情节片段或战例\n'
            '- abilities 只描述能力本身的名称、类型、特点与强弱定位，'
            '**禁止**能力施展场景举例或战绩（如"凭借一根树枝点杀丧尸"这类具体事例），'
            '避免后续小事件生成时照搬\n'
            '- personality 如实反映人设中明确描述的性格；人设未提及则输出空字符串，不要编造\n'
            '- 修正逻辑矛盾、与主角人设或大纲冲突的内容；不得新增大纲中不存在的能力或设定\n'
            '输出格式：先输出【审查意见】：简要逐条列出修正点（无需修改则写"未发现明显不合理之处"）；'
            '再换行输出【修正后档案】：修正后的 JSON，结构与原档案一致，不要输出其他内容。',
      },
      {
        'role': 'user',
        'content':
            '【主角完整人设】\n$protagonistSetting\n\n'
            '【待审校的人物档案 JSON】\n$profileJson',
      },
    ];
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
              '你是小说小事件提炼助手。请把给定的小事件正文压缩为一份简明小结（800字以内），'
              '保留：本小事件核心进展、结尾处的场景/时间/人物状态、结尾抛出的悬念或伏笔。'
              '只输出小结本身，纯文本，不要任何多余说明。',
        },
        {
          'role': 'user',
          'content':
              '【本小事件】$eventTitle\n'
              '【本小事件概要】$eventSummary\n\n'
              '【本小事件正文】\n$chapterContent',
        },
      ],
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    final content = msg?['content'] as String? ?? '';
    return content.trim();
  }

  /// 整章提炼 — 流式版本：content（小结）与 reasoning_content（AI 思考）
  /// 分别累积回调，供编辑保存页实时展示提炼过程。
  Future<void> streamSummarizeChapter({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String eventTitle,
    required String eventSummary,
    required String chapterContent,
    required void Function(String content) onContent,
    required void Function(String reasoning) onReasoning,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    await _apiService.streamChat(
      apiKey: apiKey,
      apiParams: {...apiParams, 'stream': true},
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说小事件提炼助手。请把给定的小事件正文压缩为一份简明小结（800字以内），'
              '保留：本小事件核心进展、结尾处的场景/时间/人物状态、结尾抛出的悬念或伏笔。'
              '只输出小结本身，纯文本，不要任何多余说明。',
        },
        {
          'role': 'user',
          'content':
              '【本小事件】$eventTitle\n'
              '【本小事件概要】$eventSummary\n\n'
              '【本小事件正文】\n$chapterContent',
        },
      ],
      onChunk: (chunk) {
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) return;
        final delta = choices[0]['delta'] as Map<String, dynamic>?;
        if (delta == null) return;
        final c = delta['content'] as String?;
        if (c != null && c.isNotEmpty) onContent(c);
        final r = delta['reasoning_content'] as String?;
        if (r != null && r.isNotEmpty) onReasoning(r);
      },
      onDone: onDone,
      onError: onError,
    );
  }

  /// AI 审查修正 — 构建请求消息（流式调用由控制器执行，过程可实时查看）。
  /// 在章节生成完成与账本提炼之间执行：只修正正文中逻辑不通、前后矛盾、
  /// 细节与上文不符等不合理之处，**不改变**伏笔、剧情走向、人物设定与大纲情节；
  /// 输出修正后的**完整正文**（正文无需修改时原样输出）。
  List<Map<String, dynamic>> buildReviewMessages({
    required String eventTitle,
    required String eventSummary,
    required String prevEnding,
    required String storyState,
    required String characters,
    required String foreshadows,
    required String chapterContent,
  }) {
    // 已回收 / 已实现的伏笔不再注入审校提示词
    final activeForeshadows = filterResolvedForeshadowText(foreshadows);
    return [
      {
        'role': 'system',
        'content':
            '你是小说小事件审校助手。请审校给定的小事件正文，找出并修正其中不合理之处。\n'
            '审校范围：逻辑不通、前后矛盾、细节与上文不符（时间/地点/人物状态/能力发挥）、'
            '表述错误、明显不合常识等。\n'
            '绝对不得改变：剧情走向与大纲规定的情节、伏笔的埋设与回收安排、'
            '人物设定与能力设定、叙事视角与文风。\n'
            '输出格式：先输出【审查意见】：简要逐条列出发现并修正的问题点'
            '（若正文无需修改则写"未发现明显不合理之处"）；'
            '再换行输出【修正后正文】：修正后的完整正文。不要输出其他任何内容。',
      },
      {
        'role': 'user',
        'content':
            '【本小事件】$eventTitle\n'
            '【事件概要】$eventSummary\n\n'
            '【上一个小事件小结】\n${prevEnding.isEmpty ? '（无）' : prevEnding}\n\n'
            '【全局剧情状态】\n${storyState.trim().isEmpty ? '（无）' : storyState.trim()}\n\n'
            '【人物档案】\n${characters.trim().isEmpty ? '（无）' : characters.trim()}\n\n'
            '【伏笔清单】\n${activeForeshadows.isEmpty ? '（无）' : activeForeshadows}\n\n'
            '【正文】\n$chapterContent',
      },
    ];
  }
}
