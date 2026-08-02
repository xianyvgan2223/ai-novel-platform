/// 大纲生成记录模型
class OutlineRecord {
  final int? id;
  final String title;
  final String genre;
  final String theme;
  final String protagonist;
  final String worldview;
  final String content;
  final String foreshadows; // 伏笔清单（一键生成时的账本，供章节写作注入）
  final String storyState; // 剧情状态账本（随章节写作逐步累积）
  final String characters; // 人物档案 JSON（描述/能力/性格，性格仅用户可改）
  final String createdAt;

  OutlineRecord({
    this.id,
    this.title = '',
    this.genre = '',
    this.theme = '',
    this.protagonist = '',
    this.worldview = '',
    this.content = '',
    this.foreshadows = '',
    this.storyState = '',
    this.characters = '',
    String? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toIso8601String();

  Map<String, dynamic> toMap() => {
    'title': title,
    'genre': genre,
    'theme': theme,
    'protagonist': protagonist,
    'worldview': worldview,
    'content': content,
    'foreshadows': foreshadows,
    'story_state': storyState,
    'characters': characters,
    'created_at': createdAt,
  };

  factory OutlineRecord.fromMap(Map<String, dynamic> map) => OutlineRecord(
    id: map['id'] as int?,
    title: map['title'] as String? ?? '',
    genre: map['genre'] as String? ?? '',
    theme: map['theme'] as String? ?? '',
    protagonist: map['protagonist'] as String? ?? '',
    worldview: map['worldview'] as String? ?? '',
    content: map['content'] as String? ?? '',
    foreshadows: map['foreshadows'] as String? ?? '',
    storyState: map['story_state'] as String? ?? '',
    characters: map['characters'] as String? ?? '',
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
