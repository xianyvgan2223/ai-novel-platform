/// 「大纲编辑」AI 对话消息。
///
/// 助手消息支持流式累积：正文写到 [content]，深度思考过程写到 [thinking]，
/// 生成中 [streaming] 为 true（界面据此显示光标/停止按钮）。
class OutlineEditChatMessage {
  final String role; // 'user' | 'assistant'
  String content;
  String thinking;
  bool streaming;

  OutlineEditChatMessage.user(String text)
      : role = 'user',
        content = text,
        thinking = '',
        streaming = false;

  OutlineEditChatMessage.assistant()
      : role = 'assistant',
        content = '',
        thinking = '',
        streaming = false;

  bool get isUser => role == 'user';

  bool get hasThinking => thinking.trim().isNotEmpty;

  bool get isEmpty => content.trim().isEmpty;
}
