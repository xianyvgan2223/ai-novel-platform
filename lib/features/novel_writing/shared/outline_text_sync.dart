/// 把章节标题 / 概要的修改同步回大纲正文文本。
///
/// 事件行定位规则与 [parseOutlineEvents] 保持一致：
/// - 大事件：`大事件N：标题`（可带 `══` 包裹）或 `事件N：标题`
/// - 小事件：`○ / - / • / * / ·` 前缀 + `小事件N：标题`，或直接 `事件N：标题`
///
/// 命中标题行后替换标题；[newSummary] 用于重写该事件的**概要区**
/// （标题行之后、到下一个事件 / 幕标题行之前的内容行）：
/// - 非空：整段替换为新概要（多行按原缩进逐行写入）
/// - 空串：清空概要区，保证「把概要改空」也能写回大纲文本，
///   不会在下次解析时又翻回旧概要
///
/// [oldTitle] 为空或在大纲文本中找不到对应事件时，原样返回 [content]。
String mergeEventIntoOutlineText(
  String content, {
  required String oldTitle,
  required String newTitle,
  required String newSummary,
}) {
  if (oldTitle.trim().isEmpty) return content;
  // 与 parseOutlineEvents 相同的事件 / 幕标题识别
  final majorRe = RegExp(
    r'^\s*═*\s*(?:大事件|Major|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]\s*(.+?)\s*═*\s*$',
  );
  final minorRe = RegExp(
    r'^\s*[○\-•*\·]?\s*(?:小事件|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]\s*(.+?)\s*$',
  );
  final actRe = RegExp(r'^第[一二三四五六0-9]+幕');

  /// 是否概要区边界：解析器在这些行处停止累积概要（含会被跳过的幕标题，
  /// 作为边界保留原行，避免误删）
  bool isBoundary(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('══') && t.endsWith('══')) return true;
    if (t.startsWith('○') || t.startsWith('-')) return true;
    if (actRe.hasMatch(t)) return true;
    return majorRe.hasMatch(t) || minorRe.hasMatch(t);
  }

  final lines = content.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    final majorMatch = majorRe.firstMatch(trimmed);
    // 与解析器一致：先按大事件识别，命中后不再按小事件解释
    final minorMatch = majorMatch == null ? minorRe.firstMatch(trimmed) : null;
    final lineTitle = (majorMatch?.group(1) ?? minorMatch?.group(1))?.trim();
    if (lineTitle == null || lineTitle != oldTitle) continue;

    final indent = lines[i].length - trimmed.length;
    // 标题为空时保留原标题：否则会写出「大事件1：」这类断行，
    // 下次解析时该行不成立事件行，会被并入上一事件的概要
    final targetTitle = newTitle.trim().isEmpty ? oldTitle : newTitle;
    lines[i] = ' ' * indent + trimmed.replaceFirst(oldTitle, targetTitle);
    // 概要区：[i+1, end)
    int end = i + 1;
    while (end < lines.length && !isBoundary(lines[end])) {
      end++;
    }
    var bodyIndent = indent + 2;
    for (int k = i + 1; k < end; k++) {
      if (lines[k].trim().isNotEmpty) {
        bodyIndent = lines[k].length - lines[k].trimLeft().length;
        break;
      }
    }
    final summary = newSummary.trim();
    final replacement = summary.isEmpty
        ? const <String>[]
        : summary
              .split('\n')
              .map((l) => ' ' * bodyIndent + l.trim())
              .toList();
    lines.replaceRange(i + 1, end, replacement);
    break;
  }
  return lines.join('\n');
}
