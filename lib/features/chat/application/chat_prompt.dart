/// 聊天系统提示词组装。
///
/// 与 Markdown 无关：模型输出里的 Markdown 由展示层
/// （`presentation/markdown_cleaner.dart`）统一清洗，这里不再写「禁止 Markdown」
/// 的指令——既约束不住模型，又白占系统提示词的空间。
///
/// 联网搜索开启时注入当前时间：搜索结果和用户问题经常带「今天 / 最近 / 最新」，
/// 模型自己不知道现在是几号；系统提示词里补上准确时间后，时效性回答才可靠。
library;

/// 组装发请求用的 system 内容。
///
/// - [sessionPrompt]：当前会话的自定义提示词（会话设置页填写），为空则不注入；
/// - [searchEnabled]：联网搜索是否开启，开启时追加「当前时间」段落；
/// - [now]：当前时间（测试可注入固定值）。
///
/// 两者都没有时返回空串，调用方应跳过 system 消息插入。
String buildChatSystemPrompt({
  required String sessionPrompt,
  required bool searchEnabled,
  DateTime? now,
}) {
  final parts = <String>[];
  final prompt = sessionPrompt.trim();
  if (prompt.isNotEmpty) parts.add(prompt);
  if (searchEnabled) parts.add(buildCurrentTimeHint(now ?? DateTime.now()));
  return parts.join('\n\n');
}

/// 联网搜索开启时注入的当前时间提示。
///
/// 只注入时间本身，不附加「请以该时间为准」之类的行为指令：模型对系统提示词
/// 里的额外要求比较敏感，多一句话反而可能干扰它正常回答。
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
  return '当前时间：${now.year}年${now.month}月${now.day}日 '
      '${two(now.hour)}:${two(now.minute)}（$weekday，本地时区）';
}
