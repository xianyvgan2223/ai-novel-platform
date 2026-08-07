import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import 'package:deepseekapp/core/config/user_setting_service.dart';
import '../../shared/domain/outline_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/data/outline_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';

/// 大纲生成提示词模板 — 分步式生成（Chain-of-Thought）
///
/// 设计原则：
/// - 步骤 1/2 使用结构化 JSON 输出（配合 response_format: json_object），
///   由控制器做数量校验与失败重试，避免脆弱的正则解析
/// - 步骤 3 保持纯文本流式输出，并注入「全局摘要」（书名+概念+完整三幕骨架），
///   保证每个展开块都能看到全局上下文，提升跨幕一致性
class OutlinePromptTemplate {
  /// 默认系统提示词 — 通用的角色定义 + 全局格式约束（用于步骤 3 文本输出）
  static const String defaultSystemPrompt =
      '你是一个专业的小说大纲生成助手，擅长搭建逻辑闭环、人物成长清晰、'
      '伏笔回收完整的长篇小说大纲。\n'
      '请始终使用纯文本格式输出，禁止使用markdown、表格、json、加粗符号或任何标记语言。\n'
      '不要添加多余的解释性文字。';

  /// 步骤 1/2 使用的 JSON 系统提示 — 与文本系统提示解耦，
  /// 避免默认提示中「禁止 json」的约束与结构化输出冲突
  static const String jsonSystemPrompt =
      '你是一个专业的小说大纲生成助手，擅长搭建逻辑闭环、人物成长清晰、'
      '伏笔回收完整的长篇小说大纲。\n'
      '请严格按照用户要求的结构输出 JSON 数据，'
      '不要输出 JSON 以外的任何文字、解释或 markdown 代码块。';

  /// 构建步骤 3（展开）的系统提示词
  static String buildSystemPrompt(String configuredPrompt) {
    return configuredPrompt.trim().isNotEmpty
        ? configuredPrompt
        : defaultSystemPrompt;
  }

  /// 步骤 1：定调 — 生成书名 + 核心概念（JSON 输出）
  static String buildStep1Prompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
  }) {
    return '''
根据以下小说设定，生成书名和核心概念简介，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview

要求：
- 书名务必贴合类型、主题、主角核心宿命，简洁有记忆点
- 核心概念简介概括世界观、主角核心困境、故事最终落点
- 输出 JSON 格式为：{"title": "书名", "concept": "核心概念简介"}''';
  }

  /// 步骤 2a：规划三幕粗骨架 — 全部大事件只写「标题 + 一句话定位」（JSON 输出）
  ///
  /// 只产出轻量定位信息，锁定全局轨迹（谁先谁后、伏笔埋点、高潮位置），
  /// 不写详述，避免「大事件被压缩成小事件」；详细描述由 2b 分批精写。
  static String buildCoarseSkeletonPrompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required int majorEventCount,
    required int minorEventCount,
    required String titleAndConcept, // 步骤1的输出：书名+核心概念
  }) {
    return '''
请根据以下小说设定，规划全篇三幕结构的粗骨架，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview

已有书名和核心概念：
$titleAndConcept

全篇主事件总数量：$majorEventCount（三个 act 中 events 事件总数必须严格等于 $majorEventCount）
单个主事件配套小事件固定数量：$minorEventCount

三幕分配规则：第一幕开端占总主事件约30%，第二幕发展约占50%，第三幕高潮结局约占20%，无法整除时第二幕多分配余量。

粗骨架要求：
1. 这一步只规划全局轨迹，每个大事件只写「标题 + 一句话定位」，不要展开细节
2. 定位需写清：本事件的核心冲突、在故事弧线中的位置（铺垫/升级/转折/高潮/结局）
3. 大事件之间要有递进关系：铺垫→冲突升级→危机加剧→高潮→收束
4. 人物成长：每一幕结尾主角有阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→闭环」
5. 至少预留 3 处长线伏笔的埋设点，并在定位中标注（如「埋长线伏笔：xxx」）
6. 第三幕需覆盖前文主要伏笔的回收点

输出 JSON 格式为：
{"acts": [{"act": "第一幕：开端", "events": [{"title": "事件标题", "position": "一句话定位（含在故事中的位置与伏笔提示）"}]}]}
要求：
- 必须输出 3 个 act，act 依次为「第一幕：开端」「第二幕：发展」「第三幕：高潮&结局」
- 每个 act 至少包含 1 个事件
- 全部 events 数量必须严格等于 $majorEventCount''';
  }

  /// 步骤 2b：精写一批大事件 — 按粗骨架逐个展开为完整概述（JSON 输出）
  ///
  /// 每次只精写本批（约总数的 1/10，封顶 5 个）大事件，注入：
  /// 完整粗骨架（轨迹地图）+ 本批事件 + 前序伏笔账本 +
  /// 紧邻上一批已精写的完整概述（[prevRefinedContent]，仅上一批、非全部历史），
  /// 保证每个大事件的粒度、跨批次伏笔连续性，以及相邻批次大事件的因果承接。
  static String buildRefineBatchPrompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required String title,
    required String concept,
    required String coarseSkeletonText, // 完整粗骨架（标题+定位）
    required String batchContent, // 本批大事件（标题+定位）
    required String ledgerText, // 已积累的伏笔账本
    String prevRefinedContent = '', // 上一批已精写的完整概述（无则留空）
  }) {
    final prevSection = prevRefinedContent.trim().isEmpty
        ? ''
        : '''
=== 上一批已精写的大事件（本批必须严格承接其结局状态与已发生情节，禁止重复或矛盾） ===
$prevRefinedContent

''';

    return '''
请根据以下全局设定、粗骨架和伏笔账本，精写本批大事件的完整概述，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview
书名：$title
核心概念：$concept

=== 全局粗骨架（全部大事件，仅标题与定位） ===
$coarseSkeletonText

=== 本批需要精写的大事件（标题必须与粗骨架完全一致，按顺序输出） ===
$batchContent

=== 已积累的伏笔账本（来自此前各批，必须延续与照应） ===
$ledgerText

$prevSection大事件粒度定义（严格遵守）：
- 大事件 = 改变故事走向的重大阶段节点（如身份揭露、势力决裂、觉醒/蜕变、终局大战），应跨越时间与场景，可独立成章
- 禁止把单个场景、单次对话、单一动作步骤当作大事件
- 大事件数量多代表故事铺陈规模大，不代表粒度变细

写作要求：
1. 每个大事件包含外部矛盾+主角内心矛盾，呼应本批定位中的伏笔提示
2. 相邻大事件有递进关系，事件之间需有时间/场景跳跃，独立成章
3. 延续伏笔账本：已埋伏笔按计划回收，本批新埋伏笔在描述中点明
4. 承接上一批：本批首个大事件须延续上一批最后大事件的结局状态（人物处境、关系变化、已获得的信息、在场角色），已发生的情节与已出现的冲突不得重复（若未提供「上一批已精写的大事件」则忽略此条）
5. 篇幅由你根据该事件在全局中的重要程度自行把握，写透核心冲突，宁实勿空
6. 避免逻辑漏洞、人物动机割裂、强行降智

输出 JSON 格式为：
{"events": [{"title": "与粗骨架完全一致的事件标题", "summary": "完整概述"}]}
要求：
- events 数量必须严格等于本批大事件数量
- title 必须与粗骨架中的标题完全一致，保持顺序''';
  }

  /// 步骤 2c：抽取伏笔账本 — 总结本批大事件，输出结构化状态（JSON 输出）
  ///
  /// 从本批已精写的内容中抽取伏笔、角色状态、未解决悬念，
  /// 供后续批次与步骤 3 展开时延续/回收，保证长线伏笔闭环。
  static String buildLedgerPrompt({
    required String batchContent, // 本批已精写的大事件（标题+完整概述）
    required String prevLedgerText, // 前序账本
  }) {
    return '''
请阅读以下本批已精写的大事件，结合之前的伏笔账本，抽取并合并出最新的伏笔账本，以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

=== 本批已精写的大事件 ===
$batchContent

=== 之前已积累的伏笔账本（需保留未回收项，标注本批是否有进展） ===
$prevLedgerText

要求：
1. 列出所有未回收/新埋的长线伏笔，每条注明计划回收时机（第几幕）
2. 更新各主要角色的当前处境与变化
3. 列出尚未解决的悬念
4. 已在批内回收的伏笔标注「已回收」

输出 JSON 格式为：
{"foreshadows": [{"content": "伏笔内容", "status": "已埋/已回收", "plan": "计划回收时机"}], "character_states": ["角色状态1"], "unresolved": ["悬念1"]}''';
  }

  /// 步骤 3：展开某幕细节 — 为指定大事件生成完整小事件（文本流式输出）
  ///
  /// [globalSummary] 全局摘要：书名 + 核心概念 + 完整三幕骨架，
  /// 让每个展开块都能看到全局上下文，避免跨幕角色行为/伏笔矛盾。
  /// [previousContent] 紧邻的前一块已展开的详细内容：本块必须严格承接其结尾状态，
  /// 禁止重复已发生情节，保证跨块小事件因果连贯。
  /// [laterContent] 紧接着的下一块待展开大事件：本块结尾须为其铺垫与过渡，避免生硬跳转。
  static String buildStep3Prompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required int majorEventCount,
    required int minorEventCount,
    required String title, // 书名
    required String actContent, // 步骤2中该块的原始内容（含大事件标题+概述）
    required int actIndex, // 1-based 幕索引（1/2/3）
    required String globalSummary, // 全局摘要（书名+概念+完整三幕骨架）
    String previousContent = '', // 前文已展开的详细内容（本块必须严格承接）
    String laterContent = '', // 后文待展开的大事件（本块须为其做好铺垫过渡）
  }) {
    final actNames = ['开端', '发展', '高潮&结局'];
    final actName = actIndex >= 1 && actIndex <= 3
        ? actNames[actIndex - 1]
        : '第$actIndex幕';

    final previousSection = previousContent.trim().isEmpty
        ? ''
        : '''
=== 前一块已展开的详细内容（必须严格承接，禁止重复或矛盾） ===
$previousContent

''';
    final laterSection = laterContent.trim().isEmpty
        ? ''
        : '''
=== 紧接着的下一块大事件（本块结尾须为其铺垫与过渡） ===
$laterContent

''';

    return '''
请展开第$actIndex幕（$actName）的详细内容。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview
书名：$title

=== 全局框架（保证与全局设定、其他幕保持一致） ===
$globalSummary

$previousSection$laterSection=== 当前幕已有的大事件框架 ===
$actContent

请为上述每个大事件展开配套的小事件（共$minorEventCount个小事件每个），严格遵循以下格式：

══ 大事件X：大事件标题 ══
大事件概述（写清本阶段核心危机、主角行动、埋下的长线伏笔，篇幅按重要程度自行把握）
○ 小事件1：小标题
小事件概要
○ 小事件2：小标题
小事件概要
○ 小事件3：小标题
小事件概要
……（循环至$minorEventCount个小事件）

⚠️ 小事件写作核心要求：
1. 每个小事件必须是独立完整的情节单元，不是大事件的一个执行步骤
2. 禁止将单个事件拆成时序步骤（例如“前往→发现→战斗→撤退”这种只算1个小事件）
3. 每个小事件应引入新的角色、地点、冲突或转折，而不是单纯推进上一个事件
4. 好小事件 = 场景 + 冲突 + 变化，差小事件 = 下一个动作步骤

注意：
- 只输出当前这一幕的内容，不要输出其他幕
- 保持大事件标题和概述与已有框架一致
- 小事件要有递进关系，禁止平铺流水账
- 参照全局框架中其他幕的人物状态与伏笔，避免前后矛盾
- 承接前文：若提供了「前一块已展开的详细内容」，本块开头必须紧接其最后一场戏的结尾状态
  （人物所处位置、伤势/体力、情绪、已获得的信息、当前在场的角色），
  禁止重复前文已发生的情节（如再次「初次见面」「第一次对峙」）
- 铺垫后文：若提供了「紧接着的下一块大事件」，本块结尾要为其埋下伏笔、做好状态过渡，
  保证前后事件因果连贯、过渡自然''';
  }
}

/// 大纲生成服务层
/// 职责：加载配置、构建提示词、调用 API、保存结果。
class OutlineService {
  final ApiService _apiService;

  OutlineService({ApiService? apiService})
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

  /// 调用流式/非流式 API
  Future<void> streamGenerate({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
    required void Function(Map<String, dynamic> chunk) onChunk,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    await _apiService.streamChat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: messages,
      cancelToken: cancelToken,
      onChunk: onChunk,
      onDone: onDone,
      onError: onError,
    );
  }

  /// 保存大纲记录到数据库
  Future<void> saveRecord(OutlineRecord record) async {
    await OutlineRecordDbHelper().insert(record.toMap());
  }
}
