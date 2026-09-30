import 'outline_event_syntax.dart';

/// 把章节标题 / 概要的修改同步回大纲正文文本。
///
/// 行定位与边界判定统一走 [classifyOutlineLine] / [isOutlineBoundaryLine]，
/// 与 [parseOutlineEvents] 完全一致——历史上这里各写了一份正则副本，副本只认
/// 一位编号，导致「大事件10：」之后的标题/概要改了也写不回大纲正文。
///
/// 定位顺序：
/// 1. 给了 [eventIndex] 就按它找第 N 个事件行，且要求其标题与 [oldTitle] 一致：
///    同一大纲里可能出现多条同名事件，按序号定位才不会改错行；
///    **序号对上位置但标题对不上时不写回**（返回原内容）——说明行结构与库里的
///    序号已经错位（如结构刚增删过），按标题兜底会改到另一条同名事件上；
/// 2. 只有没给 [eventIndex]（调用方拿不到序号）时，才回退按标题首次出现定位。
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
    // 序号命中位置但标题对不上：**必须原样返回**，不能再按标题兜底。
    // 结构刚改动过（增删事件）时序号与大纲正文短暂错位，此时按标题兜底
    // 会去改「另一条同名事件」（甚至完全无关的一条），把别处的大纲改坏；
    // 序号本来就对不上时宁可这次不写回，等下次进入页面按最新结构校正。
  } else {
    // 没有序号可用（调用方未提供）时才按标题首次出现定位
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

/// 第 [n] 个（从 1 开始）事件行在 [lines] 里的下标；不足 [n] 个时返回 null。
/// 与 [parseOutlineEvents] 同一套判别（[classifyOutlineLine]），
/// 因此下标一定与 `OutlineChapter.eventIndex` 对齐。
int? _eventLineAt(List<String> lines, int n) {
  var seen = 0;
  for (var i = 0; i < lines.length; i++) {
    if (!classifyOutlineLine(lines[i]).isEvent) continue;
    seen++;
    if (seen == n) return i;
  }
  return null;
}

/// 最后一个事件行的下标；没有事件行时返回 null
int? _lastEventLine(List<String> lines) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (classifyOutlineLine(lines[i]).isEvent) return i;
  }
  return null;
}

/// 事件块（标题行 + 概要区）的结束下标
int _eventBlockEnd(List<String> lines, int headerAt) {
  var end = headerAt + 1;
  while (end < lines.length && !isOutlineBoundaryLine(lines[end])) {
    end++;
  }
  return end;
}

/// 判断某一行是否已算「有内容」（用于决定是否还要补空行）
bool _blankAt(List<String> lines, int index) =>
    index < 0 || index >= lines.length || lines[index].trim().isEmpty;

/// 在大纲正文里**新增一个事件块**（「大纲编辑」页添加事件用）。
///
/// [eventIndex] 是新事件在**最终结构里的序号（从 1 开始）**：新块插到
/// 该序号对应的那个事件行之前；序号大于现有事件数时追加到末尾。
/// 新块只写标题行，概要留给调用方按同一套规则写回
/// （[mergeEventIntoOutlineText]，见 OutlineEditController.saveAll）。
///
/// 事件行写法统一走 [formatMajorHeader] / [formatMinorHeader]，
/// 与生成侧落库的规范写法完全一致——否则新事件在「大纲转章节」重解析时
/// 认不出来，会直接消失。
///
/// 换行处理（插入点两侧）：上一行不是空行时先补一个空行，避免新标题被
/// 并进上一条事件的概要（**概要区一直读到空行或下一个事件行为止**，
/// 追加到末尾同样必须先断开，否则新事件会被解析成上一条的概要，凭空消失）。
String insertEventIntoOutlineText(
  String content, {
  required int eventIndex,
  required bool isMajor,
  required String title,
}) {
  final lines = content.split('\n');
  final index = eventIndex < 1 ? 1 : eventIndex;
  final target = _eventLineAt(lines, index);

  // 缩进对齐插入点那一行；追加到末尾时对齐**最后一个事件行**而不是最后一行，
  // 否则事件行整体带缩进时，新事件会跟概要的缩进跑偏
  final refAt = target ?? _lastEventLine(lines);
  final indent = refAt == null
      ? 0
      : lines[refAt].length - lines[refAt].trimLeft().length;

  final clean = title.trim();
  final header = isMajor
      ? formatMajorHeader(index, clean)
      : formatMinorHeader(index, clean);
  final block = <String>[' ' * indent + header];

  // 前面已经有内容时先补空行：新事件行必须是「独立事件行」，
  // 贴在上一段概要后面会被当成概要的一部分
  final prevAt = target == null ? lines.length - 1 : target - 1;
  final needLeadingBlank = !_blankAt(lines, prevAt);
  if (needLeadingBlank) block.insert(0, '');
  if (target == null) {
    // 追加到末尾：末尾本来没有空行时，上面补的那一行就是分隔行，
    // 再补一个尾随空行只会多出一行空白
    lines.addAll(block);
  } else {
    // 插到 target 之前：target 不是空行时补一个空行，新块与它才分得开
    if (!_blankAt(lines, target)) block.add('');
    lines.insertAll(target, block);
  }
  return _collapseExcessBlankLines(lines).join('\n');
}

/// 删除大纲正文里第 [eventIndex] 个（从 1 开始）事件块。
///
/// 删掉的是「标题行 + 它的概要区」（到下一个事件 / 幕标题 / 边界行之前），
/// 与 [mergeEventIntoOutlineText] 认定的概要区完全一致，不会多删一行。
/// 序号不存在时原样返回 [content]。
///
/// 收尾**按需要补 / 收空行**，不能只是把块删掉就走：
/// - 两侧原本靠空行分段的（删掉的那块自己没有概要）→ 收掉多出来的空行
/// - 两侧都有内容且都没空行 → 必须补一个空行，否则「上一条的概要」与
///   「下一条的事件行」粘在一起，下一条会被解析成上一条的概要（事件凭空消失）
String removeEventFromOutlineText(String content, int eventIndex) {
  if (eventIndex < 1) return content;
  final lines = content.split('\n');
  final target = _eventLineAt(lines, eventIndex);
  if (target == null) return content;
  final end = _eventBlockEnd(lines, target);
  lines.removeRange(target, end);

  // 先把没内容的空行收干净，再按上面的规则决定要不要补空行
  while (target < lines.length &&
      target > 0 &&
      _blankAt(lines, target - 1) &&
      _blankAt(lines, target)) {
    lines.removeAt(target);
  }
  if (target > 0 && target < lines.length && !_blankAt(lines, target - 1)) {
    // 上面一行有内容（且不是空行）：下面一行必须另有归属，
    // 要么是新的分段（事件行 / 幕标题），要么本来就是空行
    lines.insert(target, '');
  }
  return lines.join('\n');
}

/// 收掉连续空行里多出来的部分（新增事件补空行后可能叠出两行空行）。
/// 只影响空行，任何有内容的行（含缩进）逐字节保持不变。
List<String> _collapseExcessBlankLines(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty && out.isNotEmpty && out.last.trim().isEmpty) {
      continue;
    }
    out.add(line);
  }
  return out;
}
