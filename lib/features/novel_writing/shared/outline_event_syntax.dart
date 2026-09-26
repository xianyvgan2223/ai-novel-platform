/// 大纲事件行的**唯一识别规则**（大事件 / 小事件 / 幕标题）。
///
/// 这套规则此前被复制到了 7 个地方（事件解析、写回大纲正文、章节提示词定位、
/// 历史骨架重建……），任何一份副本漏掉一种写法，都会造成「某个环节单独发作」的
/// bug。真实踩过的坑：
/// - 编号只允许一位（`[0-9Xx]` 没有 `+`）→ `大事件10：` 起全部失配，
///   大事件在结构里直接消失，其小事件被挂到上一个大事件名下；
/// - 不容忍 markdown 前缀 → 模型输出的 `## ══ 大事件28：` 整块丢失；
/// - 按标题定位而不是按序号定位 → 同名事件会被改错行。
///
/// **所有需要识别事件行的代码都必须调用本文件，不要再手写正则副本。**
///
/// 兼容的真实写法（取自历史大纲正文）：
/// - 大事件：`══ 大事件9：企鹅变异 ══` / `大事件10：公园兔潮` / `## ══ 大事件28：小惠养伤 ══`
/// - 小事件：`○ 小事件1：动物园来客` / `### ○ 小事件2：心痕的最后一块拼图` / `- 小事件3：x`
/// - 编号：多位数字、`X` 占位符、中文数字、带圈数字，或整体省略
/// - 幕标题：`══ 第一幕：开端 ══` / `第二幕：发展` / `## 第三幕`
library;

/// 行类型
enum OutlineLineKind {
  /// 大事件标题行
  major,

  /// 小事件标题行
  minor,

  /// 幕标题行（如「第一幕：开端」）：既不作为事件，也不能并入上一事件的概要
  act,

  /// 纯 ══ 装饰行
  decoration,

  /// 正文 / 概要等其它内容
  other,
}

/// 一行大纲的结构化识别结果
class OutlineLine {
  final OutlineLineKind kind;

  /// 事件标题（major/minor）或幕名（act，仅「第X幕」）；其余类型为空串
  final String title;

  /// 幕标题的完整标签（如「第一幕：开端」），非幕行为空串。
  /// [title] 保持历史语义（只有「第X幕」），避免影响骨架/展示逻辑。
  final String actLabel;

  /// 行首空格数（写回时保持原缩进）
  final int indent;

  const OutlineLine(
    this.kind, {
    this.title = '',
    this.actLabel = '',
    this.indent = 0,
  });

  bool get isEvent =>
      kind == OutlineLineKind.major || kind == OutlineLineKind.minor;

  bool get isMajor => kind == OutlineLineKind.major;

  bool get isMinor => kind == OutlineLineKind.minor;

  bool get isAct => kind == OutlineLineKind.act;
}

/// markdown 标题前缀（模型输出常带 `##` / `###`）
/// 行首修饰：markdown 标题前缀（#）、列表符号（○ • · -）、强调标记（* _）、
/// ══ / == 装饰，可任意组合、可重复出现。
///
/// 真实库里的变体（括号为该写法的实际行数）——只容忍其中一种，整段小事件就读不出来：
/// - 「○ **小事件1：标题**」（350 行，粗体包裹，是漏读的主要形态）
/// - 「**大事件1：标题**」（12 行）
/// - 「**══ 大事件19：标题 ══**」（3 行）
/// - 「=== 大事件97：标题 ===」（3 行，用 = 代替 ═）
const String _lead = r'(?:#{1,6}\s*|[○•·\-*_]\s*|[═=＝]+\s*)*';

/// 行尾修饰：强调标记与 ══ / == 装饰
const String _tail = r'(?:[═=＝]+\s*|\*{1,3}\s*|_{1,3}\s*)*';

/// 事件编号：多位数字 / 占位符 X / 带圈数字 / 中文数字，可整体省略
const String _eventNumber = r'(?:[0-9]+|[Xx]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十百零]+)?';

/// 大事件标题行：行首修饰 +「大事件N：标题」+ 行尾修饰
final RegExp _majorRe = RegExp(
  '^\\s*$_lead(?:大事件|Major|事件)\\s*$_eventNumber\\s*[：:]\\s*(.+?)\\s*$_tail\$',
);

/// 小事件标题行：同大事件（○ / - / * 等列表符号已含在 [_lead] 里）
final RegExp _minorRe = RegExp(
  '^\\s*$_lead(?:小事件|事件)\\s*$_eventNumber\\s*[：:]\\s*(.+?)\\s*$_tail\$',
);

/// 幕标题行：可选 markdown 前缀、可选 ══ / = 装饰；
/// 组1 =「第X幕」，组2 = 分隔符（原样的空白/冒号），组3 = 幕名（可为空）。
/// 分隔符单独捕获是为了**保持原样**：模型写过「第三幕（高潮&结局）详细展开」，
/// 规范化时不该凭空补一个冒号进去。
final RegExp _actRe = RegExp(
  '^\\s*$_lead(第\\s*[一二三四五六七八九十0-9]+\\s*幕)(\\s*[：:]?\\s*)(.*?)\\s*$_tail\$',
);

/// 纯装饰行：只由 ═ / = / ＝ / 空白组成
final RegExp _decorationRe = RegExp(r'^[═=＝\s]+$');

/// 去掉标题两端残留的强调 / 装饰标记：**归来的伤口** → 归来的伤口。
/// 只剥两端的 * _ ═ = 与空白，标题里的下划线、括号等一律不动。
String _cleanTitle(String raw) => raw
    .replaceAll(RegExp(r'^[\s═=＝*_]+'), '')
    .replaceAll(RegExp(r'[\s═=＝*_]+$'), '')
    .trim();

/// 识别一行大纲。**事件行判定顺序固定：大事件 → 小事件 → 幕 → 装饰 → 其它**，
/// 与历史解析器一致（先按大事件解释，命中后不再按小事件解释）。
OutlineLine classifyOutlineLine(String raw) {
  final trimmed = raw.trim();
  final indent = raw.length - raw.trimLeft().length;
  if (trimmed.isEmpty) {
    return OutlineLine(OutlineLineKind.other, indent: indent);
  }

  final major = _majorRe.firstMatch(trimmed);
  if (major != null) {
    final title = _cleanTitle(major.group(1) ?? '');
    // 标题为空的行（如「大事件1：」断行）不算事件，避免产生无名事件
    if (title.isNotEmpty) {
      return OutlineLine(OutlineLineKind.major, title: title, indent: indent);
    }
  }

  final minor = _minorRe.firstMatch(trimmed);
  if (minor != null) {
    final title = _cleanTitle(minor.group(1) ?? '');
    if (title.isNotEmpty) {
      return OutlineLine(OutlineLineKind.minor, title: title, indent: indent);
    }
  }

  final act = _actRe.firstMatch(trimmed);
  if (act != null) {
    final name = act.group(1) ?? '';
    final rawSep = act.group(2) ?? '';
    final tail = (act.group(3) ?? '').trim();
    // 分隔符原样保留，只把冒号写法统一成全角
    final sep = rawSep.contains('：') || rawSep.contains(':')
        ? '：'
        : (rawSep.isEmpty ? '' : ' ');
    return OutlineLine(
      OutlineLineKind.act,
      title: name,
      actLabel: tail.isEmpty ? name : '$name$sep$tail',
      indent: indent,
    );
  }

  if (trimmed.contains('═') && _decorationRe.hasMatch(trimmed)) {
    return OutlineLine(OutlineLineKind.decoration, indent: indent);
  }

  return OutlineLine(OutlineLineKind.other, indent: indent);
}

/// 是否为事件标题行（大事件 / 小事件）
bool isOutlineEventHeader(String raw) => classifyOutlineLine(raw).isEvent;

/// 写回概要时的**概要区边界**：事件标题、幕标题、装饰行、以及
/// `○` / `-` 开头的条目行都视为边界（原样保留，绝不并入概要）。
///
/// 边界漏判会直接删数据：改上一条概要时，把下一行事件标题当成概要内容替换掉。
bool isOutlineBoundaryLine(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return false;
  final line = classifyOutlineLine(raw);
  if (line.isEvent || line.isAct) return true;
  if (trimmed.startsWith('══') && trimmed.endsWith('══')) return true;
  if (trimmed.startsWith('○') || trimmed.startsWith('-')) return true;
  return false;
}

/// 模型回显框架文本时会把前缀写进标题里（如「大事件13：大事件14：唯欣苏醒」）。
/// 这里剥掉标题内嵌套的事件前缀，最多 3 层；前缀必须带编号，
/// 以免把「事件：xxx」这类正常标题误伤成空标题。
final RegExp _nestedEventPrefixRe = RegExp(
  '^$_lead(?:大事件|小事件|Major|事件)\\s*'
  '(?:[0-9]+|[Xx]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十百零]+)\\s*[：:]\\s*',
);

/// 去掉标题内嵌套的「大事件N：」/「小事件N：」前缀（生成侧与规范化共用）
String stripNestedEventPrefix(String title) {
  var t = title.trim();
  for (var i = 0; i < 3; i++) {
    final m = _nestedEventPrefixRe.firstMatch(t);
    if (m == null) break;
    final rest = t.substring(m.end).trim();
    if (rest.isEmpty) break;
    t = rest;
  }
  return t;
}

/// 事件行里声明的**数字**编号（大事件10： → 10）；未写编号 / 写 X / 中文数字
/// 时返回 null。生成提示词需要用它算出「本块应输出的编号范围」。
int? declaredEventNumber(String raw) {
  final t = raw.trim();
  final major = RegExp(
    '^\\s*$_lead(?:大事件|Major|事件)\\s*([0-9]+)\\s*[：:]',
  ).firstMatch(t);
  if (major != null) return int.tryParse(major.group(1)!);
  final minor = RegExp(
    '^\\s*$_lead(?:小事件|事件)\\s*([0-9]+)\\s*[：:]',
  ).firstMatch(t);
  if (minor != null) return int.tryParse(minor.group(1)!);
  return null;
}

/// 规范的大事件标题行写法（生成、写回、落库统一用这一处）
String formatMajorHeader(int index, String title) {
  final t = stripNestedEventPrefix(title);
  return '══ 大事件$index：$t ══';
}

/// 规范的小事件标题行写法
String formatMinorHeader(int index, String title) {
  final t = stripNestedEventPrefix(title);
  return '○ 小事件$index：$t';
}

/// 把大纲正文里的事件标题行统一成规范写法（**生成侧的格式统一出口**）。
///
/// 规范写法与生成提示词一致：
/// - 幕标题：══ 第一幕：开端 ══
/// - 大事件：══ 大事件N：标题 ══（N 为全篇连续序号，从 1 开始）
/// - 小事件：○ 小事件N：标题（N 在每个大事件内部从 1 重新开始）
///
/// 为什么需要它：模型看到的「已有大事件框架」是裸格式（大事件N：标题），
/// 提示词范例却是 ══ 包裹，加上模型自身习惯，同一个模型在不同块里会写出
/// ══、裸标题、markdown 三种形态；而分块归一化只在认得出标题时才改写，
/// 认不出就整块原样落库，于是同一篇大纲里格式并存。落库前按**位置**重新编号
/// 并统一写法后，模型输出成什么样都不再影响最终格式。
///
/// 安全约定：
/// - 只重写「被识别为事件 / 幕标题」的行；概要、正文、空行逐字节保持原样
/// - 识别不到任何事件时原样返回，绝不猜测、不改写普通文本
/// - 幂等：对已规范化的文本再执行一次，结果完全相同（返回同一内容）
String normalizeOutlineText(String content) {
  final lines = content.split('\n');
  final out = <String>[];
  var majorSeq = 0;
  var minorSeq = 0;
  var hasEvent = false;
  var changed = false;

  for (final raw in lines) {
    final line = classifyOutlineLine(raw);
    if (line.isMajor) {
      hasEvent = true;
      majorSeq++;
      minorSeq = 0;
      final canonical = formatMajorHeader(majorSeq, line.title);
      if (raw != canonical) changed = true;
      out.add(canonical);
      continue;
    }
    if (line.isMinor) {
      hasEvent = true;
      minorSeq++;
      final canonical = formatMinorHeader(minorSeq, line.title);
      if (raw != canonical) changed = true;
      out.add(canonical);
      continue;
    }
    if (line.isAct) {
      final label = line.actLabel;
      if (label.isNotEmpty) {
        final canonical = '══ $label ══';
        if (raw != canonical) changed = true;
        out.add(canonical);
        continue;
      }
    }
    out.add(raw);
  }

  if (!hasEvent || !changed) return content;
  return out.join('\n');
}

/// 只规范化**小事件**标题行（大事件行原样保留、编号绝不动）。
///
/// 用于生成的分块阶段：块内文本会作为「前一块已展开的详细内容」注入下一块的
/// 提示词，模型看到粗体小事件就会照抄（自增强）——库里 350 行
/// 「○ **小事件N：标题**」就是这么来的。大事件的全局编号由分块逻辑负责
/// （formatMajorHeader + globalStartIndex），这里不能重新编号。
String normalizeMinorHeaders(String text) {
  final out = <String>[];
  var minorSeq = 0;
  var changed = false;
  for (final raw in text.split('\n')) {
    final line = classifyOutlineLine(raw);
    if (line.isMajor) {
      minorSeq = 0; // 进入新的大事件：小事件重新从 1 计数
      out.add(raw);
      continue;
    }
    if (line.isMinor) {
      minorSeq++;
      final canonical = formatMinorHeader(minorSeq, line.title);
      if (raw != canonical) changed = true;
      out.add(canonical);
      continue;
    }
    out.add(raw);
  }
  if (!changed) return text;
  return out.join('\n');
}
