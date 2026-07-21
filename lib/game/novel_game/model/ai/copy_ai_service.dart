import 'dart:convert';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../entity/character_entity.dart';

/// AI生成副本故事的服务类
/// 使用应用中已有的 ApiService 和 UserSettingService
class CopyAiService {
  final ApiService _apiService;

  CopyAiService({ApiService? apiService})
    : _apiService = apiService ?? ApiService();

  /// 从响应中提取 content 字符串
  String _extractContent(Map<String, dynamic> response) {
    final choices = response['choices'] as List<dynamic>?;
    if (choices != null && choices.isNotEmpty) {
      final msg = choices[0]['message'] as Map<String, dynamic>?;
      if (msg != null) {
        return msg['content'] as String? ?? '';
      }
    }
    return '';
  }

  /// 生成副本总故事
  /// 输入角色列表和副本名称
  /// 返回包含总故事、公共装备、角色交集的 Map
  Future<Map<String, dynamic>> generateCopyTotalStory(
    List<CharacterEntity> characters,
    String copyName, {
    String? background,
    String? style,
  }) async {
    final charInfos = characters
        .map((c) {
          return '角色名: ${c.charName}, 基础设定: ${c.baseDesc ?? "无"}';
        })
        .join('\n');

    String styleHint = '';
    if (style != null && style != '默认') {
      styleHint = '\n故事风格：$style';
    }
    if (background != null && background.isNotEmpty) {
      styleHint += '\n背景设定：$background';
    }

    final prompt =
        '''
请根据以下角色信息，为副本"$copyName"生成一个完整的故事大纲。$styleHint

角色信息：
$charInfos

请以JSON格式返回，包含以下字段：
1. total_story: 故事总纲（字符串）
2. public_equipment: 公共装备列表（数组, 每个元素包含name和attr字段）
3. intersections: 角色交集列表（数组, 每个元素包含char_a_name, char_b_name, desc字段）

请只返回JSON格式数据，不要包含其他内容。
''';

    final settings = await UserSettingService.getSettings();
    if (settings.apiKey.isEmpty) {
      throw Exception('请先在设置中配置 API Key');
    }

    final apiParams = settings.toApiParams();
    final messages = [
      {'role': 'user', 'content': prompt},
    ];

    final response = await _apiService.chat(
      apiKey: settings.apiKey,
      apiParams: apiParams,
      messages: messages,
    );

    final content = _extractContent(response);
    if (content.isEmpty) {
      throw Exception('AI 响应内容为空');
    }

    // 尝试从 content 中提取 JSON
    final jsonStr = _extractJson(content);
    if (jsonStr != null) {
      try {
        final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
        return {
          'totalStory': parsed['total_story'] as String? ?? '',
          'publicEquipment': parsed['public_equipment'] as List<dynamic>? ?? [],
          'intersectionTexts': parsed['intersections'] as List<dynamic>? ?? [],
        };
      } catch (_) {}
    }

    return {
      'totalStory': content,
      'publicEquipment': <dynamic>[],
      'intersectionTexts': <dynamic>[],
    };
  }

  /// 生成单个角色的故事
  /// 输入角色信息、总故事
  /// 返回包含单人故事、技能、装备的 Map
  Future<Map<String, dynamic>> generateSingleCharacterStory(
    String characterInfo,
    String totalStory,
  ) async {
    final prompt =
        '''
根据以下故事总纲和角色信息，生成该角色的个人故事线。

故事总纲：
$totalStory

角色信息：
$characterInfo

请以JSON格式返回，包含以下字段：
1. single_story: 该角色的个人故事（字符串）
2. skills: 该角色获得的技能列表（数组, 每个元素包含name和desc字段）
3. equipment: 该角色获得的装备列表（数组, 每个元素包含name和attr字段）

请只返回JSON格式数据，不要包含其他内容。
''';

    final settings = await UserSettingService.getSettings();
    if (settings.apiKey.isEmpty) {
      throw Exception('请先在设置中配置 API Key');
    }

    final apiParams = settings.toApiParams();
    final messages = [
      {'role': 'user', 'content': prompt},
    ];

    final response = await _apiService.chat(
      apiKey: settings.apiKey,
      apiParams: apiParams,
      messages: messages,
    );

    final content = _extractContent(response);
    if (content.isEmpty) {
      throw Exception('AI 响应内容为空');
    }

    final jsonStr = _extractJson(content);
    if (jsonStr != null) {
      try {
        final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
        return {
          'singleStory': parsed['single_story'] as String? ?? '',
          'skills': parsed['skills'] as List<dynamic>? ?? [],
          'equipment': parsed['equipment'] as List<dynamic>? ?? [],
        };
      } catch (_) {}
    }

    return {
      'singleStory': content,
      'skills': <dynamic>[],
      'equipment': <dynamic>[],
    };
  }

  /// 从文本中提取 JSON 部分（处理 AI 可能返回 markdown 包裹的情况）
  String? _extractJson(String text) {
    // 尝试匹配 ```json ... ``` 格式
    final jsonBlockRegExp = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final match = jsonBlockRegExp.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }
    // 尝试匹配 { ... } 格式
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start != -1 && end != -1 && end > start) {
      return text.substring(start, end + 1);
    }
    return null;
  }
}
