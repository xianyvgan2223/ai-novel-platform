// lib/models/memo.dart
// 备忘录数据模型

class Memo {
  final int? id;
  final String title;
  final String content;
  final bool isCompleted;
  final MemoPriority priority;
  final String category;
  final DateTime? remindAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Memo({
    this.id,
    required this.title,
    this.content = '',
    this.isCompleted = false,
    this.priority = MemoPriority.medium,
    this.category = '',
    this.remindAt,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'content': content,
      'is_completed': isCompleted ? 1 : 0,
      'priority': priority.name,
      'category': category,
      'remind_at': remindAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Memo.fromMap(Map<String, dynamic> map) {
    return Memo(
      id: map['id'] as int?,
      title: map['title'] as String? ?? '',
      content: map['content'] as String? ?? '',
      isCompleted: (map['is_completed'] as int?) == 1,
      priority: MemoPriority.values.firstWhere(
        (p) => p.name == (map['priority'] as String? ?? 'medium'),
        orElse: () => MemoPriority.medium,
      ),
      category: map['category'] as String? ?? '',
      remindAt: map['remind_at'] != null
          ? DateTime.tryParse(map['remind_at'] as String)
          : null,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Memo copyWith({
    int? id,
    String? title,
    String? content,
    bool? isCompleted,
    MemoPriority? priority,
    String? category,
    DateTime? remindAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Memo(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      isCompleted: isCompleted ?? this.isCompleted,
      priority: priority ?? this.priority,
      category: category ?? this.category,
      remindAt: remindAt ?? this.remindAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

enum MemoPriority { low, medium, high }

extension MemoPriorityExt on MemoPriority {
  String get label {
    switch (this) {
      case MemoPriority.low:
        return '低';
      case MemoPriority.medium:
        return '中';
      case MemoPriority.high:
        return '高';
    }
  }
}
