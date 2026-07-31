import 'package:dio/dio.dart';
import 'package:deepseekapp/core/network/api_service.dart';
import 'package:deepseekapp/core/config/user_setting_service.dart';
import '../../shared/domain/outline_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/data/outline_db_helper.dart';

/// 章节写作 — 提示词模板
class ChapterWritePromptTemplate {
  /// 构建章节写作提示词
  static String buildWritePrompt({
    required OutlineRecord outline,
    required String outlineContent,
    required OutlineChapter ch,
    required String prevContent,
  }) {
    return '''
你是一位小说作家。请根据以下大纲设定，完整写出指定事件的详细章节内容。

【小说设定】
类型：${outline.genre}
主题：${outline.theme}
主角：${outline.protagonist}
世界观：${outline.worldview}

【大纲结构】
${outlineContent}

【当前事件】${ch.eventTitle}
【事件概要】${ch.eventSummary}

【前文摘要】${prevContent}

要求：
1. 以文学性强的叙述方式展开，包含场景描写、对话、心理活动
2. 字数 2000-3000 字
3. 结尾自然衔接下一个事件
4. 只写当前事件的内容，不要超出范围
5. 直接输出正文，不要添加注释说明
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
}
