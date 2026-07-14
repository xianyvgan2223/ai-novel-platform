/// 大纲生成设置模型
class OutlineSetting {
  final double temperature;
  final int maxTokens;
  final String model;
  final String systemPrompt;

  const OutlineSetting({
    this.temperature = 0.8,
    this.maxTokens = 4096,
    this.model = 'deepseek-v4-flash',
    this.systemPrompt = '',
  });

  Map<String, dynamic> toMap() => {
    'temperature': temperature,
    'max_tokens': maxTokens,
    'model': model,
    'system_prompt': systemPrompt,
  };

  factory OutlineSetting.fromMap(Map<String, dynamic> map) => OutlineSetting(
    temperature: (map['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: map['max_tokens'] as int? ?? 4096,
    model: map['model'] as String? ?? 'deepseek-v4-flash',
    systemPrompt: map['system_prompt'] as String? ?? '',
  );

  OutlineSetting copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    String? systemPrompt,
  }) => OutlineSetting(
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
  );
}
