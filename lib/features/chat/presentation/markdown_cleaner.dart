/// 聊天内容的 Markdown → 纯文本清洗。
///
/// 背景：模型输出经常带 Markdown 标记，气泡现在直接按 Markdown 渲染（见
/// chat_markdown.dart）；但「复制」「导出」这类场景更适合纯文本，所以保留
/// 这一层清洗：去掉标记、保留文字与换行结构，复制出去不会带一堆 `**`、
/// `##`、``` ` ```。
///
/// 小说灵感等仍以纯文本展示的页面也继续复用这里的清洗逻辑。
///
/// 只处理聊天里常见的 Markdown 写法，不做完整语法解析。
library;

/// 把模型输出的 Markdown 清洗成适合聊天气泡显示的纯文本。
///
/// 规则（按顺序执行）：
/// - 代码围栏的 ``` 行去掉，围栏里的代码正文保留；
/// - 行内代码的反引号去掉；
/// - `#` 标题、`>` 引用、`---` 分隔线去掉标记；
/// - `- / * / +` 无序列表统一成「• 」；
/// - `**粗体**`、`*斜体*`、`__粗体__`、`~~删除线~~` 去掉包裹符号；
/// - 链接与图片只保留可读文字；
/// - 简单表格的 `|` 换成 ` · ` 分隔；
/// - 反斜杠转义还原、多余空行合并。
String stripMarkdownForChat(String input) {
  if (input.isEmpty) return input;

  var text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  // 先把反斜杠转义（\* / \_ 等）换成占位符，避免被后面的强调规则误删，
  // 全部清洗完再还原成字面符号。
  final escapedChars = <String>[];
  text = text.replaceAllMapped(RegExp(r'\\([\\`*{}\[\]()#+\-.!_>~|])'), (m) {
    escapedChars.add(m[1] ?? '');
    return '\u0000${escapedChars.length - 1}\u0000';
  });

  // 代码围栏行（``` 或 ```dart）去掉，围栏内的代码正文保留
  text = text.replaceAll(RegExp(r'^[ \t]*```[^\n]*$', multiLine: true), '');

  // 行内代码 `code` → code
  text = text.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1] ?? '');

  // 分隔线 --- / *** / ___ 整行去掉（连同换行，避免留下空行）
  text = text.replaceAll(
    RegExp(r'^[ \t]{0,3}(?:[-*_][ \t]*){3,}[ \t]*\n?', multiLine: true),
    '',
  );

  // 标题 # ... → 去掉 # 前缀
  text = text.replaceAll(
    RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+', multiLine: true),
    '',
  );

  // 引用 > ... → 去掉 >
  text = text.replaceAll(RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true), '');

  // 无序列表 - / * / + → •
  text = text.replaceAllMapped(
    RegExp(r'^([ \t]*)[-*+][ \t]+', multiLine: true),
    (m) => '${m[1]}• ',
  );

  // 粗体 / 斜体 / 删除线：优先匹配三连、双连标记，再匹配单个 *（单个 _ 不处理，
  // 避免把 snake_case 这类标识符误伤）
  text = text.replaceAllMapped(
    RegExp(r'(\*\*\*|\*\*|__|~~|\*)([^\n]+?)\1'),
    (m) => m[2] ?? '',
  );

  // 图片 / 链接：[文字](url) → 文字；文字为空时保留 url
  text = text.replaceAllMapped(RegExp(r'!?\[([^\]\n]*)\]\(([^)\n]+)\)'), (m) {
    final label = (m[1] ?? '').trim();
    final url = (m[2] ?? '').trim();
    if (label.isEmpty || label == url) return url;
    return label;
  });

  // 简单表格：| a | b | → a · b；| --- | --- | 分隔行整行去掉
  text = _cleanTables(text);

  // 还原反斜杠转义（\* → * 等）
  text = text.replaceAllMapped(
    RegExp(r'\u0000(\d+)\u0000'),
    (m) => escapedChars[int.tryParse(m[1] ?? '') ?? 0] ?? '',
  );

  // 行尾空白与过多空行
  text = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+$'), ''))
      .join('\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 表格清洗：只处理「整行以 | 开头、以 | 结尾且至少两列」的行。
String _cleanTables(String text) {
  final out = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    final isTableRow =
        trimmed.startsWith('|') &&
        trimmed.endsWith('|') &&
        '|'.allMatches(trimmed).length >= 3;
    if (!isTableRow) {
      out.add(line);
      continue;
    }
    final cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((c) => c.trim())
        .toList();
    // 分隔行（| --- | :---: |）整行丢掉
    final isSeparator =
        cells.isNotEmpty &&
        cells.every((c) => c.isEmpty || RegExp(r'^:?-{2,}:?$').hasMatch(c));
    if (isSeparator) continue;
    final kept = cells.where((c) => c.isNotEmpty).toList();
    if (kept.isEmpty) continue;
    out.add(kept.join(' · '));
  }
  return out.join('\n');
}
