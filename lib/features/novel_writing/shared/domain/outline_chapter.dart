/// 大纲章节（按事件逐章生成的内容）
class OutlineChapter {
  final int? id;
  final int outlineId;
  final int eventIndex;
  final String eventType; // 'major' | 'minor'
  final String eventTitle;
  final String eventSummary;
  final String content;
  final String status; // 'pending' | 'generating' | 'completed'
  final String aiSummary; // AI 提炼的整章小结（供下一章开头承接）
  final String createdAt;
  final String updatedAt;

  OutlineChapter({
    this.id,
    required this.outlineId,
    required this.eventIndex,
    this.eventType = 'major',
    this.eventTitle = '',
    this.eventSummary = '',
    this.content = '',
    this.status = 'pending',
    this.aiSummary = '',
    String? createdAt,
    String? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  Map<String, dynamic> toMap() => {
    'outline_id': outlineId,
    'event_index': eventIndex,
    'event_type': eventType,
    'event_title': eventTitle,
    'event_summary': eventSummary,
    'content': content,
    'status': status,
    'ai_summary': aiSummary,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory OutlineChapter.fromMap(Map<String, dynamic> map) => OutlineChapter(
    id: map['id'] as int?,
    outlineId: map['outline_id'] as int? ?? 0,
    eventIndex: map['event_index'] as int? ?? 0,
    eventType: map['event_type'] as String? ?? 'major',
    eventTitle: map['event_title'] as String? ?? '',
    eventSummary: map['event_summary'] as String? ?? '',
    content: map['content'] as String? ?? '',
    status: map['status'] as String? ?? 'pending',
    aiSummary: map['ai_summary'] as String? ?? '',
    createdAt: map['created_at'] as String?,
    updatedAt: map['updated_at'] as String?,
  );

  OutlineChapter copyWith({
    int? id,
    int? outlineId,
    int? eventIndex,
    String? eventType,
    String? eventTitle,
    String? eventSummary,
    String? content,
    String? status,
    String? aiSummary,
    String? createdAt,
    String? updatedAt,
  }) =>
      OutlineChapter(
        id: id ?? this.id,
        outlineId: outlineId ?? this.outlineId,
        eventIndex: eventIndex ?? this.eventIndex,
        eventType: eventType ?? this.eventType,
        eventTitle: eventTitle ?? this.eventTitle,
        eventSummary: eventSummary ?? this.eventSummary,
        content: content ?? this.content,
        status: status ?? this.status,
        aiSummary: aiSummary ?? this.aiSummary,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
