/// lib/core/network/deepseek_search_service.dart
/// DeepSeek 官方「网页搜索」服务 — 调用官方 Search 接口，返回结构化搜索结果。
///
/// 官方文档：https://api-docs.deepseek.com/zh-cn/guides/search
///   POST https://api.deepseek.com/v1/tools/search
///   Body: {query, count, ori_question, localization, need_content}
///   鉴权：`Authorization: Bearer <DeepSeek API Key>`（**与对话接口同一个 Key**）
///
/// 为什么可以直接用：这个接口是 2026 年新上的「工具类」接口，不属于
/// /chat/completions 的 tools 参数——所以它不受"模型不支持服务端搜索"的限制，
/// 由 App 自己发起请求、拿到结果再喂给模型（就是本 App 既有的两段式流程）。
///
/// 实测确认（真 Key 打真实请求）：
///   * 200 返回 results[]，字段为 rerank_score/title/url/snippet/summary/
///     content/site_name/site_icon/date/authority；
///   * need_content=false 时 content 恒为空串，summary 仍有值（600~800 字符，
///     官方定位"适用于给模型阅读"，界面则用 snippet）；
///   * query 超过 128 字符 / count 超过 50 / query 全空白 → HTTP 400；
///   * Key 无效 → HTTP 401，错误体为 OpenAI 兼容格式 {"error":{"message":...}}；
///   * 单次往返约 0.2~0.6 秒。
///
/// 计费与限速（官方）：按成功请求计费 5 元 / 1000 次，账号级 5 QPS。
/// 因此这里对 429 / 5xx / 超时做有限次的退避重试（接口是只读的，重试安全）。
library;

import 'dart:convert';
import 'package:dio/dio.dart';

/// 单条搜索结果
class DeepSeekSearchResult {
  final String title;
  final String url;

  /// 短摘要，100~200 字符，官方定位"适用于前端展现"
  final String snippet;

  /// 长摘要，600~800 字符，官方定位"适用于给模型阅读"
  final String summary;

  /// 网页正文（Markdown）。need_content=false 或正文缺失时为空串
  final String content;

  /// 站点名称，缺失时为空串
  final String siteName;

  /// 发布时间（UTC RFC 3339），未知时为空串
  final String date;

  /// 网页权威性 0~4，-1 表示未知，>=3 为极权威
  final int authority;

  /// 排序分数 0~3，>=1.5 为优质结果
  final double rerankScore;

  const DeepSeekSearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
    this.summary = '',
    this.content = '',
    this.siteName = '',
    this.date = '',
    this.authority = -1,
    this.rerankScore = 0,
  });

  /// 归一化为 App 内通用的搜索结果 Map。
  ///
  /// 键名沿用百度链路既有的 `name` / `url` / `snippet` / `content`——数据库
  /// `chat_messages.search_results`、消息气泡、聊天页、Web 端都按这几个键读，
  /// 换搜索来源不该动存储格式。DeepSeek 独有的 summary/site_name/date/authority
  /// 作为附加键写入：老界面读不到就忽略，新界面可以直接展示。
  Map<String, dynamic> toMap() => {
    'name': title,
    'url': url,
    'snippet': snippet,
    if (summary.isNotEmpty) 'summary': summary,
    'content': content,
    if (siteName.isNotEmpty) 'site_name': siteName,
    if (date.isNotEmpty) 'date': date,
    if (authority >= 0) 'authority': authority,
    if (rerankScore > 0) 'rerank_score': rerankScore,
  };

  factory DeepSeekSearchResult.fromMap(Map<String, dynamic> map) {
    return DeepSeekSearchResult(
      title: map['title']?.toString() ?? '',
      url: map['url']?.toString() ?? '',
      snippet: map['snippet']?.toString() ?? '',
      summary: map['summary']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
      siteName: map['site_name']?.toString() ?? '',
      date: map['date']?.toString() ?? '',
      authority: (map['authority'] as num?)?.toInt() ?? -1,
      rerankScore: (map['rerank_score'] as num?)?.toDouble() ?? 0,
    );
  }
}

class DeepSeekSearchService {
  /// Search 接口端点
  static const String searchEndpoint =
      'https://api.deepseek.com/v1/tools/search';

  /// 官方硬限制（超了直接 400，已在客户端先做截断/钳制）
  static const int maxQueryRunes = 128;
  static const int minCount = 1;
  static const int maxCount = 50;

  /// 官方默认返回 10 条；本 App 用设置页的 search_count（默认 5）为准
  static const int defaultCount = 10;

  /// 429 / 5xx / 超时的退避间隔（总尝试次数 = 长度 + 1）
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 600),
    Duration(milliseconds: 1500),
  ];

  final Dio _dio;

  /// [dio] 仅用于测试注入；生产走默认配置
  DeepSeekSearchService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
            ),
          );

  /// 执行搜索，返回结果列表（无结果时为空列表，不抛异常）
  ///
  /// [query] 搜索词，超长会按官方 128 字符上限截断；
  /// [apiKey] DeepSeek API Key（与对话同一个）；
  /// [count] 返回条数，钳制到 1~50；
  /// [needContent] 是否抓取网页正文（true 时 content 才有内容）；
  /// [oriQuestion] 触发搜索的用户原始问题，帮助理解搜索意图（可选）；
  /// [freshness] 设置页的「时间筛选」，会被翻译成 query 的 after:/before: 语法。
  Future<List<DeepSeekSearchResult>> search({
    required String query,
    required String apiKey,
    int count = 5,
    bool needContent = false,
    String oriQuestion = '',
    String freshness = '',
  }) async {
    final finalQuery = buildQuery(query, freshness: freshness);
    if (finalQuery.isEmpty) {
      throw Exception('搜索关键词为空');
    }

    final body = <String, dynamic>{
      'query': finalQuery,
      'count': count.clamp(minCount, maxCount),
      'need_content': needContent,
    };
    final ori = truncateRunes(oriQuestion.trim(), maxQueryRunes);
    if (ori.isNotEmpty) body['ori_question'] = ori;

    final data = await _post(searchEndpoint, body, apiKey);

    final results = data['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((r) => DeepSeekSearchResult.fromMap(Map<String, dynamic>.from(r)))
        .toList(growable: false);
  }

  /// 拼装最终 query：清洗空白 + 时间语法 + 128 字符截断。
  ///
  /// 注意截断顺序：先给时间语法留位置再截搜索词，否则 after:/before: 会被
  /// 截掉一半，变成一个既没筛选效果又污染关键词的残缺串。
  static String buildQuery(String raw, {String freshness = ''}) {
    final base = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    final suffix = freshnessToQuerySyntax(freshness);
    if (suffix.isEmpty) return truncateRunes(base, maxQueryRunes);
    final room = maxQueryRunes - suffix.length - 1;
    if (room <= 0) return truncateRunes(suffix, maxQueryRunes);
    return '${truncateRunes(base, room)} $suffix';
  }

  /// 把设置页的「时间筛选」翻译成官方 query 语法。
  ///
  /// 百度链路用的是 `search_recency_filter` 参数（pd/pw/pm/py），DeepSeek 没有
  /// 这个参数，时间范围只能写进 query（`after:日期` / `before:日期`）。这里沿用
  /// 同一套输入，用户不用学第二套写法：
  ///   pd → 过去 1 天、pw → 7 天、pm → 30 天、py → 365 天
  ///   `YYYY-MM-DDtoYYYY-MM-DD` → after:起 before:止
  /// 认不出来的值原样丢弃（不猜），[now] 仅用于测试注入。
  static String freshnessToQuerySyntax(String freshness, {DateTime? now}) {
    final f = freshness.trim();
    if (f.isEmpty) return '';

    final range = RegExp(
      r'^(\d{4}-\d{2}-\d{2})\s*(?:to|~)\s*(\d{4}-\d{2}-\d{2})$',
    ).firstMatch(f);
    if (range != null) {
      return 'after:${range[1]} before:${range[2]}';
    }

    final days = const {'pd': 1, 'pw': 7, 'pm': 30, 'py': 365}[f.toLowerCase()];
    if (days == null) return '';
    final from = (now ?? DateTime.now()).subtract(Duration(days: days));
    return 'after:${isoDate(from)}';
  }

  /// 按 Unicode 码点截断（不能按 UTF-16 长度截，会把中文/emoji 劈成半个字符）
  static String truncateRunes(String s, int max) {
    if (max <= 0) return '';
    final runes = s.runes.toList(growable: false);
    if (runes.length <= max) return s;
    return String.fromCharCodes(runes.take(max));
  }

  /// yyyy-MM-dd
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 带退避重试的 POST（只读接口，重试安全）
  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body,
    String apiKey,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
      try {
        final response = await _dio.post(
          url,
          data: jsonEncode(body),
          options: Options(
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
          ),
        );
        return _asMap(response.data);
      } on DioException catch (e) {
        lastError = e;
        if (attempt == _retryDelays.length || !_shouldRetry(e)) break;
        await Future<void>.delayed(_retryDelays[attempt]);
      }
    }
    throw Exception(_parseError(lastError));
  }

  static bool _shouldRetry(DioException e) {
    final code = e.response?.statusCode;
    if (code == null) {
      // 连接/读取超时属于可重试的网络问题；其余（如 URL 非法）不重试
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError;
    }
    return code == 429 || code >= 500;
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    throw Exception('搜索接口返回了无法解析的数据');
  }

  /// 把网络异常翻译成用户看得懂的一句话
  static String _parseError(Object? error) {
    if (error is! DioException) return error?.toString() ?? '未知错误';

    final code = error.response?.statusCode;
    final serverMsg = _extractServerMessage(error.response?.data);

    if (code == 401) return 'DeepSeek API Key 无效，请检查设置';
    if (code == 402) return 'DeepSeek 账户余额不足（搜索按次计费），请充值后重试';
    if (code == 429) return '搜索请求过于频繁（官方限速 5 QPS），请稍后重试';
    if (serverMsg != null && serverMsg.isNotEmpty) return serverMsg;

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '搜索超时，请稍后重试';
      default:
        return '网络异常：${error.message ?? '未知错误'}';
    }
  }

  /// 提取 OpenAI 兼容错误体里的 message
  static String? _extractServerMessage(dynamic data) {
    dynamic payload = data;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        return payload.trim().isEmpty ? null : payload.trim();
      }
    }
    if (payload is Map) {
      final err = payload['error'];
      if (err is Map && err['message'] != null) return err['message'].toString();
      return payload['message']?.toString() ?? payload['error_msg']?.toString();
    }
    return null;
  }
}
