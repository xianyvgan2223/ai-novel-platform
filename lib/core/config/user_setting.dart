/// lib/models/user_setting.dart
/// 用户设置模型 — 映射 user_settings 表，纯数据实体，无业务逻辑

class UserSetting {
  static const int maxTokensMax = 384000;

  // ── 联网搜索来源 ──

  /// 百度千帆 AI 搜索（当前唯一可用来源）
  static const String searchEngineBaidu = 'baidu';

  /// 关闭联网搜索
  static const String searchEngineOff = 'off';

  /// DeepSeek 官方 API「自带搜索」（预留位，见 db V35→V36 迁移注释）
  static const String searchEngineDeepseek = 'deepseek';

  final int? id;
  final String model;
  final String apiKey;
  final double temperature;
  final double topP;
  final int maxTokens;
  final String stop;
  final bool stream;
  final String streamOptions;
  final double frequencyPenalty;
  final double presencePenalty;
  final String responseFormat;
  final bool thinking;
  final bool logprobs;
  final int topLogprobs;
  final String logitBias;
  final int n;
  final String reasoningContent;
  final int contextRounds;
  final String systemPrompt;
  final bool webSearch;
  final String baiduApiKey;
  final int searchCount;
  final String searchFreshness;

  /// 联网搜索来源：仅 [searchEngineBaidu] 真正可用。
  ///
  /// 保留此字段是为了让设置项能表达「想用哪个来源」，并给将来官方开放
  /// 自带搜索留出通路 —— 实测结论见 db V35→V36 迁移处的注释。
  final String searchEngine;

  const UserSetting({
    this.id,
    this.model = 'deepseek-flash',
    this.apiKey = '',
    this.temperature = 1.0,
    this.topP = 1.0,
    this.maxTokens = 4096,
    this.stop = '',
    this.stream = true,
    this.streamOptions = '',
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.responseFormat = 'text',
    this.thinking = false,
    this.logprobs = false,
    this.topLogprobs = 0,
    this.logitBias = '',
    this.n = 1,
    this.reasoningContent = '',
    this.contextRounds = 10,
    this.systemPrompt = '',
    this.webSearch = false,
    this.baiduApiKey = '',
    this.searchCount = 5,
    this.searchFreshness = '',
    this.searchEngine = searchEngineBaidu,
  });

  /// 实体 → 数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'model': model,
      'apiKey': apiKey,
      'temperature': temperature,
      'top_p': topP,
      'max_tokens': maxTokens,
      'stop': stop,
      'stream': stream ? 1 : 0,
      'stream_options': streamOptions,
      'frequency_penalty': frequencyPenalty,
      'presence_penalty': presencePenalty,
      'response_format': responseFormat,
      'thinking': thinking ? 1 : 0,
      'logprobs': logprobs ? 1 : 0,
      'top_logprobs': topLogprobs,
      'logit_bias': logitBias,
      'n': n,
      'reasoning_content': reasoningContent,
      'context_rounds': contextRounds,
      'system_prompt': systemPrompt,
      'web_search': webSearch ? 1 : 0,
      'baidu_api_key': baiduApiKey,
      'search_count': searchCount,
      'search_freshness': searchFreshness,
      'search_engine': searchEngine,
    };
  }

  /// 数据库 Map → 实体
  factory UserSetting.fromMap(Map<String, dynamic> map) {
    return UserSetting(
      id: map['id'] as int?,
      model: map['model'] as String? ?? 'deepseek-flash',
      apiKey: map['apiKey'] as String? ?? '',
      temperature: (map['temperature'] as num?)?.toDouble() ?? 1.0,
      topP: (map['top_p'] as num?)?.toDouble() ?? 1.0,
      maxTokens: map['max_tokens'] as int? ?? 4096,
      stop: map['stop'] as String? ?? '',
      stream: (map['stream'] as int?) == 1,
      streamOptions: map['stream_options'] as String? ?? '',
      frequencyPenalty: (map['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      presencePenalty: (map['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      responseFormat: map['response_format'] as String? ?? 'text',
      thinking: (map['thinking'] as int?) == 1,
      logprobs: (map['logprobs'] as int?) == 1,
      topLogprobs: map['top_logprobs'] as int? ?? 0,
      logitBias: map['logit_bias'] as String? ?? '',
      n: map['n'] as int? ?? 1,
      reasoningContent: map['reasoning_content'] as String? ?? '',
      contextRounds: map['context_rounds'] as int? ?? 10,
      systemPrompt: map['system_prompt'] as String? ?? '',
      webSearch: (map['web_search'] as int?) == 1,
      baiduApiKey: map['baidu_api_key'] as String? ?? '',
      searchCount: map['search_count'] as int? ?? 5,
      searchFreshness: map['search_freshness'] as String? ?? '',
      searchEngine: map['search_engine'] as String? ?? searchEngineBaidu,
    );
  }

  /// 不可变复制，支持部分字段覆盖
  UserSetting copyWith({
    int? id,
    String? model,
    String? apiKey,
    double? temperature,
    double? topP,
    int? maxTokens,
    String? stop,
    bool? stream,
    String? streamOptions,
    double? frequencyPenalty,
    double? presencePenalty,
    String? responseFormat,
    bool? thinking,
    bool? logprobs,
    int? topLogprobs,
    String? logitBias,
    int? n,
    String? reasoningContent,
    int? contextRounds,
    String? systemPrompt,
    bool? webSearch,
    String? baiduApiKey,
    int? searchCount,
    String? searchFreshness,
    String? searchEngine,
  }) {
    return UserSetting(
      id: id ?? this.id,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
      stop: stop ?? this.stop,
      stream: stream ?? this.stream,
      streamOptions: streamOptions ?? this.streamOptions,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      responseFormat: responseFormat ?? this.responseFormat,
      thinking: thinking ?? this.thinking,
      logprobs: logprobs ?? this.logprobs,
      topLogprobs: topLogprobs ?? this.topLogprobs,
      logitBias: logitBias ?? this.logitBias,
      n: n ?? this.n,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      contextRounds: contextRounds ?? this.contextRounds,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      webSearch: webSearch ?? this.webSearch,
      baiduApiKey: baiduApiKey ?? this.baiduApiKey,
      searchCount: searchCount ?? this.searchCount,
      searchFreshness: searchFreshness ?? this.searchFreshness,
      searchEngine: searchEngine ?? this.searchEngine,
    );
  }

  /// 快速转换为 DeepSeek API 请求参数（不含 messages）
  Map<String, dynamic> toApiParams() {
    final params = <String, dynamic>{
      'model': model,
      'temperature': temperature,
      'top_p': topP,
      'max_tokens': maxTokens,
      'stream': stream,
      'frequency_penalty': frequencyPenalty,
      'presence_penalty': presencePenalty,
    };

    // stop：逗号分隔字符串 → 数组
    if (stop.trim().isNotEmpty) {
      params['stop'] = stop.split(',').map((s) => s.trim()).toList();
    }

    // stream_options：非空时解析为 JSON
    if (streamOptions.trim().isNotEmpty) {
      params['stream_options'] = streamOptions;
    }

    // response_format：非 text 时传入
    if (responseFormat != 'text') {
      params['response_format'] = {'type': responseFormat};
    }

    // 深度推理（V1.3.5 修复：关时显式禁用，避免 API 默认启用）
    params['thinking'] = thinking ? {'type': 'enabled'} : {'type': 'disabled'};

    // 调试参数
    if (logprobs) params['logprobs'] = true;
    if (topLogprobs > 0) params['top_logprobs'] = topLogprobs;
    if (logitBias.trim().isNotEmpty) {
      params['logit_bias'] = logitBias;
    }
    if (n > 1) params['n'] = n;

    return params;
  }
}
