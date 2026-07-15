/// 大纲生成设置模型
class OutlineSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String systemPrompt;
  final String chapterSystemPrompt;

  // 字数配置
  final int conceptMinWords;    // 核心概念简介最少字数（默认 30）
  final int conceptMaxWords;    // 核心概念简介最多字数（默认 50）
  final int majorEventMinWords; // 大事件概述最少字数（默认 50）
  final int majorEventMaxWords; // 大事件概述最多字数（默认 100）
  final int minorEventMinWords; // 小事件概要最少字数（默认 30）
  final int minorEventMaxWords; // 小事件概要最多字数（默认 50）
  final int summaryMaxWords;    // 人物成长总结最大字数（默认 80）

  const OutlineSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-v4-flash',
    this.systemPrompt = '',
    this.chapterSystemPrompt = '',
    this.conceptMinWords = 30,
    this.conceptMaxWords = 50,
    this.majorEventMinWords = 50,
    this.majorEventMaxWords = 100,
    this.minorEventMinWords = 30,
    this.minorEventMaxWords = 50,
    this.summaryMaxWords = 80,
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'system_prompt': systemPrompt,
    'chapter_system_prompt': chapterSystemPrompt,
    'concept_min_words': conceptMinWords,
    'concept_max_words': conceptMaxWords,
    'major_event_min_words': majorEventMinWords,
    'major_event_max_words': majorEventMaxWords,
    'minor_event_min_words': minorEventMinWords,
    'minor_event_max_words': minorEventMaxWords,
    'summary_max_words': summaryMaxWords,
  };

  factory OutlineSetting.fromMap(Map<String, dynamic> map) => OutlineSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-v4-flash',
    systemPrompt: map['system_prompt'] as String? ?? '',
    chapterSystemPrompt: map['chapter_system_prompt'] as String? ?? '',
    conceptMinWords: map['concept_min_words'] as int? ?? 30,
    conceptMaxWords: map['concept_max_words'] as int? ?? 50,
    majorEventMinWords: map['major_event_min_words'] as int? ?? 50,
    majorEventMaxWords: map['major_event_max_words'] as int? ?? 100,
    minorEventMinWords: map['minor_event_min_words'] as int? ?? 30,
    minorEventMaxWords: map['minor_event_max_words'] as int? ?? 50,
    summaryMaxWords: map['summary_max_words'] as int? ?? 80,
  );

  OutlineSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? systemPrompt,
    String? chapterSystemPrompt,
    int? conceptMinWords,
    int? conceptMaxWords,
    int? majorEventMinWords,
    int? majorEventMaxWords,
    int? minorEventMinWords,
    int? minorEventMaxWords,
    int? summaryMaxWords,
  }) => OutlineSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    chapterSystemPrompt: chapterSystemPrompt ?? this.chapterSystemPrompt,
    conceptMinWords: conceptMinWords ?? this.conceptMinWords,
    conceptMaxWords: conceptMaxWords ?? this.conceptMaxWords,
    majorEventMinWords: majorEventMinWords ?? this.majorEventMinWords,
    majorEventMaxWords: majorEventMaxWords ?? this.majorEventMaxWords,
    minorEventMinWords: minorEventMinWords ?? this.minorEventMinWords,
    minorEventMaxWords: minorEventMaxWords ?? this.minorEventMaxWords,
    summaryMaxWords: summaryMaxWords ?? this.summaryMaxWords,
  );
}
