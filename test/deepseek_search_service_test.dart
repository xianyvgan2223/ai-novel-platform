// DeepSeek 官方搜索服务（/v1/tools/search）单元测试
//
// 全部走 Dio 的 HttpClientAdapter 打桩，不联网；真联网的用例在
// live_deepseek_search_test.dart（需要真 Key，默认跳过）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/network/deepseek_search_service.dart';

/// 拦截请求的假适配器：既能断言请求体，也能按需造响应
class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) handler;
  final List<Map<String, dynamic>> requests = [];

  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(jsonDecode(options.data as String) as Map<String, dynamic>);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _errorBody(int status, String message) => _jsonBody({
  'error': {
    'message': message,
    'type': 'invalid_request_error',
    'param': null,
    'code': 'invalid_request_error',
  },
}, status: status);

/// 造一个只走假适配器的服务实例
(DeepSeekSearchService, _FakeAdapter) _service(
  ResponseBody Function(RequestOptions options) handler,
) {
  final adapter = _FakeAdapter(handler);
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  )..httpClientAdapter = adapter;
  return (DeepSeekSearchService(dio: dio), adapter);
}

/// 官方真实返回样例（字段照抄线上响应，中文换成可断言的短句）
Map<String, dynamic> _sampleResponse() => {
  'results': [
    {
      'rerank_score': 2.289104461669922,
      'title': 'DeepSeek 发布新模型',
      'url': 'https://example.com/a',
      'snippet': '短摘要',
      'summary': '长摘要',
      'content': '正文内容',
      'site_name': '示例站点',
      'site_icon': 'https://example.com/favicon.ico',
      'date': '2026-04-26T16:00:00+00:00',
      'authority': 4,
    },
    {
      'rerank_score': 1.1,
      'title': '第二条',
      'url': 'https://example.com/b',
      'snippet': 's2',
      'summary': '',
      'content': '',
      'site_name': null,
      'site_icon': null,
      'date': null,
      'authority': -1,
    },
  ],
};

void main() {
  group('请求体组装', () {
    test('按官方字段名发送 query/count/need_content，并带上 ori_question', () async {
      final (service, adapter) = _service((_) => _jsonBody(_sampleResponse()));

      await service.search(
        query: '  DeepSeek   最新模型  ',
        apiKey: 'sk-test',
        count: 5,
        needContent: true,
        oriQuestion: 'DeepSeek 最近发了什么模型？',
      );

      expect(adapter.requests, hasLength(1));
      final body = adapter.requests.single;
      expect(body['query'], 'DeepSeek 最新模型', reason: '连续空白要合并、首尾要裁掉');
      expect(body['count'], 5);
      expect(body['need_content'], true);
      expect(body['ori_question'], 'DeepSeek 最近发了什么模型？');
    });

    test('count 超出 1~50 时钳制到合法区间（官方超范围直接 400）', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));

      await service.search(query: 'a', apiKey: 'k', count: 999);
      await service.search(query: 'a', apiKey: 'k', count: -3);

      expect(adapter.requests[0]['count'], 50);
      expect(adapter.requests[1]['count'], 1);
    });

    test('query 超过 128 字符时按码点截断，且不劈开中文/emoji', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));

      await service.search(query: '中' * 200, apiKey: 'k');
      await service.search(query: '😀' * 200, apiKey: 'k');

      for (final body in adapter.requests) {
        expect((body['query'] as String).runes.length, 128);
      }
      // 截断后仍是完整的 emoji，没有出现半个代理对
      expect(adapter.requests[1]['query'], '😀' * 128);
    });

    test('ori_question 也按 128 字符上限截断', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));
      await service.search(query: 'a', apiKey: 'k', oriQuestion: 'x' * 300);
      expect((adapter.requests.single['ori_question'] as String).length, 128);
    });

    test('ori_question 为空时不发送该字段', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));
      await service.search(query: 'a', apiKey: 'k');
      expect(adapter.requests.single.containsKey('ori_question'), isFalse);
    });

    test('query 全空白时直接报错，不浪费一次计费请求', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));
      await expectLater(
        service.search(query: '   ', apiKey: 'k'),
        throwsA(
          predicate((e) => e.toString().contains('搜索关键词为空')),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  group('时间筛选 → 官方 query 语法', () {
    final now = DateTime(2026, 10, 17);

    test('pd/pw/pm/py 翻译成 after:日期', () {
      expect(
        DeepSeekSearchService.freshnessToQuerySyntax('pd', now: now),
        'after:2026-10-16',
      );
      expect(
        DeepSeekSearchService.freshnessToQuerySyntax('pw', now: now),
        'after:2026-10-10',
      );
      expect(
        DeepSeekSearchService.freshnessToQuerySyntax('pm', now: now),
        'after:2026-09-17',
      );
      expect(
        DeepSeekSearchService.freshnessToQuerySyntax('py', now: now),
        'after:2025-10-17',
      );
    });

    test('显式区间翻译成 after: + before:（百度写法照旧可用）', () {
      expect(
        DeepSeekSearchService.freshnessToQuerySyntax(
          '2024-01-01to2025-06-30',
          now: now,
        ),
        'after:2024-01-01 before:2025-06-30',
      );
    });

    test('认不出来的值不猜，直接忽略', () {
      expect(DeepSeekSearchService.freshnessToQuerySyntax('上周', now: now), '');
      expect(DeepSeekSearchService.freshnessToQuerySyntax('', now: now), '');
    });

    test('时间语法拼进 query，且总长仍不超过 128 字符', () async {
      final (service, adapter) = _service((_) => _jsonBody({'results': []}));
      await service.search(
        query: '非常长的搜索词' * 30,
        apiKey: 'k',
        freshness: 'pw',
      );
      final query = adapter.requests.single['query'] as String;
      // 服务内部用的是**当前时间**算「过去一周」，这里按同一口径现算期望值：
      // 写死成某个日期的话，第二天跑测试就会红（日期敏感的用例不该钉死时钟）
      final expectedSuffix = DeepSeekSearchService.freshnessToQuerySyntax('pw');
      expect(expectedSuffix, isNotEmpty);
      expect(query.endsWith(' $expectedSuffix'), isTrue);
      expect(query.runes.length, lessThanOrEqualTo(128));
      // 关键：日期没被截断成残句
      expect(query.contains(expectedSuffix), isTrue);
    });
  });

  group('响应解析', () {
    test('解析官方全部字段，并压成 App 通用键名', () async {
      final (service, _) = _service((_) => _jsonBody(_sampleResponse()));
      final results = await service.search(
        query: 'q',
        apiKey: 'k',
        needContent: true,
      );

      expect(results, hasLength(2));
      final first = results.first;
      expect(first.title, 'DeepSeek 发布新模型');
      expect(first.snippet, '短摘要');
      expect(first.summary, '长摘要');
      expect(first.content, '正文内容');
      expect(first.siteName, '示例站点');
      expect(first.date, '2026-04-26T16:00:00+00:00');
      expect(first.authority, 4);
      expect(first.rerankScore, closeTo(2.289, 0.001));

      final map = first.toMap();
      // 老链路（DB / 消息气泡 / Web 端）读的是这几个键，必须保持
      expect(map['name'], 'DeepSeek 发布新模型');
      expect(map['url'], 'https://example.com/a');
      expect(map['snippet'], '短摘要');
      expect(map['content'], '正文内容');
      // DeepSeek 独有字段作为附加键
      expect(map['summary'], '长摘要');
      expect(map['site_name'], '示例站点');
      expect(map['date'], '2026-04-26T16:00:00+00:00');
      expect(map['authority'], 4);
    });

    test('null 字段不炸：缺失的站点/日期按空处理', () async {
      final (service, _) = _service((_) => _jsonBody(_sampleResponse()));
      final results = await service.search(query: 'q', apiKey: 'k');
      final second = results[1];
      expect(second.siteName, '');
      expect(second.date, '');
      expect(second.authority, -1);
      expect(second.toMap().containsKey('site_name'), isFalse);
    });

    test('没有结果时返回空列表（官方也是空数组）', () async {
      final (service, _) = _service((_) => _jsonBody({'results': []}));
      expect(await service.search(query: 'q', apiKey: 'k'), isEmpty);
    });

    test('响应缺少 results 字段时返回空列表而不是抛异常', () async {
      final (service, _) = _service((_) => _jsonBody({'foo': 'bar'}));
      expect(await service.search(query: 'q', apiKey: 'k'), isEmpty);
    });
  });

  group('错误处理', () {
    test('401 提示 Key 无效（官方错误体是 OpenAI 兼容格式）', () async {
      final (service, _) = _service(
        (_) => _errorBody(401, 'Authentication Fails, Your api key: **** is invalid'),
      );
      await expectLater(
        service.search(query: 'q', apiKey: 'bad'),
        throwsA(predicate((e) => e.toString().contains('DeepSeek API Key 无效'))),
      );
    });

    test('402 提示余额不足（搜索按次计费）', () async {
      final (service, _) = _service((_) => _errorBody(402, 'Insufficient Balance'));
      await expectLater(
        service.search(query: 'q', apiKey: 'k'),
        throwsA(predicate((e) => e.toString().contains('余额不足'))),
      );
    });

    test('400 直接透出官方 message，便于定位参数问题', () async {
      final (service, _) = _service(
        (_) => _errorBody(400, "'count' must be between 1 and 50"),
      );
      await expectLater(
        service.search(query: 'q', apiKey: 'k'),
        throwsA(predicate((e) => e.toString().contains("'count' must be between 1 and 50"))),
      );
    });

    test('429 会按官方建议退避重试；重试仍失败时给出限速提示', () async {
      var calls = 0;
      final (service, adapter) = _service((_) {
        calls++;
        return calls == 1
            ? _errorBody(429, 'Rate limit reached')
            : _jsonBody(_sampleResponse());
      });

      final results = await service.search(query: 'q', apiKey: 'k');
      expect(adapter.requests, hasLength(2), reason: '第一次 429 后应重试');
      expect(results, hasLength(2));
    });

    test('401 不重试（重试也不会变好，还白等）', () async {
      final (service, adapter) = _service((_) => _errorBody(401, 'bad key'));
      await expectLater(
        service.search(query: 'q', apiKey: 'bad'),
        throwsA(anything),
      );
      expect(adapter.requests, hasLength(1));
    });
  });
}
