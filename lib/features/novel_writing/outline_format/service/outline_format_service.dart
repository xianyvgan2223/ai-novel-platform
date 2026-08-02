import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import 'package:deepseekapp/core/config/user_setting_service.dart';
import '../../shared/domain/outline_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/data/outline_db_helper.dart';

/// 大纲格式匹配 — 提示词模板
class OutlineFormatPromptTemplate {
  static const String defaultSystemPrompt = '你是一个专业的小说大纲格式化助手，请用纯文本格式输出。';

  /// 构建系统提示词
  static String buildSystemPrompt(String configuredPrompt) {
    return configuredPrompt.trim().isNotEmpty
        ? configuredPrompt
        : defaultSystemPrompt;
  }

  /// 构建格式化提示词
  static String buildFormatPrompt(String input) {
    return '''
你是一个专业的小说大纲格式化工具。请将用户提供的大纲内容，按照以下固定格式重新组织和输出。

固定输出格式要求（严格遵循，不要使用markdown、表格、json或任何标记符号，只输出纯文本）：

1. 第一行：书名：《xxx》（如果原内容有书名则沿用，没有则根据内容提炼一个）
2. 第二行：空行
3. 核心概念简介（30-50字，概括世界观、主角核心困境、故事最终落点）
4. 然后按三幕结构组织内容，格式与「一键生成大纲」功能完全一致：

══ 第一幕：开端 ══
══ 大事件1：标题 ══
大事件概述（50-100字）
○ 小事件1：标题
小事件概要（30-50字）
○ 小事件2：标题
小事件概要
══ 大事件2：标题 ══
大事件概述
○ 小事件1：标题
小事件概要
○ 小事件2：标题
小事件概要

══ 第二幕：发展 ══
══ 大事件3：标题 ══
大事件概述
○ 小事件1：标题
小事件概要
○ 小事件2：标题
小事件概要

══ 第三幕：高潮&结局 ══
══ 大事件N：标题 ══
大事件概述
○ 小事件1：标题
小事件概要
○ 小事件2：标题
小事件概要

注意事项：
- 大事件用 ══ 大事件N：标题 ══ 格式，编号必须跨三幕全局连续递增（第一幕 1、2、3…，第二幕接着往下，第三幕同理），禁止每幕从 1 重新编号
- 小事件用 ○ 小事件N：标题 格式，编号在每个大事件内部从 1 重新开始
- 事件概要直接写在标题的下一行，不要加任何前缀符号
- 幕标题用 ══ 第一幕：开端 ══ / ══ 第二幕：发展 ══ / ══ 第三幕：高潮&结局 ══
- 保留原文中所有有价值的情节信息，不要遗漏重要内容
- 如果原文有明确的三幕划分，请保留；如果没有，请根据内容合理划分
- 保持内容连贯，不要随意增删情节
- 事件数量根据原文内容灵活调整，不要强行凑数

用户的大纲内容如下：
---
$input
---
''';
  }
}

/// 大纲格式匹配服务层
/// 职责：加载配置、调用流式 API、保存结果。
class OutlineFormatService {
  final ApiService _apiService;

  OutlineFormatService({ApiService? apiService})
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

  /// 调用流式格式化 API
  Future<void> streamFormat({
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
