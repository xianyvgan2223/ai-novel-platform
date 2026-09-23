import 'package:flutter/widgets.dart';
import '../../shared/domain/outline_chapter.dart';

/// 单章大纲草稿：事件标题 / 事件概要两个控制器。
///
/// 「大纲编辑」只编辑大纲（标题与概要），不涉及章节正文：
/// 保存时只写 outline_chapters 的 event_title / event_summary，
/// 正文内容与生成状态保持原样。
class OutlineEditDraft {
  /// 进入编辑时的章节快照（保留序号、类型、正文状态等原始信息）
  final OutlineChapter chapter;
  final TextEditingController titleCtrl;
  final TextEditingController summaryCtrl;

  /// 最近一次保存（或进入页面）时的标题/概要，用作未保存判定基线
  String savedTitle;
  String savedSummary;

  /// 文本变更回调：由控制器注入，用于刷新页面（未保存标记、保存按钮状态）
  VoidCallback? onChanged;

  OutlineEditDraft(this.chapter)
      : titleCtrl = TextEditingController(text: chapter.eventTitle),
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

  /// 保存成功后调用：把当前值设为新的未保存判定基线
  void markSaved() {
    savedTitle = title;
    savedSummary = summary;
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

  void _notifyChanged() => onChanged?.call();

  void dispose() {
    titleCtrl.removeListener(_notifyChanged);
    summaryCtrl.removeListener(_notifyChanged);
    titleCtrl.dispose();
    summaryCtrl.dispose();
  }
}
