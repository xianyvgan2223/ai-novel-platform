/// 大纲生成设置模型（与章节写作设置完全独立，存于 outline_settings 表）
class OutlineSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String systemPrompt;
  final bool enableThinking; // 是否启用深度思考（默认开启）
  final bool pauseAfterSkeleton; // 粗骨架生成完成后暂停检查点，等待手动继续
  final bool pauseAfterEvents; // 大事件精写完成后暂停检查点，等待手动继续

  const OutlineSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-v4-flash',
    this.systemPrompt = '',
    this.enableThinking = true,
    this.pauseAfterSkeleton = false,
    this.pauseAfterEvents = false,
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'system_prompt': systemPrompt,
    'enable_thinking': enableThinking ? 1 : 0,
    'pause_after_skeleton': pauseAfterSkeleton ? 1 : 0,
    'pause_after_events': pauseAfterEvents ? 1 : 0,
  };

  factory OutlineSetting.fromMap(Map<String, dynamic> map) => OutlineSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-v4-flash',
    systemPrompt: map['system_prompt'] as String? ?? '',
    // sqflite 将 INTEGER 列读为 int(0/1)；列缺失（旧库）时默认开启
    enableThinking:
        map['enable_thinking'] == null || (map['enable_thinking'] as int?) == 1,
    // 检查点开关默认关闭
    pauseAfterSkeleton: (map['pause_after_skeleton'] as int?) == 1,
    pauseAfterEvents: (map['pause_after_events'] as int?) == 1,
  );

  OutlineSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? systemPrompt,
    bool? enableThinking,
    bool? pauseAfterSkeleton,
    bool? pauseAfterEvents,
  }) => OutlineSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    enableThinking: enableThinking ?? this.enableThinking,
    pauseAfterSkeleton: pauseAfterSkeleton ?? this.pauseAfterSkeleton,
    pauseAfterEvents: pauseAfterEvents ?? this.pauseAfterEvents,
  );
}
