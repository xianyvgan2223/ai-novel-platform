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
/// - System Prompt 只放通用角色定义和全局格式约束，保持稳定
/// - User Prompt 聚焦内容输入，每个步骤只包含该步骤所需的最小指令集
/// - 分步降低单次上下文的认知负载，提高生成质量
class OutlinePromptTemplate {
  /// 默认系统提示词 — 通用的角色定义 + 全局格式约束
  static const String defaultSystemPrompt =
      '你是一个专业的小说大纲生成助手，擅长搭建逻辑闭环、人物成长清晰、'
      '伏笔回收完整的长篇小说大纲。\n'
      '请始终使用纯文本格式输出，禁止使用markdown、表格、json、加粗符号或任何标记语言。\n'
      '不要添加多余的解释性文字。';

  /// 构建系统提示词
  static String buildSystemPrompt(String configuredPrompt) {
    return configuredPrompt.isNotEmpty ? configuredPrompt : defaultSystemPrompt;
  }

  /// 步骤 1：定调 — 生成书名 + 核心概念
  ///
  /// User Prompt 专注内容输入，格式要求保持在最简。
  static String buildStep1Prompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
  }) {
    return '''
根据以下小说设定，生成书名和核心概念简介。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview

要求：
- 书名务必贴合类型、主题、主角核心宿命，简洁有记忆点
- 核心概念简介概括世界观、主角核心困境、故事最终落点
- 第一行输出格式：「书名：《xxx」」
- 第二行为空行
- 第三行开始为核心概念内容''';
  }

  /// 步骤 2：生成三幕结构 — 确定大事件列表
  ///
  /// 基于步骤 1 的结果，生成三幕骨架和主事件分配。
  static String buildStep2Prompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required int majorEventCount,
    required int minorEventCount,
    required String titleAndConcept, // 步骤1的输出：书名+核心概念
    required OutlineSetting outlineSetting,
  }) {
    return '''
请根据以下小说设定和大纲框架，生成三幕结构的大事件列表。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview

已有书名和核心概念：
$titleAndConcept

全篇主事件总数量：$majorEventCount
单个主事件配套小事件固定数量：$minorEventCount

三幕分配规则：第一幕开端占总主事件约30%，第二幕发展约占50%，第三幕高潮结局约占20%，无法整除时第二幕多分配余量。

内容创作要求：
1. 人物成长：每一幕结尾主角有阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→圆满/遗憾闭环」
2. 冲突分层：每个大事件包含外部矛盾+主角内心矛盾，至少埋1处长线伏笔；第三幕回收前文80%以上伏笔
3. 情节节奏：大事件之间有递进关系，依次完成铺垫→冲突升级→危机加剧
4. 结局：主题正向则圆满救赎，偏现实/暗黑则留白遗憾
5. 避免逻辑漏洞、战力/世界观崩坏、人物动机割裂、强行降智

输出格式要求：
══ 第一幕：开端 ══
大事件1：标题
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字）

══ 第二幕：发展 ══
大事件3：标题
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字）

══ 第三幕：高潮&结局 ══
大事件5：标题
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字）''';
  }

  /// 步骤 3：展开某幕细节 — 为指定幕生成完整大/小事件
  ///
  /// 每次调用展开一幕，基于步骤 2 确定的大事件列表填充小事件。
  static String buildStep3Prompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required int majorEventCount,
    required int minorEventCount,
    required String title, // 书名
    required String actContent, // 步骤2中该幕的原始内容（含大事件标题+概述）
    required int actIndex, // 1-based 幕索引（1/2/3）
    required OutlineSetting outlineSetting,
  }) {
    final actNames = ['开端', '发展', '高潮&结局'];
    final actName = actIndex >= 1 && actIndex <= 3
        ? actNames[actIndex - 1]
        : '第$actIndex幕';

    return '''
请展开第$actIndex幕（$actName）的详细内容。

小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist
完整世界观：$worldview
书名：$title

当前幕已有的大事件框架：
$actContent

请为上述每个大事件展开配套的小事件（共$minorEventCount个小事件每个），严格遵循以下格式：

══ 大事件X：大事件标题 ══
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字，写清本阶段核心危机、主角行动、埋下的长线伏笔）
○ 小事件1：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字）
○ 小事件2：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字）
○ 小事件3：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字）
……（循环至$minorEventCount个小事件）

⚠️ 小事件写作核心要求：
1. 每个小事件必须是独立完整的情节单元，不是大事件的一个执行步骤
2. 禁止将单个事件拆成时序步骤（例如“前往→发现→战斗→撤退”这种只算1个小事件）
3. 每个小事件应引入新的角色、地点、冲突或转折，而不是单纯推进上一个事件
4. 好小事件 = 场景 + 冲突 + 变化，差小事件 = 下一个动作步骤

注意：
- 只输出当前这一幕的内容，不要输出其他幕
- 保持大事件标题和概述与已有框架一致
- 小事件要有递进关系，禁止平铺流水账''';
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

  /// 调用流式 API
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
