/// lib/models/chat_message.dart
/// 单条消息实体 — 内存中用，不直接映射数据库表，用于对话上下文拼接

enum MessageRole { user, assistant }

class ChatMessage {
  final int? id; // 数据库主键，null 表示尚未持久化
  final MessageRole role;
  final String content;
  final String? thinkingText; // 助手消息的思考过程内容
  final String timestamp;
  final List<Map<String, dynamic>>? searchResults; // 联网搜索结果
  final int promptTokens; // 产生这条回答的那次请求的 prompt_tokens
  final int cachedTokens; // 那次请求命中的缓存 token
  final int completionTokens; // 那次请求的输出 token

  const ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.thinkingText,
    required this.timestamp,
    this.searchResults,
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.completionTokens = 0,
  });

  /// 是否为用户消息
  bool get isUser => role == MessageRole.user;

  /// 这条回答自己的缓存命中率（0-100）；没有记录 usage 时返回 null
  int? get cachePercent {
    if (promptTokens <= 0) return null;
    final value = (cachedTokens * 100 / promptTokens).round();
    return value > 100 ? 100 : value;
  }

  /// 转换为 API 所需的消息格式 [{"role": "...", "content": "..."}]
  Map<String, String> toApiMessage() {
    return {'role': isUser ? 'user' : 'assistant', 'content': content};
  }

  /// 复制并更新 id
  ChatMessage copyWith({int? id}) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content,
      thinkingText: thinkingText,
      timestamp: timestamp,
      searchResults: searchResults,
      promptTokens: promptTokens,
      cachedTokens: cachedTokens,
      completionTokens: completionTokens,
    );
  }
}
