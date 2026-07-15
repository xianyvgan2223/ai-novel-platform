import 'package:dio/dio.dart';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../../shared/models/outline_setting.dart';
import '../../shared/models/outline_record.dart';
import '../../shared/models/db/outline_db_helper.dart';
import '../../shared/models/db/outline_record_db_helper.dart';

/// 大纲生成提示词模板
/// 将硬编码的提示词提取为可配置的模板，便于维护和后续支持自定义。
class OutlinePromptTemplate {
  /// 默认系统提示词
  static const String defaultSystemPrompt = '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';

  /// 构建系统提示词
  static String buildSystemPrompt(String configuredPrompt) {
    return configuredPrompt.isNotEmpty ? configuredPrompt : defaultSystemPrompt;
  }

  /// 构建用户提示词
  static String buildUserPrompt({
    required String genre,
    required String theme,
    required String protagonist,
    required String worldview,
    required int majorEventCount,
    required int minorEventCount,
    required OutlineSetting outlineSetting,
  }) {
    return '''
你是从业十年资深网文/出版双栖小说编辑，擅长搭建逻辑闭环、人物成长清晰、伏笔回收完整的长篇小说大纲，严格遵守所有输出格式与内容约束，禁止擅自增删层级、改格式、加多余符号。

基础设定参数：
小说类型：$genre
核心主题：$theme
主角完整人设：$protagonist（包含身份、初始性格、执念、软肋、终极渴望、初始缺陷）
完整世界观：$worldview（规则、势力、矛盾根源、危险机制、底层冲突）
全篇主事件总数量：$majorEventCount
单个主事件配套小事件固定数量：$minorEventCount

硬性内容创作规则（必须全部执行）：
1. 三幕均衡分配主事件：
   第一幕开端占总主事件30%，第二幕发展占总主事件50%，第三幕高潮结局占总主事件20%，无法整除时第二幕多分配余量；
2. 人物成长强制落地：每一幕结尾写明主角阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→圆满/遗憾闭环」完整人物弧光；
3. 冲突分层：每个大事件必须包含外部矛盾+主角内心矛盾，至少埋1处长线伏笔；第三幕必须回收前文80%以上伏笔；
4. 情节节奏：小事件有递进关系，依次完成铺垫→冲突升级→危机加剧，禁止平铺流水账；
5. 结局区分两种导向：主题正向则圆满救赎结局，主题偏现实/暗黑则留白遗憾结局，全程贴合核心主题；
6. 禁忌约束：不出现逻辑漏洞、战力/世界观崩坏、人物行为动机割裂、强行降智、突兀机械降神。

固定输出格式（一字不差遵守，禁止markdown、表格、json、加粗符号，纯普通文本）：
1. 第一行固定格式：书名：《xxx》，书名贴合类型、主题、主角核心宿命，简洁有记忆点；
2. 第二行为空行；
3. 第三行核心概念简介，严格控制${outlineSetting.conceptMinWords}-${outlineSetting.conceptMaxWords}字，概括世界观、主角核心困境、故事最终落点；
4. 分段结构标识：
══ 第一幕：开端 ══
（分配好的开端主事件）
══ 第二幕：发展 ══
（分配好的发展主事件）
══ 第三幕：高潮&结局 ══
（分配好的高潮结局主事件）

单一大事件统一格式：
══ 大事件X：大事件标题 ══
大事件概述（${outlineSetting.majorEventMinWords}-${outlineSetting.majorEventMaxWords}字，写清本阶段核心危机、主角行动、埋下的长线伏笔）
○ 小事件1：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字，写清场景、冲突、主角心理变化）
○ 小事件2：小标题
小事件概要（${outlineSetting.minorEventMinWords}-${outlineSetting.minorEventMaxWords}字，承接上一小事件，冲突升级，加深主角困境）
……循环至$minorEventCount个小事件
''';
  }
}

/// 大纲生成服务层
/// 职责：加载配置、构建提示词、调用 API、保存结果。
/// 将原本集中在 Controller 中的数据访问与网络请求逻辑抽取至此，
/// 使 Controller 专注于状态管理和 UI 协调。
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

  /// 调用流式 API 生成大纲
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
