import 'package:flutter/widgets.dart';

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

  /// 一个事件读完后是否自动接着读下一个
  final bool autoNext;

  /// 读完最后一个事件后是否回到第一个继续（循环）
  final bool repeat;

  const OutlineSpeechSettings({
    this.rate = 1.0,
    this.pitch = 1.0,
    this.language = 'zh-CN',
    this.mode = OutlineListenMode.titleAndSummary,
    this.autoNext = true,
    this.repeat = false,
  });

  /// 可选的语速档位（界面用一排按钮呈现，不做连续滑块：朗读语速用整数档更好挑）
  ///
  /// 3.0x 是本地离线合成（VITS）还听得清的上限，也够用来快速过一遍大纲。
  static const List<double> rateOptions = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  OutlineSpeechSettings copyWith({
    double? rate,
    double? pitch,
    String? language,
    OutlineListenMode? mode,
    bool? autoNext,
    bool? repeat,
  }) => OutlineSpeechSettings(
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    language: language ?? this.language,
    mode: mode ?? this.mode,
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
      other.autoNext == autoNext &&
      other.repeat == repeat;

  @override
  int get hashCode =>
      Object.hash(rate, pitch, language, mode, autoNext, repeat);
}

/// **一个事件 = 一个框**（V4.8.4 起）。
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

  /// 事件标题
  final TextEditingController titleCtrl;

  /// 事件概要整段（多行保留换行）
  final TextEditingController summaryCtrl;

  /// 事件当前完整正文（只读，只在「标题 + 概要 + 正文」模式下读出来）
  String content;

  /// 进入页面 / 上次保存时的标题与概要，用于「未保存」判断与写回定位
  String savedTitle;
  String savedSummary;

  OutlineListenSegment({
    required this.chapterId,
    required this.eventIndex,
    required this.isMajor,
    required String title,
    required String summary,
    required this.content,
  })  : titleCtrl = TextEditingController(text: title),
        summaryCtrl = TextEditingController(text: summary),
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

  /// 卡片上的类型文案，如「大事件3」
  String get typeLabel => isMajor ? '大事件$eventIndex' : '小事件$eventIndex';

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
