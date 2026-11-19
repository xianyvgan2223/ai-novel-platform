import 'package:deepseekapp/core/config/user_setting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('官方 Chat Completions 参数完整映射', () {
    const setting = UserSetting(
      model: 'deepseek-pro',
      temperature: 0.7,
      topP: 0.8,
      maxTokens: 8192,
      stop: '第一章，END',
      stream: true,
      streamIncludeUsage: true,
      responseFormat: 'json_object',
      thinking: true,
      reasoningEffort: 'low',
      toolChoice: 'none',
      safetyCheck: 'high',
      titleEnabled: true,
      userId: 'user-1',
      logprobs: true,
      topLogprobs: 5,
    );

    final params = setting.toApiParams();
    expect(params['model'], 'deepseek-v4-pro');
    expect(params['temperature'], 0.7);
    expect(params['top_p'], 0.8);
    expect(params['max_tokens'], 8192);
    expect(params['stream'], isTrue);
    expect(params['stop'], ['第一章', 'END']);
    expect(params['stream_options'], {'include_usage': true});
    expect(params['response_format'], {'type': 'json_object'});
    expect(params['reasoning_effort'], 'low');
    expect(params.containsKey('thinking'), isFalse);
    expect(params['safety_check'], {'level': 'high'});
    expect(params['title'], {'enabled': true});
    expect(params['user_id'], 'user-1');
    expect(params['logprobs'], isTrue);
    expect(params['top_logprobs'], 5);
    // 官方已弃用 / 不存在的字段不再发送。
    expect(params.containsKey('frequency_penalty'), isFalse);
    expect(params.containsKey('presence_penalty'), isFalse);
    expect(params.containsKey('logit_bias'), isFalse);
    expect(params.containsKey('n'), isFalse);
  });

  test('关闭思考与非流式时省略对应参数', () {
    const setting = UserSetting(
      thinking: false,
      reasoningEffort: 'max',
      stream: false,
      streamIncludeUsage: true,
      topLogprobs: 20,
      logprobs: false,
      safetyCheck: 'low',
    );
    final params = setting.toApiParams();
    expect(params['thinking'], {'type': 'disabled'});
    expect(params.containsKey('reasoning_effort'), isFalse);
    expect(params.containsKey('stream_options'), isFalse);
    expect(params.containsKey('top_logprobs'), isFalse);
    expect(params.containsKey('safety_check'), isFalse);
    expect(params.containsKey('title'), isFalse);
  });

  test('流式请求始终带 include_usage（面板要显示上下文与缓存）', () {
    const setting = UserSetting(stream: true, streamIncludeUsage: false);
    expect(setting.toApiParams()['stream_options'], {'include_usage': true});
  });

  test('reasoning_effort=none 时关闭思考', () {
    const setting = UserSetting(thinking: true, reasoningEffort: 'none');
    final params = setting.toApiParams();
    expect(params['thinking'], {'type': 'disabled'});
    expect(params.containsKey('reasoning_effort'), isFalse);
  });
}
