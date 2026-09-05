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

  /// 从大纲内容提炼伏笔清单 — 非流式轻量调用。
  /// 供用户修改大纲内容后重提炼，避免注入过期/缺失的伏笔信息。
  Future<String> extractForeshadows({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String outlineContent,
  }) async {
    final response = await _apiService.chat(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说大纲伏笔提炼助手。请从给定的大纲中提取所有已埋设的长线/短线伏笔、悬念与回收点，'
              '输出纯文本清单，每条一行，形如：「伏笔内容（埋设位置 / 计划回收时机）」。'
              '只输出清单本身，不要多余说明；若没有明显伏笔，输出「（暂无）」。',
        },
        {'role': 'user', 'content': outlineContent},
      ],
    );
    final choices = response['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final msg = choices[0]['message'] as Map<String, dynamic>?;
    final content = msg?['content'] as String? ?? '';
    return content.trim();
  }

  /// 流式提炼伏笔清单：content（清单）与 reasoning_content（AI 思考过程）
  /// 分别累积回调，供「AI 伏笔生成详情」界面实时展示。
  /// [existingForeshadows] 旧伏笔清单：结合旧清单修改/补充/删除，而非从零提取覆盖。
  Future<void> streamExtractForeshadows({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required String outlineContent,
    String existingForeshadows = '',
    required void Function(String content) onContent,
    required void Function(String reasoning) onReasoning,
    required void Function() onDone,
    required void Function(String error) onError,
    CancelToken? cancelToken,
  }) async {
    await _apiService.streamChat(
      apiKey: apiKey,
      apiParams: {...apiParams, 'stream': true},
      messages: [
        {
          'role': 'system',
          'content':
              '你是小说大纲伏笔提炼助手。请结合【原有伏笔清单】与当前大纲内容，输出更新后的伏笔清单。\n'
              '- 原有清单中仍然有效的伏笔要保留（埋设位置/计划回收时机可随大纲变化调整）；\n'
              '- 按当前大纲补充新出现的伏笔、悬念与回收点；\n'
              '- 大纲中已不存在的旧伏笔删除，不要保留；\n'
              '- 每条一行，形如：「伏笔内容（埋设位置 / 计划回收时机）」。\n'
              '- 只输出清单本身，不要多余说明；若没有明显伏笔，输出「（暂无）」。',
        },
        {
          'role': 'user',
          'content':
              '【原有伏笔清单】\n'
              '${existingForeshadows.trim().isEmpty ? '（无）' : existingForeshadows.trim()}\n\n'
              '【当前大纲内容】\n$outlineContent',
        },
      ],
      cancelToken: cancelToken,
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
}
