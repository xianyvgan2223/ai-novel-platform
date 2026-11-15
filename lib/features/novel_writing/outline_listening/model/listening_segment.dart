import 'package:flutter/material.dart';

import 'package:deepseekapp/core/theme/app_palette.dart';

/// 「听大纲改名」的朗读模式：决定每个事件读多少内容。
///
/// 三个档位覆盖三种典型用法：只想核对结构时读标题，想连听带看时读标题 + 概要，
/// 已经写过正文、想通听一遍找问题时把正文也读上。
enum OutlineListenMode {
  /// 只读事件标题
  titleOnly('只读标题'),

  /// 读标题 + 事件概要（默认）
  titleAndSummary('标题 + 概要'),

  /// 读标题 + 概要 + 已写正文（正文较长，可能读很久）
  full('标题 + 概要 + 正文');

  /// 界面上显示的名字
  final String label;

  const OutlineListenMode(this.label);

  bool get includesSummary => this != OutlineListenMode.titleOnly;

  bool get includesContent => this == OutlineListenMode.full;

  static OutlineListenMode fromName(String? name) {
    for (final m in OutlineListenMode.values) {
      if (m.name == name) return m;
    }
    return OutlineListenMode.titleAndSummary;
  }
}

/// 朗读事件范围：全部事件 / 只听大事件 / 只听小事件。
///
/// 长篇小说动辄上百个事件，用户可能只想把「大事件」这条主线顺一遍，
/// 或者反过来只补听小事件细节。范围只影响**朗读推进**（播放 / 上一个 / 下一个 /
/// 自动连读），不影响卡片列表本身——边听边改时仍然能看到并编辑所有事件。
enum OutlineListenScope {
  /// 全部事件
  all('全部事件'),

  /// 只听大事件
  majorOnly('只听大事件'),

  /// 只听小事件
  minorOnly('只听小事件');

  final String label;

  const OutlineListenScope(this.label);

  /// 这条事件在当前范围里读不读
  bool matches(bool isMajor) => switch (this) {
    OutlineListenScope.all => true,
    OutlineListenScope.majorOnly => isMajor,
    OutlineListenScope.minorOnly => !isMajor,
  };

  static OutlineListenScope fromName(String? name) {
    for (final s in OutlineListenScope.values) {
      if (s.name == name) return s;
    }
    return OutlineListenScope.all;
  }
}

/// 朗读参数（语速 / 音调 / 语言 / 模式）。不可变，改动即换一份，
/// 便于「正在读的内容不受设置改动影响」这类判断。
@immutable
class OutlineSpeechSettings {
  /// 语速，1.0 为正常
  final double rate;

  /// 音调，1.0 为正常
  final double pitch;

  /// BCP-47 语言标签（如 `zh-CN`）。设备缺该语言的语音包时由实现方退回默认语言，
  /// 而不是干脆不读。
  final String language;

  /// 朗读模式
  final OutlineListenMode mode;

  /// DeepSeek TTS 音色：stella（女声）/ tide（男声）
  final String ttsVoice;

  /// 朗读事件范围（全部 / 只听大事件 / 只听小事件）
  final OutlineListenScope scope;

  /// 一个事件读完后是否自动接着读下一个
  final bool autoNext;

  /// 读完最后一个事件后是否回到第一个继续（循环）
  final bool repeat;

  const OutlineSpeechSettings({
    this.rate = 1.0,
    this.pitch = 1.0,
    this.language = 'zh-CN',
    this.mode = OutlineListenMode.titleAndSummary,
    this.ttsVoice = 'stella',
    this.scope = OutlineListenScope.all,
    this.autoNext = true,
    this.repeat = false,
  });

  /// 可选的语速档位（界面用一排按钮呈现，不做连续滑块：朗读语速用整数档更好挑）
  ///
  /// 3.0x / 4.0x 是「快速过一遍大纲」用的高档位：本地离线合成（VITS）在 4.0x
  /// 下会明显发紧、个别字可能糊，但内容能听懂；系统引擎能接受多快取决于引擎本身
  /// （有的引擎上限就是 3.0，传更大值会被它自己夹住）。
  static const List<double> rateOptions = [
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0,
    4.0,
  ];

  OutlineSpeechSettings copyWith({
    double? rate,
    double? pitch,
    String? language,
    OutlineListenMode? mode,
    String? ttsVoice,
    OutlineListenScope? scope,
    bool? autoNext,
    bool? repeat,
  }) => OutlineSpeechSettings(
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    language: language ?? this.language,
    mode: mode ?? this.mode,
    ttsVoice: ttsVoice ?? this.ttsVoice,
    scope: scope ?? this.scope,
    autoNext: autoNext ?? this.autoNext,
    repeat: repeat ?? this.repeat,
  );

  /// 语速文案（如 `1.25x`）
  String get rateLabel => '${rate}x';

  @override
  bool operator ==(Object other) =>
      other is OutlineSpeechSettings &&
      other.rate == rate &&
      other.pitch == pitch &&
      other.language == language &&
      other.mode == mode &&
      other.ttsVoice == ttsVoice &&
      other.scope == scope &&
      other.autoNext == autoNext &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(
    rate,
    pitch,
    language,
    mode,
    ttsVoice,
    scope,
    autoNext,
    repeat,
  );
}

/// 可高亮的文本编辑控制器：朗读时给「当前正在读的句子」加一层背景色。
///
/// 为什么继承 [TextEditingController] 而不是在页面里用 RichText 覆盖：
/// 卡片上的标题 / 概要是可编辑的 TextField，用户边听边改是这页的核心用法；
/// 用控制器重写 [buildTextSpan]，高亮与编辑就落在同一个控件里，不会出现
/// 「高亮层和输入层错位」或「朗读时不能改字」的问题。
///
/// 高亮范围只影响绘制，不触发 [TextEditingController] 的通知——否则
/// 「朗读推进」会被误判成「用户改了文本」，把撤回历史和未保存标记搅乱。
class OutlineListenTextController extends TextEditingController {
  OutlineListenTextController({super.text});

  TextRange? _highlightRange;

  /// 当前需要高亮的字符区间（null = 不高亮）
  TextRange? get highlightRange => _highlightRange;

  /// 高亮底色（浅主色，深色文字上仍清晰）
  Color highlightColor = const Color(0x334D6BFE);

  /// 设置高亮区间（会按当前文本长度夹紧；相同区间不重复设置）。
  ///
  /// 刻意**不调用** notifyListeners：页面下一次由控制器统一重建时
  /// [buildTextSpan] 会自然读到新值；若这里通知，会被当作文本改动。
  void setHighlight(TextRange? range) {
    final len = text.length;
    TextRange? normalized;
    if (range != null) {
      final start = range.start.clamp(0, len);
      final end = range.end.clamp(0, len);
      if (end > start) normalized = TextRange(start: start, end: end);
    }
    if (normalized == _highlightRange) return;
    _highlightRange = normalized;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final range = _highlightRange;
    // 输入法组合中（正在拼音选字）交回默认实现，避免把 composing 下划线弄丢
    if (range == null || withComposing && value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final p = context.palette;
    final before = text.substring(0, range.start);
    final mid = text.substring(range.start, range.end);
    final after = text.substring(range.end);
    return TextSpan(
      style: base,
      children: [
        if (before.isNotEmpty) TextSpan(text: before),
        TextSpan(
          text: mid,
          style: base.copyWith(
            backgroundColor: p.isDark
                ? p.accent.withValues(alpha: 0.28)
                : highlightColor,
            color: p.isDark ? p.textPrimary : const Color(0xFF1A1A1A),
          ),
        ),
        if (after.isNotEmpty) TextSpan(text: after),
      ],
    );
  }
}

///
/// 与上一版的区别：上一版把事件拆成「标题一段 + 概要逐行 N 段 + 正文一段」，
/// 列表里一行一个框、读的时候一行一停；用户要的是**一个事件一个框**——
/// 标题与概要在同一张卡片里，点卡片上的播放就从这一个事件开始读，
/// 读完整个事件再往下走。
///
/// 卡片上可编辑的内容：
/// - [titleCtrl]：事件标题（写回 `outline_chapters.event_title` + 大纲正文的标题行）
/// - [summaryCtrl]：事件概要**整段**（多行保留换行；写回 `event_summary` + 正文概要区）
/// - 正文（[content]）只读展示：本页不改正文，避免误删已生成的内容
class OutlineListenSegment {
  /// 事件在 `outline_chapters` 里的行 id（0 表示这一行还没入库，不可写回）
  final int chapterId;

  /// 事件在大纲里的全局序号（从 1 开始）——写回大纲正文时按它定位
  final int eventIndex;

  /// 是否大事件（大事件是结构节点，卡片上要能一眼分开）
  final bool isMajor;

  /// 大事件序号：**全篇只数大事件**，从 1 连续（与大纲正文里的「大事件N」一致）；
  /// 小事件为 null
  final int? majorNumber;

  /// 小事件序号：**在所属大事件内部从 1 重新计数**（与大纲正文里的「○ 小事件N」
  /// 一致）；大事件为 null
  final int? minorNumber;

  /// 事件标题（带朗读高亮能力）
  final OutlineListenTextController titleCtrl;

  /// 事件概要整段（多行保留换行，带朗读高亮能力）
  final OutlineListenTextController summaryCtrl;

  /// 事件当前完整正文（只读，只在「标题 + 概要 + 正文」模式下读出来）
  String content;

  /// 进入页面 / 上次保存时的标题与概要，用于「未保存」判断与写回定位
  String savedTitle;
  String savedSummary;

  OutlineListenSegment({
    required this.chapterId,
    required this.eventIndex,
    required this.isMajor,
    this.majorNumber,
    this.minorNumber,
    required String title,
    required String summary,
    required this.content,
  }) : titleCtrl = OutlineListenTextController(text: title),
       summaryCtrl = OutlineListenTextController(text: summary),
       savedTitle = title,
       savedSummary = summary {
    titleCtrl.addListener(_notifyChanged);
    summaryCtrl.addListener(_notifyChanged);
  }

  /// 文本变更回调：由控制器注入，用于刷新页面（未保存标记、保存按钮状态）
  VoidCallback? onChanged;

  /// 会话内的稳定标识：就是事件序号，保留这个别名让调用处读起来更清楚
  /// （说的是「哪一张卡片」而不是「第几个事件」）
  int get localId => eventIndex;

  String get title => titleCtrl.text.trim();

  /// 概要原文（保留换行；写回要原样带上）
  String get summary => summaryCtrl.text.trim();

  /// 未保存判定：标题或概要任一变化
  bool get isDirty => title != savedTitle || summary != savedSummary;

  bool get hasContent => content.trim().isNotEmpty;

  /// 已写正文的字数（卡片上提示用）
  int get contentLength => content.trim().characters.length;

  /// 可写回数据库（章节行已入库）
  bool get canPersist => chapterId != 0;

  /// 卡片上的类型文案，如「大事件3」「小事件2」。
  ///
  /// 序号就是**大纲正文里的写法**：大事件全篇连续（`══ 大事件N：`，只数大事件），
  /// 小事件在所属大事件内部从 1 重新开始（`○ 小事件N：`）——与「大纲编辑」页
  /// 卡片上的序号是同一套。不能退回去用 [eventIndex]：它是**所有**事件
  /// （含大事件）的连续序号，小事件会跳号（大事件1 后面跟着小事件2、3……），
  /// 正文里却是「○ 小事件1」。
  ///
  /// 序号没传时（旧调用方 / 单测直接构造）退回 eventIndex，只作兜底。
  String get typeLabel {
    if (isMajor) return '大事件${majorNumber ?? eventIndex}';
    return '小事件${minorNumber ?? eventIndex}';
  }

  /// 这一个事件读出来的文本。
  ///
  /// 类型标签后面用逗号隔开：语音会把「大事件3下山」连读成一个词，
  /// 断开之后才听得出「第 3 个大事件」和标题。
  String speechText(OutlineListenMode mode) {
    final buf = StringBuffer()..write('$typeLabel，$title');
    if (mode.includesSummary && summary.isNotEmpty) {
      buf.write('。$summary');
    }
    if (mode.includesContent && hasContent) {
      buf.write('。正文：$content');
    }
    return buf.toString().trim();
  }

  /// 标记为已保存（基线跟上当前文本）
  void markSaved() {
    savedTitle = title;
    savedSummary = summary;
  }

  /// 用新的文本替换标题（批量改名、重建列表时用）
  void replaceTitle(String text) {
    if (text == titleCtrl.text) return;
    titleCtrl.text = text;
    titleCtrl.selection = TextSelection.collapsed(offset: text.length);
  }

  /// 用新的文本替换概要
  void replaceSummary(String text) {
    if (text == summaryCtrl.text) return;
    summaryCtrl.text = text;
    summaryCtrl.selection = TextSelection.collapsed(offset: text.length);
  }

  /// 按 [replace] 把标题 / 概要 / 正文 / 已保存基线整体改一遍（批量改名用），
  /// 返回是否有改动
  bool renameAll(String Function(String) replace) {
    var changed = false;
    final nextTitle = replace(titleCtrl.text);
    if (nextTitle != titleCtrl.text) {
      titleCtrl.text = nextTitle;
      changed = true;
    }
    final nextSummary = replace(summaryCtrl.text);
    if (nextSummary != summaryCtrl.text) {
      summaryCtrl.text = nextSummary;
      changed = true;
    }
    final nextContent = replace(content);
    if (nextContent != content) {
      content = nextContent;
      changed = true;
    }
    final nextSavedTitle = replace(savedTitle);
    if (nextSavedTitle != savedTitle) {
      savedTitle = nextSavedTitle;
      changed = true;
    }
    final nextSavedSummary = replace(savedSummary);
    if (nextSavedSummary != savedSummary) {
      savedSummary = nextSavedSummary;
      changed = true;
    }
    return changed;
  }

  void _notifyChanged() => onChanged?.call();

  void dispose() {
    titleCtrl.removeListener(_notifyChanged);
    summaryCtrl.removeListener(_notifyChanged);
    titleCtrl.dispose();
    summaryCtrl.dispose();
  }
}

// ─── 句子级朗读计划（高亮 + 单事件拖动进度共用） ─────────────────

/// 一个可朗读片段属于哪种内容：标题 / 概要 / 正文。
///
/// 高亮时按它决定把区间画在哪个文本控制器上（正文没有编辑框，
/// 由播放器上的「当前句」提示条展示）。
enum SpeechPiecePart { title, summary, content }

/// 朗读计划中的一句：属于哪部分、在这部分文本里的区间、真正发给引擎的文本。
@immutable
class SpeechPiece {
  final SpeechPiecePart part;

  /// 在对应字段文本内的起始偏移（title: 0；summary: 概要文本内偏移；
  /// content: 正文内偏移）
  final int start;

  /// 结束偏移（不含）
  final int end;

  /// 实际朗读的文本（标题句带「大事件N，」前缀；正文首句前有「正文」提示词）
  final String text;

  const SpeechPiece({
    required this.part,
    required this.start,
    required this.end,
    required this.text,
  });

  @override
  String toString() => 'SpeechPiece(${part.name}, $start..$end, "$text")';
}

/// 一个事件的完整朗读计划：按「标题句 → 概要逐句 → 正文逐句」排好序。
@immutable
class SpeechPlan {
  final List<SpeechPiece> pieces;

  const SpeechPlan(this.pieces);

  static const SpeechPlan empty = SpeechPlan(<SpeechPiece>[]);

  int get length => pieces.length;

  bool get isEmpty => pieces.isEmpty;

  SpeechPiece? pieceAt(int index) =>
      index >= 0 && index < pieces.length ? pieces[index] : null;
}

/// 把一段文本切成适合「逐句朗读 / 高亮 / 拖动定位」的句子区间。
///
/// 规则：
/// 1. 在句末标点（。！？!?；;… 换行）处断开，紧随其后的闭引号 / 括号并入本句；
/// 2. 超长句（默认 >80 字，一口气读太久、高亮也不好看）再按逗号 / 顿号 / 冒号
///    切短，实在没有标点就按 80 字硬切；
/// 3. 返回的是**原文偏移**（已去掉首尾空白），调用方可以直接拿去做 TextRange 高亮。
List<({int start, int end})> splitSentenceRanges(
  String text, {
  int maxLength = 80,
}) {
  final firstPass = <({int start, int end})>[];
  if (text.isEmpty) return firstPass;

  bool isTerminator(int code) =>
      code == 0x3002 || // 。
      code == 0xFF01 || // ！
      code == 0xFF1F || // ？
      code == 0x21 || // !
      code == 0x3F || // ?
      code == 0xFF1B || // ；
      code == 0x3B || // ;
      code == 0x2026 || // …
      code == 0x0A ||
      code == 0x0D;

  bool isSoftBreak(int code) =>
      code == 0xFF0C || // ，
      code == 0x2C || // ,
      code == 0x3001 || // 、
      code == 0xFF1A || // ：
      code == 0x3A; // :

  bool isSpace(int code) =>
      code == 0x20 ||
      code == 0x09 ||
      code == 0x3000 ||
      code == 0x0A ||
      code == 0x0D;

  bool isCloser(int code) =>
      code == 0x300D || // 」
      code == 0x300F || // 』
      code == 0x201D || // ”
      code == 0x2019 || // ’
      code == 0x22 || // "
      code == 0x27 || // '
      code == 0xFF09 || // ）
      code == 0x29 || // )
      code == 0x300B || // 》
      code == 0x3011 || // 】
      code == 0x3009; // 〉

  var start = 0;
  var i = 0;

  void emit(int endExclusive) {
    var s = start;
    var e = endExclusive;
    while (s < e && isSpace(text.codeUnitAt(s))) {
      s++;
    }
    while (e > s && isSpace(text.codeUnitAt(e - 1))) {
      e--;
    }
    if (e > s) firstPass.add((start: s, end: e));
    start = endExclusive;
  }

  while (i < text.length) {
    final code = text.codeUnitAt(i);
    if (isTerminator(code)) {
      var j = i + 1;
      while (j < text.length && isCloser(text.codeUnitAt(j))) {
        j++;
      }
      emit(j);
      i = j;
      continue;
    }
    i++;
  }
  if (start < text.length) emit(text.length);

  // 第二遍：超长句再切短
  final out = <({int start, int end})>[];
  for (final r in firstPass) {
    final length = r.end - r.start;
    if (length <= maxLength) {
      out.add(r);
      continue;
    }
    var s = r.start;
    while (s < r.end) {
      var e = s + maxLength;
      if (e >= r.end) {
        out.add((start: s, end: r.end));
        break;
      }
      var cut = -1;
      for (var k = e - 1; k > s; k--) {
        if (isSoftBreak(text.codeUnitAt(k))) {
          cut = k + 1;
          break;
        }
      }
      var end = cut > s ? cut : e;
      // 别把代理对（emoji / 生僻扩展字）劈成两半
      if (end > s + 1 &&
          end < r.end &&
          (text.codeUnitAt(end) & 0xFC00) == 0xDC00) {
        end--;
      }
      out.add((start: s, end: end));
      s = end;
    }
  }
  return out;
}

/// 为一个事件生成朗读计划（读什么、按什么顺序、每句对应原文哪里）。
///
/// 与旧的 `OutlineListenSegment.speechText` 的关系：文案顺序保持一致
/// （类型标签 + 标题 → 概要 → 正文），只是拆成逐句，方便高亮与拖动定位。
SpeechPlan buildSpeechPlan(
  OutlineListenSegment segment,
  OutlineListenMode mode,
) {
  final pieces = <SpeechPiece>[];

  // 标题整句：语音把「大事件3下山」连读成一个词，加逗号断开更清楚；
  // 高亮时整段标题一起亮（标题一般很短，逐字高亮反而闪）。
  if (segment.title.isNotEmpty) {
    pieces.add(
      SpeechPiece(
        part: SpeechPiecePart.title,
        start: 0,
        end: segment.titleCtrl.text.length,
        text: '${segment.typeLabel}，${segment.title}',
      ),
    );
  }

  // 概要逐句
  if (mode.includesSummary) {
    final source = segment.summaryCtrl.text;
    for (final r in splitSentenceRanges(source)) {
      final sentence = source.substring(r.start, r.end).trim();
      if (sentence.isEmpty) continue;
      pieces.add(
        SpeechPiece(
          part: SpeechPiecePart.summary,
          start: r.start,
          end: r.end,
          text: sentence,
        ),
      );
    }
  }

  // 正文逐句（只有「标题 + 概要 + 正文」模式才读）：先读一句「正文」做分界，
  // 让听觉上知道标题概要已经结束。
  if (mode.includesContent && segment.hasContent) {
    pieces.add(
      const SpeechPiece(
        part: SpeechPiecePart.content,
        start: 0,
        end: 0,
        text: '正文',
      ),
    );
    final content = segment.content;
    for (final r in splitSentenceRanges(content)) {
      final sentence = content.substring(r.start, r.end).trim();
      if (sentence.isEmpty) continue;
      pieces.add(
        SpeechPiece(
          part: SpeechPiecePart.content,
          start: r.start,
          end: r.end,
          text: sentence,
        ),
      );
    }
  }

  return SpeechPlan(pieces);
}
