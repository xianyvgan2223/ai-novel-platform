import 'dart:convert';

import '../../shared/domain/character_profile.dart';
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

  /// 大事件序号：全篇只数大事件，从 1 连续（与正文里的「大事件N」一致）；
  /// 小事件为 null
  final int? majorNumber;

  /// 小事件序号：在所属大事件内部从 1 重新计数（与正文里的「○ 小事件N」一致）；
  /// 大事件为 null
  final int? minorNumber;

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
    this.majorNumber,
    this.minorNumber,
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
    final majorNumbers = <int?>[];
    final minorNumbers = <int?>[];
    final titleRanges = <(int, int)>[];
    var majorSeq = 0;
    var minorSeq = 0;

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
      // 显示序号按正文的规范编号口径算：大事件只数大事件、小事件在每个大事件
      // 内部从 1 重新开始（与 normalizeOutlineText / 大纲编辑页一致）
      if (line.isMajor) {
        majorSeq++;
        minorSeq = 0;
        majorNumbers.add(majorSeq);
        minorNumbers.add(null);
      } else {
        minorSeq++;
        majorNumbers.add(null);
        minorNumbers.add(minorSeq);
      }
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
          majorNumber: majorNumbers[k],
          minorNumber: minorNumbers[k],
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

  /// 事件在大纲正文里的定位文案，如「大事件3 · 标题」「小事件1 · 概要」。
  ///
  /// 序号与**大纲正文 / 大纲编辑页卡片**一致：大事件全篇只数大事件，
  /// 小事件在所属大事件内部从 1 重新计数——不能拿 [OutlineEventText.index]
  /// （所有事件的连续序号）顶上：大事件会跳号（大事件1、大事件5……），
  /// 小事件也会显示成 2、3、5……，用户按它在大纲里找不到对应那条。
  String get where {
    final label = event.isMajor
        ? '大事件${event.majorNumber ?? event.index}'
        : '小事件${event.minorNumber ?? event.index}';
    return '$label · ${inTitle ? "标题" : "概要"}';
  }
}

/// 小说设定里的一类**可改名文本**（字段说明 + 当前值）。
///
/// 类型 / 主题 / 主角简介 / 世界观各一条；人物档案（`outline_records.characters`
/// 的 JSON）按人物、按字段展开成多条。搜索预览与替换共用同一套字段定义，
/// 不会出现「预览里看得到、替换时不生效」。
class OutlineSettingText {
  /// 字段说明，如「主题」「主角简介」「世界观」「人物档案 · 顾泽 · 描述」
  final String label;

  /// 当前值
  final String value;

  const OutlineSettingText(this.label, this.value);
}

/// 小说设定里一处命中的预览条目（[label] 是哪个字段、[count] 命中几处）
class OutlineSettingHit {
  final String label;
  final int count;
  final String context;

  const OutlineSettingHit({
    required this.label,
    required this.count,
    required this.context,
  });
}

/// 解析 `outline_records.characters` 里的人物档案 JSON。
///
/// - 空串 → 空列表（还没提炼过人物档案）
/// - 解析失败 / 结构不对 → null：**调用方必须原样保留原文本**，不能拿空列表
///   覆盖，否则改一次名就把人物的描述 / 能力 / 性格整段丢了。
List<CharacterProfile>? tryParseCharacterProfiles(String json) {
  final text = json.trim();
  if (text.isEmpty) return const [];
  try {
    final data = jsonDecode(text);
    if (data is! List) return null;
    return [
      for (final item in data)
        if (item is Map)
          CharacterProfile.fromJson(Map<String, dynamic>.from(item)),
    ];
  } catch (_) {
    return null;
  }
}

/// 把小说设定整理成可搜索 / 可替换的文本字段。
///
/// 与 [renameSettingValues] 一一对应：预览里能看到的字段，替换时一定覆盖到。
/// 空字段不列（0 处命中，列出来只会让面板变长）。
List<OutlineSettingText> outlineSettingTexts({
  String genre = '',
  String theme = '',
  String protagonist = '',
  String worldview = '',
  String characters = '',
}) {
  final out = <OutlineSettingText>[
    if (genre.trim().isNotEmpty) OutlineSettingText('类型', genre),
    if (theme.trim().isNotEmpty) OutlineSettingText('主题', theme),
    if (protagonist.trim().isNotEmpty) OutlineSettingText('主角简介', protagonist),
    if (worldview.trim().isNotEmpty) OutlineSettingText('世界观', worldview),
  ];
  for (final c in tryParseCharacterProfiles(characters) ??
      const <CharacterProfile>[]) {
    final who = c.name.trim().isEmpty ? '未命名人物' : c.name.trim();
    if (c.name.trim().isNotEmpty) {
      out.add(OutlineSettingText('人物档案 · $who · 姓名', c.name));
    }
    if (c.description.trim().isNotEmpty) {
      out.add(OutlineSettingText('人物档案 · $who · 描述', c.description));
    }
    if (c.abilities.trim().isNotEmpty) {
      out.add(OutlineSettingText('人物档案 · $who · 能力', c.abilities));
    }
    if (c.personality.trim().isNotEmpty) {
      out.add(OutlineSettingText('人物档案 · $who · 性格', c.personality));
    }
  }
  return out;
}

/// 在小说设定字段里查 [source] 的命中（每个字段最多一条，便于面板展示）。
List<OutlineSettingHit> findSettingHits(
  List<OutlineSettingText> fields,
  String source,
) {
  final key = source.trim();
  if (key.isEmpty) return const [];
  final hits = <OutlineSettingHit>[];
  for (final field in fields) {
    if (field.value.isEmpty) continue;
    var count = 0;
    var at = field.value.indexOf(key);
    final first = at;
    while (at >= 0) {
      count++;
      at = field.value.indexOf(key, at + key.length);
    }
    if (count == 0) continue;
    hits.add(
      OutlineSettingHit(
        label: field.label,
        count: count,
        context: _settingContext(field.value, first, first + key.length),
      ),
    );
  }
  return hits;
}

/// 替换后的小说设定值（与 [outlineSettingTexts] 的字段一一对应）。
class OutlineSettingValues {
  final String genre;
  final String theme;
  final String protagonist;
  final String worldview;

  /// 人物档案 JSON（解析失败时原样返回，绝不覆盖坏数据）
  final String characters;

  const OutlineSettingValues({
    required this.genre,
    required this.theme,
    required this.protagonist,
    required this.worldview,
    required this.characters,
  });
}

/// 把 [mapping]（原文 → 新文）应用到小说设定上。
///
/// - 类型 / 主题 / 主角简介 / 世界观：纯文本替换（与正文的替换规则一致）；
/// - 人物档案：解析 JSON 后逐人物、逐字段替换再编码；**解析失败原样返回**。
OutlineSettingValues renameSettingValues({
  required String genre,
  required String theme,
  required String protagonist,
  required String worldview,
  required String characters,
  required Map<String, String> mapping,
}) {
  final profiles = tryParseCharacterProfiles(characters);
  var nextCharacters = characters;
  if (profiles != null && profiles.isNotEmpty) {
    nextCharacters = jsonEncode([
      for (final c in profiles)
        CharacterProfile(
          name: _replaceMapping(c.name, mapping),
          description: _replaceMapping(c.description, mapping),
          abilities: _replaceMapping(c.abilities, mapping),
          personality: _replaceMapping(c.personality, mapping),
          isProtagonist: c.isProtagonist,
        ).toJson(),
    ]);
  }
  return OutlineSettingValues(
    genre: _replaceMapping(genre, mapping),
    theme: _replaceMapping(theme, mapping),
    protagonist: _replaceMapping(protagonist, mapping),
    worldview: _replaceMapping(worldview, mapping),
    characters: nextCharacters,
  );
}

/// 按 [mapping] 逐条替换（顺序应用；与控制器里卡片的替换规则一致）
String _replaceMapping(String text, Map<String, String> mapping) {
  var out = text;
  for (final entry in mapping.entries) {
    if (entry.key.isEmpty || !out.contains(entry.key)) continue;
    out = out.replaceAll(entry.key, entry.value);
  }
  return out;
}

/// 设定命中处左右各最多 10 字的上下文（换行压成空格，面板里显示成一行）
String _settingContext(String text, int start, int end) {
  const span = 10;
  final left = start - span < 0 ? 0 : start - span;
  final right = end + span > text.length ? text.length : end + span;
  final body = text
      .substring(left, right)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${left > 0 ? '…' : ''}$body${right < text.length ? '…' : ''}';
}

/// 一次改名在**大纲正文**上的完整结果：命中清单 + 替换后的新正文。
class OutlineRenameResult {
  /// 按事件顺序排列的命中（同一事件可能有多条：标题一处、概要多处）
  final List<OutlineRenameHit> hits;

  /// 小说设定里（类型 / 主题 / 主角简介 / 世界观 / 人物档案）的命中
  final List<OutlineSettingHit> settingHits;

  /// 应用改名后的新正文
  final String newContent;

  const OutlineRenameResult({
    required this.hits,
    this.settingHits = const [],
    required this.newContent,
  });

  /// 大纲正文里共命中多少处
  int get outlineCount =>
      hits.fold(0, (sum, hit) => sum + hit.occurrences.length);

  /// 小说设定里共命中多少处
  int get settingCount => settingHits.fold(0, (sum, hit) => sum + hit.count);

  /// 共命中多少处（正文 + 设定）
  int get totalCount => outlineCount + settingCount;

  /// 涉及多少个事件（事件是「改动的可见单位」，用户按它判断影响面）
  int get eventCount => hits.map((h) => h.event.index).toSet().length;

  /// 正文与设定都没有命中
  bool get isEmpty => hits.isEmpty && settingHits.isEmpty;

  /// 大纲正文里有命中
  bool get hasOutlineHits => hits.isNotEmpty;

  /// 小说设定里有命中
  bool get hasSettingHits => settingHits.isNotEmpty;

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
/// [settings] 是「小说设定」的可搜索字段（见 [outlineSettingTexts]）：
/// 传了之后命中会一并算进 [OutlineRenameResult.settingHits]，面板才能显示
/// 「世界观 / 主题 / 主角简介 / 人物档案里也有几处」并让用户确认要不要一起改。
///
/// [maxPerLine] 限制同一行的命中数，避免某个高频短词把结果撑爆。
OutlineRenameResult findRenameHits(
  String content,
  String source, {
  int maxPerLine = 20,
  List<OutlineSettingText> settings = const [],
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
    settingHits: findSettingHits(settings, key),
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
