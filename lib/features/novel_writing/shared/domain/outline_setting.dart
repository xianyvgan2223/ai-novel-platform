/// 大纲生成设置模型（与章节写作设置完全独立，存于 outline_settings 表）
class OutlineSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String systemPrompt;
  final bool enableThinking; // 是否启用深度思考（默认开启）

  const OutlineSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-v4-flash',
    this.systemPrompt = '',
    this.enableThinking = true,
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'system_prompt': systemPrompt,
    'enable_thinking': enableThinking ? 1 : 0,
  };

  factory OutlineSetting.fromMap(Map<String, dynamic> map) => OutlineSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-v4-flash',
    systemPrompt: map['system_prompt'] as String? ?? '',
    // sqflite 将 INTEGER 列读为 int(0/1)；列缺失（旧库）时默认开启
    enableThinking:
        map['enable_thinking'] == null || (map['enable_thinking'] as int?) == 1,
  );

  OutlineSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? systemPrompt,
    bool? enableThinking,
  }) => OutlineSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    enableThinking: enableThinking ?? this.enableThinking,
  );
}
