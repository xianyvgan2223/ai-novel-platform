/// 大纲生成记录模型
class OutlineRecord {
  final int? id;
  final String title;
  final String genre;
  final String theme;
  final String protagonist;
  final String content;
  final String createdAt;

  OutlineRecord({
    this.id,
    this.title = '',
    this.genre = '',
    this.theme = '',
    this.protagonist = '',
    this.content = '',
    String? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String();

  Map<String, dynamic> toMap() => {
    'title': title,
    'genre': genre,
    'theme': theme,
    'protagonist': protagonist,
    'content': content,
    'created_at': createdAt,
  };

  factory OutlineRecord.fromMap(Map<String, dynamic> map) => OutlineRecord(
    id: map['id'] as int?,
    title: map['title'] as String? ?? '',
    genre: map['genre'] as String? ?? '',
    theme: map['theme'] as String? ?? '',
    protagonist: map['protagonist'] as String? ?? '',
    content: map['content'] as String? ?? '',
    createdAt: map['created_at'] as String?,
  );

  /// 格式化的创建时间（仅日期部分）
  String get formattedDate {
    try {
      final dt = DateTime.parse(createdAt);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return createdAt;
    }
  }
}
