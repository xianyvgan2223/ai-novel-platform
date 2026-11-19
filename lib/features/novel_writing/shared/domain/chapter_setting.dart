/// 章节写作设置模型（与大纲生成设置完全独立，存于 chapter_settings 表）
class ChapterSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String chapterSystemPrompt;
  final bool enableThinking; // 是否启用深度思考（默认开启）
  final String reasoningEffort; // 思考深度：low / high / max（默认 high）
  final bool enableStoryState; // 是否启用剧情状态账本（默认开启，每章多一次轻量调用）
  final int chapterMinWords; // 单章最少字数（默认 2000）
  final int chapterMaxWords; // 单章最多字数（默认 3000）

  const ChapterSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-flash',
    this.chapterSystemPrompt = '',
    this.enableThinking = true,
    this.reasoningEffort = 'high',
    this.enableStoryState = true,
    this.chapterMinWords = 2000,
    this.chapterMaxWords = 3000,
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'chapter_system_prompt': chapterSystemPrompt,
    'enable_thinking': enableThinking ? 1 : 0,
    'reasoning_effort': reasoningEffort,
    'enable_story_state': enableStoryState ? 1 : 0,
    'chapter_min_words': chapterMinWords,
    'chapter_max_words': chapterMaxWords,
  };

  factory ChapterSetting.fromMap(Map<String, dynamic> map) => ChapterSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-flash',
    chapterSystemPrompt: map['chapter_system_prompt'] as String? ?? '',
    // sqflite 将 INTEGER 列读为 int(0/1)；列缺失（旧库）时默认开启
    enableThinking:
        map['enable_thinking'] == null || (map['enable_thinking'] as int?) == 1,
    reasoningEffort: _normalizeEffort(map['reasoning_effort'] as String?),
    enableStoryState: (map['enable_story_state'] as int?) == 1,
    chapterMinWords: map['chapter_min_words'] as int? ?? 2000,
    chapterMaxWords: map['chapter_max_words'] as int? ?? 3000,
  );

  /// 只接受 DeepSeek 支持的思考深度，旧库/异常值回落到 high。
  static String _normalizeEffort(String? raw) {
    const allowed = {'low', 'high', 'max'};
    final value = (raw ?? '').trim();
    return allowed.contains(value) ? value : 'high';
  }

  ChapterSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? chapterSystemPrompt,
    bool? enableThinking,
    String? reasoningEffort,
    bool? enableStoryState,
    int? chapterMinWords,
    int? chapterMaxWords,
  }) => ChapterSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    chapterSystemPrompt: chapterSystemPrompt ?? this.chapterSystemPrompt,
    enableThinking: enableThinking ?? this.enableThinking,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    enableStoryState: enableStoryState ?? this.enableStoryState,
    chapterMinWords: chapterMinWords ?? this.chapterMinWords,
    chapterMaxWords: chapterMaxWords ?? this.chapterMaxWords,
  );
}
