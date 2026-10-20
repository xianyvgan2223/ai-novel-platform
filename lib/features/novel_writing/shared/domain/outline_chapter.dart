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
  final String storyState; // 本章生成的剧情账本（每章独立保存，账本页展示最新一章）
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
    this.storyState = '',
    String? createdAt,
    String? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  /// 是否大事件（其余为小事件，界面上显示成「小事件N」）
  bool get isMajor => eventType == 'major';

  Map<String, dynamic> toMap() => {
    'outline_id': outlineId,
    'event_index': eventIndex,
    'event_type': eventType,
    'event_title': eventTitle,
    'event_summary': eventSummary,
    'content': content,
    'status': status,
    'ai_summary': aiSummary,
    'story_state': storyState,
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
    storyState: map['story_state'] as String? ?? '',
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
    String? storyState,
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
        storyState: storyState ?? this.storyState,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 按列表顺序给大事件编号（从 1 开始，**只数大事件**），非大事件对应位置为 null。
///
/// 这个序号与大纲正文里的「大事件N」一致——生成 / 规范化时大事件就是全篇从 1
/// 连续编号（见 outline_event_syntax.dart 的 normalizeOutlineText）。
/// 注意别拿 [OutlineChapter.eventIndex] 当大事件编号：那是**所有**事件的连续
/// 序号，小事件也占号，直接显示会跳号（大事件1、大事件4、大事件9……）。
List<int?> majorEventNumbers(List<OutlineChapter> chapters) {
  final numbers = List<int?>.filled(chapters.length, null);
  var majorSeq = 0;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i].isMajor) numbers[i] = ++majorSeq;
  }
  return numbers;
}

/// 同 [majorEventNumbers]，但返回 chapter.id → 序号，供**只拿到部分章节**的
/// 页面（如「大纲编辑」编辑页只拿到勾选的几章）反查序号用：
/// 这些页面必须按全篇章节列表来查，否则序号会从 1 重新开始。
Map<int, int?> majorEventNumbersById(List<OutlineChapter> chapters) {
  final numbers = majorEventNumbers(chapters);
  final byId = <int, int?>{};
  for (var i = 0; i < chapters.length; i++) {
    final id = chapters[i].id;
    if (id != null) byId[id] = numbers[i];
  }
  return byId;
}

/// 按列表顺序给小事件编号（从 1 开始，**进入下一个大事件就重新计数**），
/// 大事件对应位置为 null。
///
/// 这个序号与大纲正文里的「○ 小事件N」一致——生成 / 规范化时小事件就是
/// 在**每个大事件内部**从 1 重新编号（见 outline_event_syntax.dart 的
/// normalizeOutlineText），不是全篇连续序号。
///
/// 注意别拿 [OutlineChapter.eventIndex] 当小事件编号，也别拿
/// [majorEventNumbers] 那种「只数同类」的全篇连续编号：eventIndex 是所有
/// 事件的连续序号（大事件也占号），直接显示会跳号（小事件1 之后是
/// 小事件5……），与正文里的「○ 小事件1」对不上。
///
/// [chapters] 必须按 [OutlineChapter.eventIndex] 排好序（库里的读取顺序即是）。
List<int?> minorEventNumbers(List<OutlineChapter> chapters) {
  final numbers = List<int?>.filled(chapters.length, null);
  var minorSeq = 0;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i].isMajor) {
      minorSeq = 0; // 进入新的大事件：小事件重新从 1 计数
      continue;
    }
    numbers[i] = ++minorSeq;
  }
  return numbers;
}

/// 同 [minorEventNumbers]，但返回 chapter.id → 序号，供**只拿到部分章节**的
/// 页面（如「大纲编辑」编辑页只拿到勾选的几章）反查序号用：
/// 这些页面必须按全篇章节列表来查，否则小事件序号会从 1 重新开始。
Map<int, int?> minorEventNumbersById(List<OutlineChapter> chapters) {
  final numbers = minorEventNumbers(chapters);
  final byId = <int, int?>{};
  for (var i = 0; i < chapters.length; i++) {
    final id = chapters[i].id;
    if (id != null) byId[id] = numbers[i];
  }
  return byId;
}
