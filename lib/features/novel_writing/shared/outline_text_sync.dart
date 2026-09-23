/// 把章节标题 / 概要的修改同步回大纲正文文本。
///
/// 事件行定位规则与 [parseOutlineEvents] 保持一致：
/// - 大事件：`══` 开头且结尾为 `══` 的标题行
/// - 小事件：以 `○` 开头的标题行
///
/// 命中标题行后替换标题；[newSummary] 非空时，继续向下找到第一个非空内容行
/// 写入新概要（小事件标题行后常跟空行，必须跳过，否则概要修改不生效）。
/// [newTitle] 与原文本不一致时同步替换，保证「大纲转章节」重解析时
/// 不会因标题对不上而回退章节标题。
/// [oldTitle] 为空或在大纲文本中找不到对应事件时，原样返回 [content]。
String mergeEventIntoOutlineText(
  String content, {
  required String oldTitle,
  required String newTitle,
  required String newSummary,
}) {
  if (oldTitle.trim().isEmpty) return content;
  final lines = content.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('══') &&
        trimmed.contains(oldTitle) &&
        trimmed.endsWith('══')) {
      final newLine = trimmed.replaceFirst(oldTitle, newTitle);
      final indent = lines[i].length - lines[i].trimLeft().length;
      lines[i] = ' ' * indent + newLine.trimLeft();
      if (newSummary.isNotEmpty) {
        for (int j = i + 1; j < lines.length; j++) {
          final t = lines[j].trimLeft();
          if (t.startsWith('══') || t.startsWith('○') || t.startsWith('-')) break;
          if (t.isNotEmpty) {
            final indent2 = lines[j].length - lines[j].trimLeft().length;
            lines[j] = ' ' * indent2 + newSummary;
            break;
          }
        }
      }
      break;
    }
    if (trimmed.startsWith('○') && trimmed.contains(oldTitle)) {
      final newLine = trimmed.replaceFirst(oldTitle, newTitle);
      final indent = lines[i].length - lines[i].trimLeft().length;
      lines[i] = ' ' * indent + newLine.trimLeft();
      // 概要替换：小事件标题行后常跟空行（实际格式），需跳过空行
      // 找到第一个非空内容行再替换，否则概要修改不会写回大纲文本
      if (newSummary.isNotEmpty) {
        for (int j = i + 1; j < lines.length; j++) {
          final t = lines[j].trimLeft();
          if (t.startsWith('══') || t.startsWith('○') || t.startsWith('-')) break;
          if (t.isNotEmpty) {
            final indent2 = lines[j].length - lines[j].trimLeft().length;
            lines[j] = ' ' * indent2 + newSummary;
            break;
          }
        }
      }
      break;
    }
  }
  return lines.join('\n');
}
