/// lib/models/chat_session.dart
/// 会话实体 — 映射 chat_sessions 表，纯数据实体

class ChatSession {
  final int? id;
  final String title;
  final String createTime;
  final String lastMessage;
  final String systemPrompt; // V5 新增：每个会话独立的系统提示词
  final String summary; // V4 新增：对话历史摘要

  const ChatSession({
    this.id,
    required this.title,
    required this.createTime,
    this.lastMessage = '',
    this.systemPrompt = '',
    this.summary = '',
  });

  /// 实体 → 数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'create_time': createTime,
      'last_message': lastMessage,
      'system_prompt': systemPrompt,
      'summary': summary,
    };
  }

  /// 数据库 Map → 实体
  factory ChatSession.fromMap(Map<String, dynamic> map) {
    return ChatSession(
      id: map['id'] as int?,
      title: map['title'] as String? ?? '',
      createTime: map['create_time'] as String? ?? '',
      lastMessage: map['last_message'] as String? ?? '',
      systemPrompt: map['system_prompt'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
    );
  }

  /// 不可变复制
  ChatSession copyWith({
    int? id,
    String? title,
    String? createTime,
    String? lastMessage,
    String? systemPrompt,
    String? summary,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createTime: createTime ?? this.createTime,
      lastMessage: lastMessage ?? this.lastMessage,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      summary: summary ?? this.summary,
    );
  }
}
