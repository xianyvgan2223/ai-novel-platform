import '../../shared/outline_event_syntax.dart';

/// 大纲正文里一处命中。
///
/// [line]/[start]/[end] 是**原始行**上的坐标（不是标题或概要子串上的），
/// 因此可以直接按位置回写——标题行前后的 `══` / `##` / `○` 等装饰、行首缩进、
/// 概要区缩进全部原样保留，不靠「重新格式化一遍」去猜。
class OutlineTextOccurrence {
  /// 命中所在行在正文里的下标（从 0 开始）
  final int line;

  /// 命中起点（含）
  final int start;

  /// 命中终点（不含）
  final int end;

  /// 命中的原文（用于显示「实际替换掉的文字」）
  final String matched;

  /// 命中处左右的上下文（各最多 8 字），列表里一眼能看出改的是哪一句
  final String context;

  const OutlineTextOccurrence({
    required this.line,
    required this.start,
    required this.end,
    required this.matched,
    required this.context,
  });
}

/// 大纲正文里一个事件（标题行 + 它的概要区）的索引项。
class OutlineEventText {
  /// 事件在整个大纲里的序号（从 1 开始），与 `OutlineChapter.eventIndex` 对齐
  final int index;

  /// 是否大事件
  final bool isMajor;

  /// 事件标题（已剥掉「大事件N：」前缀与装饰）
  final String title;

  /// 标题行的行号
  final int headerLine;

  /// 标题整体在原始行上的区间（不含行首缩进与 `══` / `○` 等装饰）
  final int titleStart;
  final int titleEnd;

  /// 概要区的行号范围 `[start, end)`（不含任何边界行）
  final int bodyStart;
  final int bodyEnd;

  const OutlineEventText({
    required this.index,
    required this.isMajor,
    required this.title,
    required this.headerLine,
    required this.titleStart,
    required this.titleEnd,
    required this.bodyStart,
    required this.bodyEnd,
  });
}

/// 某条大纲正文的**事件索引**：把「第几个事件」映射到具体的行区间。
///
/// 改名功能必须知道「这一处命中属于哪个事件」，否则说不清「会影响哪些事件」，
/// 用户也不敢点下「替换」。索引只做只读扫描，不改文本。
class OutlineTextIndex {
  /// 原始正文
  final String content;

  /// 行数组（与 [content] 按 `\n` 切分的结果一致）
  final List<String> lines;

  /// 按顺序排列的事件
  final List<OutlineEventText> events;

  const OutlineTextIndex._(this.content, this.lines, this.events);

  /// 扫描一遍大纲正文，建立事件索引
  factory OutlineTextIndex.of(String content) {
    final lines = content.split('\n');
    final headerLines = <int>[];
    final headerTitles = <String>[];
    final headerMajors = <bool>[];
    final titleRanges = <(int, int)>[];

    for (var i = 0; i < lines.length; i++) {
      final line = classifyOutlineLine(lines[i]);
      if (!line.isEvent) continue;
      // 按标题文字在本行内定位：classifyOutlineLine 抠出来的标题已剥装饰、已 trim，
      // 它在行内的首次出现就是标题本身（前缀「大事件N：」不含标题文字）
      final at = lines[i].indexOf(line.title);
      if (at < 0) continue;
      headerLines.add(i);
      headerTitles.add(line.title);
      headerMajors.add(line.isMajor);
      titleRanges.add((at, at + line.title.length));
    }

    final events = <OutlineEventText>[];
    for (var k = 0; k < headerLines.length; k++) {
      final header = headerLines[k];
      var end = header + 1;
      while (end < lines.length && !isOutlineBoundaryLine(lines[end])) {
        end++;
      }
      events.add(
        OutlineEventText(
          index: k + 1,
          isMajor: headerMajors[k],
          title: headerTitles[k],
          headerLine: header,
          titleStart: titleRanges[k].$1,
          titleEnd: titleRanges[k].$2,
          bodyStart: header + 1,
          bodyEnd: end,
        ),
      );
    }
    return OutlineTextIndex._(content, lines, events);
  }

  /// 该行属于哪个事件（标题行与它的概要区都算）；不在任何事件里时返回 null
  OutlineEventText? eventAtLine(int line) {
    for (final e in events) {
      if (e.headerLine == line) return e;
      if (line >= e.bodyStart && line < e.bodyEnd) return e;
    }
    return null;
  }
}

/// 一处改名命中：命中位置 + 属于哪个事件 + 命中的是标题还是概要。
class OutlineRenameHit {
  /// 被替换掉的原文
  final String source;

  /// 命中属于哪个事件
  final OutlineEventText event;

  /// 命中在正文里的位置（同一行同一字段可能有多个）
  final List<OutlineTextOccurrence> occurrences;

  /// `true` = 命中在事件标题里；`false` = 命中在概要区里
  final bool inTitle;

  /// 列表上展示的上下文（取第一处命中的上下文）
  final String context;

  const OutlineRenameHit({
    required this.source,
    required this.event,
    required this.occurrences,
    required this.inTitle,
    required this.context,
  });

  int get count => occurrences.length;

  /// 事件在大纲正文里的定位文案，如「大事件3 · 标题」「小事件5 · 概要」
  String get where =>
      '${event.isMajor ? "大事件" : "小事件"}${event.index} · ${inTitle ? "标题" : "概要"}';
}

/// 一次改名在**大纲正文**上的完整结果：命中清单 + 替换后的新正文。
class OutlineRenameResult {
  /// 按事件顺序排列的命中（同一事件可能有多条：标题一处、概要多处）
  final List<OutlineRenameHit> hits;

  /// 应用改名后的新正文
  final String newContent;

  const OutlineRenameResult({required this.hits, required this.newContent});

  /// 共替换了多少处
  int get totalCount => hits.fold(0, (sum, hit) => sum + hit.occurrences.length);

  /// 涉及多少个事件（事件是「改动的可见单位」，用户按它判断影响面）
  int get eventCount => hits.map((h) => h.event.index).toSet().length;

  bool get isEmpty => hits.isEmpty;

  /// 列表上最多展示的命中条数（剩下的用条数概括）
  static const int previewLimit = 30;
}

/// 在 [content] 里查找 [source] 的所有命中（事件标题与概要区都查）。
///
/// 定位规则：
/// - 只查**事件标题**与**概要区**：幕标题、装饰行、事件之外的正文不动
///   （它们不属于任何事件，改了也说不清改在哪儿）；
/// - 大小写敏感：中文无大小写问题，英文名区分大小写更符合预期；
/// - 不做全词匹配：中文没有词的边界，「李云」出现在「李云飞」里也算命中——
///   改名本来就要连名带姓一起换；列表里会显示**实际替换掉的文字**与上下文，
///   用户自己确认。
///
/// [maxPerLine] 限制同一行的命中数，避免某个高频短词把结果撑爆。
OutlineRenameResult findRenameHits(
  String content,
  String source, {
  int maxPerLine = 20,
}) {
  final key = source.trim();
  if (key.isEmpty) {
    return OutlineRenameResult(hits: const [], newContent: content);
  }

  final index = OutlineTextIndex.of(content);
  final hits = <OutlineRenameHit>[];

  for (final event in index.events) {
    // 标题行：只在标题本身的区间里找，`══`/`○`/「大事件N：」里的文字不参与
    final titleOccurrences = _scanLine(
      index.lines[event.headerLine],
      event.headerLine,
      key,
      limitStart: event.titleStart,
      limitEnd: event.titleEnd,
      maxPerLine: maxPerLine,
    );
    if (titleOccurrences.isNotEmpty) {
      hits.add(
        OutlineRenameHit(
          source: key,
          event: event,
          occurrences: titleOccurrences,
          inTitle: true,
          context: titleOccurrences.first.context,
        ),
      );
    }

    // 概要区
    for (var line = event.bodyStart; line < event.bodyEnd; line++) {
      final occurrences = _scanLine(
        index.lines[line],
        line,
        key,
        maxPerLine: maxPerLine,
      );
      if (occurrences.isEmpty) continue;
      hits.add(
        OutlineRenameHit(
          source: key,
          event: event,
          occurrences: occurrences,
          inTitle: false,
          context: occurrences.first.context,
        ),
      );
    }
  }

  return OutlineRenameResult(
    hits: hits,
    newContent: replaceOccurrences(content, _flatten(hits), key),
  );
}

/// 把所有命中摊平成一个列表（替换时统一从后往前改）
List<OutlineTextOccurrence> _flatten(List<OutlineRenameHit> hits) =>
    [for (final h in hits) ...h.occurrences];

/// 按位置把正文里的 [occurrences] 换成 [target]。
///
/// 每处替换前都校验「该位置上的文字仍是这次命中的原文」（[OutlineTextOccurrence.matched]）：
/// 坐标一旦被前面的替换带偏就直接跳过，绝不误改相邻文字。
/// 同一行上的多处替换**从后往前**做，前面的下标才不会失效。
String replaceOccurrences(
  String content,
  List<OutlineTextOccurrence> occurrences,
  String target,
) {
  if (occurrences.isEmpty || target.isEmpty) return content;
  final lines = content.split('\n');
  final byLine = <int, List<OutlineTextOccurrence>>{};
  for (final occ in occurrences) {
    byLine.putIfAbsent(occ.line, () => []).add(occ);
  }
  for (final entry in byLine.entries) {
    final lineNo = entry.key;
    if (lineNo < 0 || lineNo >= lines.length) continue;
    final ordered = [...entry.value]..sort((a, b) => b.start.compareTo(a.start));
    var line = lines[lineNo];
    for (final occ in ordered) {
      if (occ.start < 0 || occ.end > line.length || occ.start >= occ.end) {
        continue;
      }
      // 坐标校验：命中位置上的文字仍是原文才改，否则说明这一行已被改过
      if (line.substring(occ.start, occ.end) != occ.matched) continue;
      line = line.replaceRange(occ.start, occ.end, target);
    }
    lines[lineNo] = line;
  }
  return lines.join('\n');
}

/// 批量改名：按 [mapping]（原文 → 新文）逐条替换大纲正文。
///
/// **已替换区间会被保护**：`甲→乙` 之后 `乙→丙` 不会把刚改出来的「乙」再改成
/// 「丙」——否则一串改名会连锁反应（把本来就叫乙的人一起改掉）。
/// 具体做法：每轮重新扫描当前正文，并记下本轮写入的落点，后续轮次跳过它们。
///
/// [fallbackToPlainText]：正文里**一个事件都识别不出来**时（例如伏笔清单那种
/// 没有事件结构的纯文本），改为整篇纯文本替换。事件结构存在时一律按事件定位，
/// 事件之外的文字（幕标题、说明）绝不碰。
String renameInOutlineText(
  String content,
  Map<String, String> mapping, {
  bool fallbackToPlainText = false,
}) {
  var result = content;
  final written = <String, Set<(int, int)>>{};

  for (final entry in mapping.entries) {
    final source = entry.key.trim();
    final target = entry.value.trim();
    if (source.isEmpty || target.isEmpty || source == target) continue;

    final found = findRenameHits(result, source);
    if (found.isEmpty) {
      if (fallbackToPlainText && OutlineTextIndex.of(result).events.isEmpty) {
        result = _replacePlainText(result, source, target, written);
      }
      continue;
    }
    final occurrences = _flatten(found.hits)
        .where((o) => !(written[source]?.contains((o.line, o.start)) ?? false))
        .toList();
    if (occurrences.isEmpty) continue;

    final lines = result.split('\n');
    final byLine = <int, List<OutlineTextOccurrence>>{};
    for (final occ in occurrences) {
      byLine.putIfAbsent(occ.line, () => []).add(occ);
    }
    for (final e in byLine.entries) {
      if (e.key < 0 || e.key >= lines.length) continue;
      final ordered = [...e.value]..sort((a, b) => b.start.compareTo(a.start));
      var line = lines[e.key];
      for (final occ in ordered) {
        if (occ.start < 0 || occ.end > line.length || occ.start >= occ.end) {
          continue;
        }
        if (line.substring(occ.start, occ.end) != source) continue;
        line = line.replaceRange(occ.start, occ.end, target);
        written.putIfAbsent(target, () => {}).add((e.key, occ.start));
      }
      lines[e.key] = line;
    }
    result = lines.join('\n');
  }
  return result;
}

/// 纯文本替换（没有事件结构时用）：逐行**从后往前**替换这一轮的所有命中。
///
/// 先把命中位置全部收集起来再改，不在替换过程中重新搜索——替换文本里若含有
/// 原词（`李云` → `李云霄`）会把自己刚写进去的字再匹配一遍，越改越长。
String _replacePlainText(
  String content,
  String source,
  String target,
  Map<String, Set<(int, int)>> written,
) {
  final lines = content.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.contains(source)) continue;
    final hits = <int>[];
    var at = line.indexOf(source);
    while (at >= 0) {
      hits.add(at);
      at = line.indexOf(source, at + source.length);
    }
    if (hits.isEmpty) continue;
    var current = line;
    for (final start in hits.reversed) {
      current = current.replaceRange(start, start + source.length, target);
      written.putIfAbsent(target, () => {}).add((i, start));
    }
    lines[i] = current;
  }
  return lines.join('\n');
}

/// 单行扫描：把 [key] 在该行 `[limitStart, limitEnd)` 区间内的所有出现找出来
List<OutlineTextOccurrence> _scanLine(
  String line,
  int lineNo,
  String key, {
  int? limitStart,
  int? limitEnd,
  int maxPerLine = 20,
}) {
  final out = <OutlineTextOccurrence>[];
  if (key.isEmpty || line.isEmpty) return out;
  final from = (limitStart ?? 0).clamp(0, line.length);
  final to = (limitEnd ?? line.length).clamp(0, line.length);
  var at = line.indexOf(key, from);
  while (at >= 0 && at + key.length <= to && out.length < maxPerLine) {
    out.add(
      OutlineTextOccurrence(
        line: lineNo,
        start: at,
        end: at + key.length,
        matched: line.substring(at, at + key.length),
        context: _context(line, at, at + key.length),
      ),
    );
    at = line.indexOf(key, at + key.length);
  }
  return out;
}

/// 命中处左右各最多 8 字的上下文
String _context(String line, int start, int end) {
  const span = 8;
  final left = start - span < 0 ? 0 : start - span;
  final right = end + span > line.length ? line.length : end + span;
  final prefix = left > 0 ? '…' : '';
  final suffix = right < line.length ? '…' : '';
  return '$prefix${line.substring(left, right).trim()}$suffix';
}
