import 'package:flutter/widgets.dart';
import '../../shared/domain/outline_chapter.dart';

/// 单章大纲草稿：事件标题 / 事件概要两个控制器。
///
/// 「大纲编辑」只编辑大纲（标题与概要），不涉及章节正文：
/// 保存时只写 outline_chapters 的 event_title / event_summary，
/// 正文内容与生成状态保持原样。
class OutlineEditDraft {
  /// 进入编辑时的章节快照（保留序号、类型、正文状态等原始信息）。
  ///
  /// 可变：增删事件会重编序号、保存结构时会给新增行补上行 id，
  /// 都通过 [reindex] / [adoptChapter] 换掉这一份，正文状态等信息原样保留。
  OutlineChapter chapter;
  final TextEditingController titleCtrl;
  final TextEditingController summaryCtrl;

  /// 本次编辑会话内的稳定标识。
  ///
  /// 为什么不用 [chapterId]：页面上可以**新增**事件，新增的行还没入库、
  /// 没有行 id；撤销快照若按行 id 记录状态，就认不出「刚加进来还没保存的
  /// 那一条」。本页只改这几个事件，用一个自增的局部 id 最省事，
  /// 滚动定位（`_cardKeys`）、撤销快照、AI 目标索引都按它来。
  final int localId;

  /// 是否本次新增、尚未入库（保存时决定 INSERT 还是 UPDATE）
  bool isNew;

  /// 最近一次保存（或进入页面）时的标题/概要，用作未保存判定基线
  String savedTitle;
  String savedSummary;

  /// 文本变更回调：由控制器注入，用于刷新页面（未保存标记、保存按钮状态）。
  /// 参数是**发生改动的那张卡片的局部 id**：回调是在新文本已经写进去之后
  /// 才来的，控制器要按这个 id 去上一份快照里取「改动前」的文本做撤销基线。
  ValueChanged<int>? onChanged;

  OutlineEditDraft(
    this.chapter, {
    required this.localId,
    this.isNew = false,
  })  : titleCtrl = TextEditingController(text: chapter.eventTitle),
        summaryCtrl = TextEditingController(text: chapter.eventSummary),
        savedTitle = chapter.eventTitle,
        savedSummary = chapter.eventSummary {
    titleCtrl.addListener(_notifyChanged);
    summaryCtrl.addListener(_notifyChanged);
  }

  int get chapterId => chapter.id ?? 0;

  int get eventIndex => chapter.eventIndex;

  /// 大事件是结构节点，同样只编辑标题与概要
  bool get isMajor => chapter.eventType == 'major';

  String get title => titleCtrl.text.trim();

  String get summary => summaryCtrl.text.trim();

  bool get isDirty => title != savedTitle || summary != savedSummary;

  /// 是否已写过正文（仅用于卡片上标注，本功能不改动正文）
  bool get hasContent => chapter.content.trim().isNotEmpty;

  /// 已写正文的字数（删除确认弹窗里如实告知会丢多少字）
  int get contentLength => chapter.content.trim().characters.length;

  /// 用快照数据重建这份草稿（撤销 / 反撤销时把已删掉的卡片恢复回来）。
  ///
  /// 必须连同 [savedTitle] / [savedSummary] 一起还原：未保存标记是拿
  /// 「当前文本」和「上次保存基线」比出来的，只还原文本会让撤销后的卡片
  /// 错判成「已修改」或「没修改」。
  factory OutlineEditDraft.restore({
    required OutlineChapter chapter,
    required int localId,
    required bool isNew,
    required String title,
    required String summary,
    required String savedTitle,
    required String savedSummary,
  }) {
    final draft = OutlineEditDraft(chapter, localId: localId, isNew: isNew);
    draft.titleCtrl.text = title;
    draft.summaryCtrl.text = summary;
    draft.savedTitle = savedTitle;
    draft.savedSummary = savedSummary;
    return draft;
  }

  /// 保存成功后调用：把当前值设为新的未保存判定基线
  void markSaved() {
    savedTitle = title;
    savedSummary = summary;
    isNew = false;
  }

  /// 增删事件后重编事件序号（只在内存里改，保存时统一落库）
  void reindex(int eventIndex) {
    if (chapter.eventIndex == eventIndex) return;
    chapter = chapter.copyWith(eventIndex: eventIndex);
  }

  /// 新增行入库后换上带行 id 的章节数据（正文状态等原样保留）
  void adoptChapter(OutlineChapter updated) {
    chapter = updated;
  }

  /// 用 AI 生成的内容替换事件概要（多段概要原样保留换行）
  void replaceSummary(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    summaryCtrl.text = t;
  }

  /// 把 AI 生成的内容追加到事件概要末尾（自动补换行）
  void appendSummary(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    final cur = summaryCtrl.text.trimRight();
    summaryCtrl.text = cur.isEmpty ? t : '$cur\n$t';
  }

  /// 用 AI 生成的内容替换事件标题：多行只取第一行，
  /// 并去掉模型可能带的「标题：」前缀与书名号包装
  void replaceTitle(String text) {
    var t = text.trim().split('\n').first.trim();
    t = t.replaceFirst(RegExp(r'^(标题|事件标题|章节标题)\s*[：:]\s*'), '');
    t = t.replaceAll(RegExp(r'^[《【\[]+|[》】\]]+$'), '').trim();
    if (t.isEmpty) return;
    titleCtrl.text = t;
  }

  void _notifyChanged() => onChanged?.call(localId);

  void dispose() {
    titleCtrl.removeListener(_notifyChanged);
    summaryCtrl.removeListener(_notifyChanged);
    titleCtrl.dispose();
    summaryCtrl.dispose();
  }
}
