/// lib/services/baidu_search_service.dart
/// 百度千帆联网搜索服务 — 调用百度 AI 搜索 API，返回搜索结果列表

import 'dart:convert';
import 'package:dio/dio.dart';

class BaiduSearchResult {
  final String title;
  final String url;
  final String snippet;
  final String content; // 页面正文内容

  const BaiduSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.content = '',
  });

  Map<String, dynamic> toMap() => {
    'name': title,
    'url': url,
    'snippet': snippet,
    'content': content,
  };

  factory BaiduSearchResult.fromMap(Map<String, dynamic> map) {
    return BaiduSearchResult(
      title: map['title']?.toString() ?? '',
      url: map['url']?.toString() ?? '',
      snippet: map['snippet']?.toString() ?? map['abstract']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
    );
  }
}

class BaiduSearchService {
  /// 百度 AI 搜索 API 端点
  static const _searchUrl =
      'https://qianfan.baidubce.com/v2/ai_search/web_search';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  /// 执行百度搜索，返回搜索结果列表
  Future<List<BaiduSearchResult>> search({
    required String query,
    required String apiKey,
    int count = 5,
    String freshness = '',
  }) async {
    try {
      final requestBody = <String, dynamic>{
        'messages': [
          {'role': 'user', 'content': query},
        ],
        'search_source': 'baidu_search_v2',
        'resource_type_filter': [
          {'type': 'web', 'top_k': count},
        ],
      };

      // 可选：时间筛选
      if (freshness.isNotEmpty) {
        requestBody['search_recency_filter'] = freshness;
      }

      final response = await _dio.post(
        _searchUrl,
        data: jsonEncode(requestBody),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      final data = response.data as Map<String, dynamic>;
      // 百度 AI 搜索返回的搜索结果在 references 字段中
      final references = data['references'] as List<dynamic>? ?? [];
      return references
          .map((r) => BaiduSearchResult.fromMap(r as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      final msg = _parseError(e);
      throw Exception('百度搜索失败：$msg');
    } catch (e) {
      throw Exception('百度搜索异常：$e');
    }
  }

  String _parseError(DioException e) {
    try {
      final data = e.response?.data;
      if (data is Map) {
        return data['error_msg']?.toString() ??
            data['message']?.toString() ??
            'HTTP ${e.response?.statusCode}';
      }
    } catch (_) {}
    return e.message ?? '未知错误';
  }
}
