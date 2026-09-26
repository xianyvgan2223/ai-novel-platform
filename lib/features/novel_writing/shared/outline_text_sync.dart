import 'outline_event_syntax.dart';

/// 把章节标题 / 概要的修改同步回大纲正文文本。
///
/// 行定位与边界判定统一走 [classifyOutlineLine] / [isOutlineBoundaryLine]，
/// 与 [parseOutlineEvents] 完全一致——历史上这里各写了一份正则副本，副本只认
/// 一位编号，导致「大事件10：」之后的标题/概要改了也写不回大纲正文。
///
/// 定位顺序：
/// 1. 优先按 [eventIndex] 找第 N 个事件行，且要求其标题与 [oldTitle] 一致：
///    同一大纲里可能出现多条同名事件，按序号定位才不会改错行；
/// 2. 序号未命中（行结构与数据库尚未对齐）时，回退按标题首次出现定位。
///
/// 命中后替换标题；[newSummary] 重写该事件的概要区
/// （标题行之后、到下一个事件 / 幕标题 / 边界行之前）：
/// - 非空：整段替换为新概要（多行按原缩进逐行写入）
/// - 空串：清空概要区，保证「把概要改空」也能写回大纲文本，
///   不会在下次解析时又翻回旧概要
///
/// [oldTitle] 为空或找不到对应事件时，原样返回 [content]。
String mergeEventIntoOutlineText(
  String content, {
  required String oldTitle,
  required String newTitle,
  required String newSummary,
  int? eventIndex,
}) {
  if (oldTitle.trim().isEmpty) return content;
  final lines = content.split('\n');

  var target = -1;
  if (eventIndex != null && eventIndex > 0) {
    var seen = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = classifyOutlineLine(lines[i]);
      if (!line.isEvent) continue;
      seen++;
      if (seen == eventIndex) {
        if (line.title == oldTitle) target = i;
        break;
      }
    }
  }
  if (target < 0) {
    for (var i = 0; i < lines.length; i++) {
      final line = classifyOutlineLine(lines[i]);
      if (line.isEvent && line.title == oldTitle) {
        target = i;
        break;
      }
    }
  }
  if (target < 0) return content;

  final indent = classifyOutlineLine(lines[target]).indent;
  // 标题为空时保留原标题：否则会写出「大事件1：」这类断行，
  // 下次解析时该行不成立事件行，会被并入上一事件的概要
  final title = newTitle.trim();
  lines[target] = title.isEmpty
      ? ' ' * indent + lines[target].trimLeft()
      : ' ' * indent + lines[target].trimLeft().replaceFirst(oldTitle, title);

  // 概要区：[target + 1, end)
  var end = target + 1;
  while (end < lines.length && !isOutlineBoundaryLine(lines[end])) {
    end++;
  }
  var bodyIndent = indent + 2;
  for (var k = target + 1; k < end; k++) {
    if (lines[k].trim().isNotEmpty) {
      bodyIndent = lines[k].length - lines[k].trimLeft().length;
      break;
    }
  }
  final summary = newSummary.trim();
  final replacement = summary.isEmpty
      ? const <String>[]
      : summary.split('\n').map((l) => ' ' * bodyIndent + l.trim()).toList();
  lines.replaceRange(target + 1, end, replacement);
  return lines.join('\n');
}
