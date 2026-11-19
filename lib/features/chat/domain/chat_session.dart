/// lib/models/chat_session.dart
/// 会话实体 — 映射 chat_sessions 表，纯数据实体

class ChatSession {
  final int? id;
  final String title;
  final String createTime;
  final String lastMessage;
  final String systemPrompt; // V5 新增：每个会话独立的系统提示词
  final String summary; // V4 新增：对话历史摘要（DSH 式检查点）
  final int summaryCount; // 已被摘要覆盖的消息条数（从会话开头算）
  final int contextTokens; // 上次请求的精确 prompt_tokens
  final int cachedTokens; // 上次请求命中的缓存 token 数
  final int contextWindow; // 上次请求使用的上下文窗口
  final int totalPromptTokens; // 本会话累计输入 token（Σ 所有请求）
  final int totalCachedTokens; // 本会话累计缓存命中 token

  const ChatSession({
    this.id,
    required this.title,
    required this.createTime,
    this.lastMessage = '',
    this.systemPrompt = '',
    this.summary = '',
    this.summaryCount = 0,
    this.contextTokens = 0,
    this.cachedTokens = 0,
    this.contextWindow = 0,
    this.totalPromptTokens = 0,
    this.totalCachedTokens = 0,
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
      'summary_count': summaryCount,
      'context_tokens': contextTokens,
      'cached_tokens': cachedTokens,
      'context_window': contextWindow,
      'total_prompt_tokens': totalPromptTokens,
      'total_cached_tokens': totalCachedTokens,
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
      summaryCount: map['summary_count'] as int? ?? 0,
      contextTokens: map['context_tokens'] as int? ?? 0,
      cachedTokens: map['cached_tokens'] as int? ?? 0,
      contextWindow: map['context_window'] as int? ?? 0,
      totalPromptTokens: map['total_prompt_tokens'] as int? ?? 0,
      totalCachedTokens: map['total_cached_tokens'] as int? ?? 0,
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
    int? summaryCount,
    int? contextTokens,
    int? cachedTokens,
    int? contextWindow,
    int? totalPromptTokens,
    int? totalCachedTokens,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createTime: createTime ?? this.createTime,
      lastMessage: lastMessage ?? this.lastMessage,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      summary: summary ?? this.summary,
      summaryCount: summaryCount ?? this.summaryCount,
      contextTokens: contextTokens ?? this.contextTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      contextWindow: contextWindow ?? this.contextWindow,
      totalPromptTokens: totalPromptTokens ?? this.totalPromptTokens,
      totalCachedTokens: totalCachedTokens ?? this.totalCachedTokens,
    );
  }
}
