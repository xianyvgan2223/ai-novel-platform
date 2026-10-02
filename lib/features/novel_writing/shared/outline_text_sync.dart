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

/// 两条事件标题是否指同一条：去掉两端空白，并剥掉标题里嵌套的
/// 「大事件N：」/「小事件N：」前缀后比较。
///
/// 为什么不能直接比字符串：生成侧写进正文的是**剥过前缀**的标题
/// （[formatMajorHeader] / [formatMinorHeader]），而界面上卡片里的标题可能是
/// 用户手输的原样（带前缀），直接比会把同一条判成两条。
bool _sameEventTitle(String a, String b) {
  final x = stripNestedEventPrefix(a);
  final y = stripNestedEventPrefix(b);
  return x.isNotEmpty && x == y;
}

/// 标题命中 [titles] 之一、且类型符合 [requireMajor]（为 null 时不限）的事件行里，
/// **离第 [nearIndex] 个事件最近**的一条的下标（从 0 开始）；没有时返回 null。
///
/// [titles] 按优先级排列：前一个候选能找到就不再试后面的——
/// 候选顺序是「正文里现在写着的标题 → 界面上现在显示的标题」，
/// 前者才是正文那一行的真实身份。
/// [nearIndex] 是调用方手里的序号，用来在**同名多条**之间取最像的那一条
/// （界面上的第 N 条，通常就是正文里的第 N 条附近）。
int? _eventLineAtAnyTitle(
  List<String> lines,
  List<String> titles,
  int nearIndex, {
  bool? requireMajor,
}) {
  final wanted = titles
      .map((t) => stripNestedEventPrefix(t))
      .where((t) => t.isNotEmpty)
      .toList();
  if (wanted.isEmpty) return null;
  for (final want in wanted) {
    int? best;
    var bestDistance = 0;
    var seen = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = classifyOutlineLine(lines[i]);
      if (!line.isEvent) continue;
      seen++;
      if (requireMajor != null && line.isMajor != requireMajor) continue;
      if (!_sameEventTitle(line.title, want)) continue;
      final distance = (seen - nearIndex).abs();
      if (best == null || distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    if (best != null) return best;
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

/// 大纲正文里的事件总数（大事件 + 小事件）
int countOutlineEvents(String content) {
  var n = 0;
  for (final raw in content.split('\n')) {
    if (classifyOutlineLine(raw).isEvent) n++;
  }
  return n;
}

/// 把一串卡片标题映射成它们在大纲正文里的**事件序号**（从 1 开始，全局）。
///
/// 返回的列表与 [titles] 等长；找不到对应事件行的项为 null。
///
/// 「大纲编辑」页可以只勾选其中几章（「编辑该章」/「编辑所选（N）」），
/// 这时草稿列表里的第 N 张卡片**不是**正文里的第 N 个事件——拿草稿下标当序号去
/// 插 / 删 / 重编号，新事件会被插到整篇大纲的最前面、选中行会被改成 1、2……
/// 与其余章节撞号（现象就是「我原来写的大事件被新加的那条顶掉了」）。
/// 草稿顺序与正文顺序一致（上一页整表按正文解析入库），所以**按顺序往下找**：
/// 每一项从上一项命中的位置之后继续，同名多条也能一一对上，不会串行。
List<int?> locateEventOrdinals(String content, List<String> titles) {
  final result = List<int?>.filled(titles.length, null);
  var ordinal = 0;
  var i = 0;
  for (final raw in content.split('\n')) {
    final line = classifyOutlineLine(raw);
    if (!line.isEvent) continue;
    ordinal++;
    if (i >= titles.length) break;
    final want = stripNestedEventPrefix(titles[i]);
    if (want.isEmpty) {
      // 标题是空的（用户把标题清掉了）：认不出是哪一条，跳过它继续找后面的，
      // 不然后面每一张卡片都会被判成「找不到」
      i++;
      continue;
    }
    if (!_sameEventTitle(line.title, want)) continue;
    result[i] = ordinal;
    i++;
  }
  return result;
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
/// [expectTitles] / [expectMajor] 是这一条在**界面上的身份**（标题候选 + 大/小事件），
/// 传了就先核对第 [eventIndex] 个事件行是不是它：
/// - 是 → 按序号删（正常路径）；
/// - 不是 → 说明库里的序号与正文已经错位（历史上「章节选择页拿旧快照校正结构」
///   把删掉的事件插回来过），此时**只按标题**找离该序号最近的一条，
///   一条都对不上就原样返回。
///
/// 为什么不能一律按序号硬删：用户点的是「删掉这一条」，序号错位时硬删会把
/// **旁边那条**从大纲里抹掉——现象正是「删了这个小事件，它自己还在、
/// 别的事件反而没了」，比这次不删更糟。所以只在认得出来时才动正文。
///
/// 收尾**按需要补 / 收空行**，不能只是把块删掉就走：
/// - 两侧原本靠空行分段的（删掉的那块自己没有概要）→ 收掉多出来的空行
/// - 两侧都有内容且都没空行 → 必须补一个空行，否则「上一条的概要」与
///   「下一条的事件行」粘在一起，下一条会被解析成上一条的概要（事件凭空消失）
String removeEventFromOutlineText(
  String content,
  int eventIndex, {
  List<String>? expectTitles,
  bool? expectMajor,
}) {
  if (eventIndex < 1) return content;
  final lines = content.split('\n');
  var target = _eventLineAt(lines, eventIndex);

  final titles = (expectTitles ?? const <String>[])
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (titles.isNotEmpty) {
    final here = target == null ? null : classifyOutlineLine(lines[target]);
    final hit =
        here != null &&
        here.isEvent &&
        (expectMajor == null || here.isMajor == expectMajor) &&
        titles.any((t) => _sameEventTitle(here.title, t));
    if (!hit) {
      target = _eventLineAtAnyTitle(
        lines,
        titles,
        eventIndex,
        requireMajor: expectMajor,
      );
    }
  }

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
