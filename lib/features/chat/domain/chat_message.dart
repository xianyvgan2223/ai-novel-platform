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

  const ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.thinkingText,
    required this.timestamp,
    this.searchResults,
  });

  /// 是否为用户消息
  bool get isUser => role == MessageRole.user;

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
    );
  }
}
