/// 聊天系统提示词与运行环境注记的组装。
///
/// 与 Markdown 无关：模型输出里的 Markdown 由展示层
/// （`presentation/markdown_cleaner.dart`）统一清洗，这里不再写「禁止 Markdown」
/// 的指令——既约束不住模型，又白占系统提示词的空间。
///
/// **缓存优先**：系统提示词里只放跨请求不变的内容（基础提示 + 会话自定义提示）。
/// 当前时间每分钟都会变，一旦放进 system，DeepSeek 的前缀缓存会从时间那一行开始
/// 全部失配，后面整段历史都要按 cache-miss 计费；所以时间按每条用户消息自己的
/// 时间戳追加到消息末尾，重建历史时逐字节一致，前一轮请求才能成为下一轮的前缀。
library;

/// 跨会话、跨请求都不变的基础系统提示。
///
/// 这里不能放时间、用户昵称、会话标题、当前任务等动态内容，否则每次请求都会
/// 从这里开始整段缓存失配。它的作用是给移动端提供一个稳定、可复用的缓存前缀，
/// 同时约束模型的回答语言和事实边界。
const String kChatBaseSystemPrompt =
    '你是 DeepSeek 助手，用中文回答，表达简洁直接。\n'
    '不确定的信息要说明，不要编造事实。';

/// 组装发请求用的 system 内容。
///
/// - [sessionPrompt]：当前会话的自定义提示词（会话设置页填写），非空时追加在
///   基础提示之后。
///
/// 始终返回基础提示，调用方不再需要判断空串。
String buildChatSystemPrompt({required String sessionPrompt}) {
  final custom = sessionPrompt.trim();
  return custom.isEmpty
      ? kChatBaseSystemPrompt
      : '$kChatBaseSystemPrompt\n\n$custom';
}

/// 运行环境注记：按消息时间生成，同一消息每次重建都得到完全相同的文本。
String buildCurrentTimeHint(DateTime now) {
  final weekday = const [
    '星期一',
    '星期二',
    '星期三',
    '星期四',
    '星期五',
    '星期六',
    '星期日',
  ][now.weekday - 1];
  String two(int value) => value.toString().padLeft(2, '0');
  return '【运行环境】当前时间：${now.year}年${now.month}月${now.day}日 '
      '${two(now.hour)}:${two(now.minute)}（$weekday，本地时区）';
}

/// 把某条用户消息的运行环境注记追加到消息末尾。
///
/// 用消息自己的发送时间，而不是 `DateTime.now()`：这样下一轮重建历史时，上一条
/// 用户消息的内容与上一轮请求里发送过的内容逐字节一致，整段历史才能命中前缀缓存。
String runtimeHintedContent(String content, DateTime sentAt) {
  return '$content\n\n${buildCurrentTimeHint(sentAt)}';
}

/// 第二阶段（带搜索结果回答）的消息列表。
///
/// **缓存关键**：直接复用第一阶段已经发送过的消息（含 system、历史、末尾的时间
/// 注记），只在末尾追加一条搜索结果消息。这样第二阶段的提示词前缀与第一阶段
/// 逐字节一致，DeepSeek 才能命中第一阶段已经写好的缓存；千万不能重建历史——
/// 重建会把时间注记丢掉，前缀从最后一条用户消息开始就失配。
List<Map<String, dynamic>> buildSearchAnswerMessages({
  required List<Map<String, dynamic>> phaseOneMessages,
  required String searchContext,
}) {
  return [
    ...phaseOneMessages.map((m) => Map<String, dynamic>.from(m)),
    <String, dynamic>{'role': 'user', 'content': searchContext},
  ];
}
