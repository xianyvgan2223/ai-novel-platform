import 'package:flutter/widgets.dart';
import '../../shared/domain/outline_chapter.dart';

/// 单章编辑草稿：事件标题 / 事件概要 / 正文三个控制器 + 撤回前进历史。
///
/// 多章编辑时每章一份草稿常驻内存，切换章节不丢失未保存内容；
/// 是否「有修改」以最近一次保存（[markSaved]）后的值为基线比较。
class OutlineEditDraft {
  /// 撤回/前进最多保留的快照数
  static const int _maxHistory = 100;

  /// 进入编辑时的章节快照（保留 id / 序号 / 类型 / AI 小结 / 账本等原始信息）
  final OutlineChapter chapter;
  final TextEditingController titleCtrl;
  final TextEditingController summaryCtrl;
  final TextEditingController contentCtrl;

  /// 最近一次保存（或进入页面）时的事件标题/概要/正文，用作未保存判定基线
  String savedTitle;
  String savedSummary;
  String savedContent;

  /// 文本变更回调：由控制器注入，用于刷新页面（字数、按钮可用态）
  VoidCallback? onChanged;

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  String _lastSnapshot;
  bool _restoring = false; // 撤回/前进回写文本时不重复记录历史

  OutlineEditDraft(this.chapter)
      : titleCtrl = TextEditingController(text: chapter.eventTitle),
        summaryCtrl = TextEditingController(text: chapter.eventSummary),
        contentCtrl = TextEditingController(text: chapter.content),
        savedTitle = chapter.eventTitle,
        savedSummary = chapter.eventSummary,
        savedContent = chapter.content,
        _lastSnapshot = chapter.content {
    contentCtrl.addListener(_onContentChanged);
    // 标题/概要也要能触发页面刷新（未保存标记、章节切换条与保存按钮状态）
    titleCtrl.addListener(_notifyChanged);
    summaryCtrl.addListener(_notifyChanged);
  }

  int get chapterId => chapter.id ?? 0;

  int get eventIndex => chapter.eventIndex;

  /// 大事件是结构节点（只有标题与概要），不支持编辑正文
  bool get isMajor => chapter.eventType == 'major';

  bool get isDirty =>
      titleCtrl.text.trim() != savedTitle ||
      summaryCtrl.text.trim() != savedSummary ||
      contentCtrl.text != savedContent;

  int get wordCount => contentCtrl.text.characters.length;

  bool get canUndo => _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  /// 保存成功后调用：把当前值设为新的未保存判定基线
  void markSaved() {
    savedTitle = titleCtrl.text.trim();
    savedSummary = summaryCtrl.text.trim();
    savedContent = contentCtrl.text;
  }

  /// 标题/概要变更：仅通知界面刷新
  void _notifyChanged() => onChanged?.call();

  /// 每次文本变更前把上一个快照压入撤销栈；新输入清空前进栈
  void _onContentChanged() {
    if (_restoring) return;
    final current = contentCtrl.text;
    if (current != _lastSnapshot) {
      _undoStack.add(_lastSnapshot);
      if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
      _redoStack.clear();
      _lastSnapshot = current;
    }
    onChanged?.call();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_lastSnapshot);
    _lastSnapshot = _undoStack.removeLast();
    _applySnapshot();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_lastSnapshot);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _lastSnapshot = _redoStack.removeLast();
    _applySnapshot();
  }

  /// 回写快照文本并恢复光标到末尾（不记录历史）
  void _applySnapshot() {
    _restoring = true;
    contentCtrl.text = _lastSnapshot;
    contentCtrl.selection = TextSelection.collapsed(
      offset: contentCtrl.text.length,
    );
    _restoring = false;
    onChanged?.call();
  }

  /// 在正文光标处插入 AI 生成的内容（有选中文本时替换选中部分）
  void insertIntoContent(String text) {
    if (text.isEmpty) return;
    final sel = contentCtrl.selection;
    final int start = sel.isValid ? sel.start : contentCtrl.text.length;
    final int end = sel.isValid ? sel.end : contentCtrl.text.length;
    final newText = contentCtrl.text.replaceRange(start, end, text);
    contentCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// 把 AI 生成的内容追加到正文末尾（自动补换行）
  void appendToContent(String text) {
    if (text.isEmpty) return;
    final cur = contentCtrl.text;
    final needBreak = cur.isNotEmpty && !cur.endsWith('\n');
    final newText = needBreak ? '$cur\n$text' : '$cur$text';
    contentCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }

  /// 用 AI 生成的内容整体替换正文
  void replaceContent(String text) {
    if (text.isEmpty) return;
    contentCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 用 AI 生成的内容替换事件概要
  void replaceSummary(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    summaryCtrl.text = t;
    onChanged?.call();
  }

  void dispose() {
    contentCtrl.removeListener(_onContentChanged);
    titleCtrl.removeListener(_notifyChanged);
    summaryCtrl.removeListener(_notifyChanged);
    titleCtrl.dispose();
    summaryCtrl.dispose();
    contentCtrl.dispose();
  }
}
