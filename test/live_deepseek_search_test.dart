// DeepSeek 官方搜索接口「真联网」测试 —— 默认跳过，避免 CI/日常跑测试时计费。
//
// 跑法（Key 用真 Key，官方按成功请求计费 5 元/1000 次，本文件跑一轮 4~6 次）：
//   PowerShell:  $env:DS_LIVE_API_KEY='sk-xxxx'; flutter test test/live_deepseek_search_test.dart
//   Bash:        DS_LIVE_API_KEY=sk-xxxx flutter test test/live_deepseek_search_test.dart
//
// 目的：验证**真实响应**与本仓库服务代码的契约（字段名、need_content 行为、
// 错误体格式），而不是我对文档的理解。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/network/deepseek_search_service.dart';

String get _apiKey {
  final fromEnv = Platform.environment['DS_LIVE_API_KEY']?.trim() ?? '';
  if (fromEnv.isNotEmpty) return fromEnv;
  return const String.fromEnvironment('DS_LIVE_API_KEY').trim();
}

void main() {
  final apiKey = _apiKey;
  if (apiKey.isEmpty) {
    test('真联网测试（未提供 DS_LIVE_API_KEY，跳过）', () {
      // ignore: avoid_print
      print('跳过：设置环境变量 DS_LIVE_API_KEY 后重跑');
    });
    return;
  }

  final service = DeepSeekSearchService();

  test('真实搜索返回结构化结果', () async {
    final results = await service.search(
      query: 'DeepSeek V4 模型 发布',
      apiKey: apiKey,
      count: 5,
      needContent: true,
      oriQuestion: 'DeepSeek 最近发布了什么模型？',
    );

    // ignore: avoid_print
    print('返回 ${results.length} 条；首条=${results.isEmpty ? '-' : results.first.title}');
    expect(results, isNotEmpty, reason: '官方接口对常见查询应有结果');

    for (final r in results) {
      expect(r.title, isNotEmpty);
      expect(r.url, startsWith('http'));
      expect(r.snippet, isNotEmpty);
      expect(r.summary, isNotEmpty, reason: 'summary 是给模型读的，不该为空');
      expect(r.authority, greaterThanOrEqualTo(-1));
    }

    // toMap 后老链路依赖的键必须齐全
    final map = results.first.toMap();
    expect(map['name'], isNotEmpty);
    expect(map['url'], isNotEmpty);
    expect(map.keys, containsAll(['name', 'url', 'snippet', 'content']));
  });

  test('need_content=false 时不返回正文，true 时返回正文', () async {
    final thin = await service.search(
      query: 'DeepSeek 搜索 API 计费',
      apiKey: apiKey,
      count: 3,
    );
    expect(thin, isNotEmpty);
    expect(
      thin.every((r) => r.content.isEmpty),
      isTrue,
      reason: 'need_content 默认 false，content 应恒为空串',
    );
    expect(thin.every((r) => r.summary.isNotEmpty), isTrue);

    final fat = await service.search(
      query: 'DeepSeek 搜索 API 计费',
      apiKey: apiKey,
      count: 3,
      needContent: true,
    );
    expect(fat, isNotEmpty);
    expect(
      fat.any((r) => r.content.isNotEmpty),
      isTrue,
      reason: 'need_content=true 时至少一条应带网页正文',
    );
  });

  test('搜索语法（site:）被官方接受并生效', () async {
    final results = await service.search(
      query: 'site:api-docs.deepseek.com 网页搜索',
      apiKey: apiKey,
      count: 3,
    );
    expect(results, isNotEmpty);
    expect(
      results.first.url.contains('api-docs.deepseek.com'),
      isTrue,
      reason: 'site: 限定应体现在返回链接上，首条=${results.first.url}',
    );
  });

  test('环境变量里的时间筛选会被翻成 after: 语法并生效', () async {
    final results = await service.search(
      query: 'DeepSeek 模型发布',
      apiKey: apiKey,
      count: 3,
      freshness: 'py',
    );
    expect(results, isNotEmpty);
    // ignore: avoid_print
    print('时间筛选后首条=${results.first.title} 日期=${results.first.date}');
    expect(results.first.date, isNotEmpty, reason: '限定时间后应能拿到发布时间');
  });

  test('无效 Key 得到可读的 401 提示', () async {
    await expectLater(
      service.search(query: 'test', apiKey: 'sk-definitely-invalid-key'),
      throwsA(
        predicate((e) => e.toString().contains('DeepSeek API Key 无效')),
      ),
    );
  });
}
