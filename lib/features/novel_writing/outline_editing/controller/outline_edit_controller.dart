import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../shared/data/outline_chapter_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/outline_text_sync.dart';
import '../model/outline_edit_chat_message.dart';
import '../model/outline_edit_draft.dart';
import '../service/outline_edit_service.dart';

/// 「大纲编辑」控制器（只编辑大纲，不改动正文）。
///
/// 负责：
/// - 所选章节的大纲草稿（每章一份 OutlineEditDraft，标题 + 概要）
/// - 保存：只写 outline_chapters 的标题/概要，并把改动同步回大纲正文文本
/// - AI 对话：针对「AI 生成」所选的那一章，把小说设定、所属大事件、前后相邻事件、
///   剧情账本与伏笔清单交给模型流式生成**大纲文本**（不生成正文）
class OutlineEditController extends ChangeNotifier {
  final OutlineRecord outline;
  final OutlineEditService _service;

  OutlineEditController(this.outline, {OutlineEditService? service})
    : outlineContent = outline.content,
      _service = service ?? OutlineEditService();

  /// 参与编辑的章节草稿（顺序与事件序号一致）
  final List<OutlineEditDraft> drafts = [];

  /// 本小说的全部章节：AI 生成时用于取所属大事件与前后相邻事件，
  /// 即使用户只勾选了其中几章，也能拿到完整上下文
  List<OutlineChapter> allChapters = [];

  /// AI 生成的目标章节（点某张卡片的「AI 生成」时切换）
  int aiTargetIndex = 0;

  bool saving = false;
  String saveError = '';

  /// 大纲正文（标题/概要改动会合并写回其中并持久化）
  String outlineContent;

  /// 从记录中读取的最新伏笔清单 / 剧情账本（AI 上下文用）
  String foreshadows = '';
  String storyState = '';

  /// AI 对话消息（含流式中的占位助手消息）
  final List<OutlineEditChatMessage> messages = [];
  bool chatting = false;
  String chatError = '';

  CancelToken? _cancelToken;
  bool _cancelled = false;
  bool _disposed = false;
  // 对话轮次号：新一轮对话/主动停止会让旧轮次的回调失效，
  // 避免旧请求的收尾代码清掉新一轮的生成状态
  int _chatSeq = 0;

  OutlineEditDraft? get aiTargetDraft =>
      aiTargetIndex >= 0 && aiTargetIndex < drafts.length
      ? drafts[aiTargetIndex]
      : null;

  int get dirtyCount => drafts.where((d) => d.isDirty).length;

  bool get hasUnsaved => dirtyCount > 0;

  // ---- 撤销 / 反撤销 ----
  // 编辑历史：把「每一章标题 + 概要」整体快照成一份状态，
  // 连续输入合并为一步（停顿后并入撤销栈），最多保留 100 步。
  static const int _maxHistory = 100;
  final List<_OutlineSnapshot> _undoStack = [];
  final List<_OutlineSnapshot> _redoStack = [];
  _OutlineSnapshot? _committed; // 最近一次已并入撤销栈的状态
  Timer? _historyTimer; // 连续输入的合并计时器
  bool _applyingHistory = false; // 撤销/反撤销回写文本时不重复记录历史
  bool _pendingHistory = false; // 尚有未并入撤销栈的改动

  bool get canUndo => _undoStack.isNotEmpty || _pendingHistory;

  bool get canRedo => _redoStack.isNotEmpty && !_pendingHistory;

  /// 载入待编辑章节（仅内存，不落库）
  void init(List<OutlineChapter> chapters) {
    for (final c in chapters) {
      if (c.id == null) continue;
      drafts.add(OutlineEditDraft(c)..onChanged = _onDraftChanged);
    }
    _committed = _takeSnapshot();
    _loadContext();
  }

  /// 读取全部章节与记录最新字段：进入页面时传入的数据可能是列表页的快照，
  /// 期间章节生成/账本提炼可能已更新（只读，不改动正文）
  Future<void> _loadContext() async {
    if (outline.id == null) return;
    try {
      final rows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      if (rows.isNotEmpty) {
        allChapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      }
      final row = await OutlineRecordDbHelper().getById(outline.id!);
      if (row != null) {
        foreshadows = row['foreshadows'] as String? ?? '';
        storyState = row['story_state'] as String? ?? '';
        final content = row['content'] as String? ?? '';
        if (content.isNotEmpty) outlineContent = content;
      }
      _safeNotify();
    } catch (_) {
      // 读取失败不影响编辑，沿用进入页面时的快照
    }
  }

  void setAiTarget(int index) {
    if (index < 0 || index >= drafts.length || index == aiTargetIndex) return;
    aiTargetIndex = index;
    _safeNotify();
  }

  /// 任意一张卡片文本变化：刷新页面并（合并后）记录一步历史
  void _onDraftChanged() {
    _safeNotify();
    if (_applyingHistory) return;
    _pendingHistory = true;
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 600), _commitHistory);
  }

  /// 把「上一提交状态」压入撤销栈；连续输入只保留一个撤销起点
  void _commitHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
    final cur = _takeSnapshot();
    final committed = _committed;
    if (committed == null) {
      _committed = cur;
      _pendingHistory = false;
      return;
    }
    _pendingHistory = false;
    if (cur.sameAs(committed)) return;
    _undoStack.add(committed);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    _committed = cur;
    _safeNotify();
  }

  /// 撤销上一步编辑
  void undo() {
    if (_historyTimer != null) _commitHistory();
    if (_undoStack.isEmpty) return;
    _redoStack.add(_takeSnapshot());
    final target = _undoStack.removeLast();
    _applySnapshot(target);
    _committed = target;
    _pendingHistory = false;
    _safeNotify();
  }

  /// 反撤销（重做）刚刚撤销的编辑
  void redo() {
    if (_historyTimer != null) _commitHistory();
    if (_redoStack.isEmpty) return;
    _undoStack.add(_takeSnapshot());
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    final target = _redoStack.removeLast();
    _applySnapshot(target);
    _committed = target;
    _pendingHistory = false;
    _safeNotify();
  }

  /// 当前所有草稿的文本快照
  _OutlineSnapshot _takeSnapshot() {
    final states = <int, _OutlineDraftState>{};
    for (final d in drafts) {
      states[d.chapterId] = _OutlineDraftState(
        d.titleCtrl.text,
        d.summaryCtrl.text,
      );
    }
    return _OutlineSnapshot(states);
  }

  /// 回写快照文本；回写过程中的监听不记录历史
  void _applySnapshot(_OutlineSnapshot snap) {
    _applyingHistory = true;
    try {
      for (final d in drafts) {
        final s = snap.states[d.chapterId];
        if (s == null) continue;
        if (d.titleCtrl.text != s.title) d.titleCtrl.text = s.title;
        if (d.summaryCtrl.text != s.summary) d.summaryCtrl.text = s.summary;
      }
    } finally {
      _applyingHistory = false;
    }
  }

  /// 保存所有有改动的章节大纲，返回实际保存的章节数。
  /// 只写标题与概要（outline_chapters 的 event_title / event_summary），
  /// 正文内容与生成状态不受影响。
  Future<int> saveAll() async {
    if (saving) return 0;
    final dirty = drafts.where((d) => d.isDirty).toList();
    if (dirty.isEmpty) return 0;
    saving = true;
    saveError = '';
    _safeNotify();
    int saved = 0;
    try {
      for (final d in dirty) {
        // 事件标题不允许为空：空标题会让大纲文本出现「大事件1：」断行，
        // 下次解析时会被并入上一事件概要；这里回填原标题（界面同步可见）
        if (d.title.isEmpty) d.titleCtrl.text = d.savedTitle;
        final newTitle = d.title;
        final newSummary = d.summary;
        await OutlineChapterDbHelper().updateSummary(
          d.chapterId,
          newTitle,
          newSummary,
        );
        // 标题/概要改动同步回大纲正文：否则「大纲转章节」下次进入时会按
        // 大纲文本重解析，把手改的标题/概要吃回旧值
        if (newTitle != d.savedTitle || newSummary != d.savedSummary) {
          outlineContent = mergeEventIntoOutlineText(
            outlineContent,
            oldTitle: d.savedTitle,
            newTitle: newTitle,
            newSummary: newSummary,
            eventIndex: d.eventIndex,
          );
        }
        d.markSaved();
        saved++;
      }
      await _persistOutlineContent();
    } catch (e) {
      saveError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      saving = false;
      _safeNotify();
    }
    return saved;
  }

  /// 把合并后的大纲正文写回记录（其余设定字段原样回写，避免列被清空）
  Future<void> _persistOutlineContent() async {
    if (outline.id == null) return;
    await OutlineRecordDbHelper().update(outline.id!, {
      'content': outlineContent,
      'title': outline.title,
      'genre': outline.genre,
      'theme': outline.theme,
      'protagonist': outline.protagonist,
      'worldview': outline.worldview,
    });
  }

  /// 发送一条对话：把「AI 生成」目标章节的大纲上下文交给模型，流式返回大纲文本
  Future<void> sendChat(String input) async {
    final text = input.trim();
    if (text.isEmpty || chatting) return;
    final draft = aiTargetDraft;
    if (draft == null) {
      chatError = '没有可编辑的章节';
      _safeNotify();
      return;
    }
    final settings = await _service.loadSettings();
    if (_disposed) return;
    if (settings.apiKey.isEmpty) {
      chatError = '请先在设置中填写 API Key';
      _safeNotify();
      return;
    }

    final userMsg = OutlineEditChatMessage.user(text);
    final assistant = OutlineEditChatMessage.assistant()..streaming = true;
    messages.add(userMsg);
    messages.add(assistant);
    final int seq = ++_chatSeq;
    chatting = true;
    chatError = '';
    _cancelled = false;
    _cancelToken = CancelToken();
    _safeNotify();

    final requestMessages = _service.buildChatMessages(
      outline: outline,
      eventTitle: draft.title,
      eventSummary: draft.summary,
      isMajor: draft.isMajor,
      userInput: text,
      // 历史不含刚插入的占位助手消息
      history: messages.sublist(0, messages.length - 1),
      parentMajor: _parentMajorText(draft),
      prevEvents: _adjacentText(draft, forward: false),
      nextEvents: _adjacentText(draft, forward: true),
      storyState: _storyStateText(draft),
      foreshadows: foreshadows,
    );
    final apiParams = <String, dynamic>{
      'model': settings.chapterSetting.model,
      'temperature': settings.chapterSetting.temperature,
      'max_tokens': settings.chapterSetting.maxTokens,
      // 与章节生成保持一致：关闭深度思考时显式禁用，避免思考抢占输出预算
      if (!settings.chapterSetting.enableThinking)
        'thinking': {'type': 'disabled'},
    };

    try {
      await _service.streamChat(
        apiKey: settings.apiKey,
        apiParams: apiParams,
        messages: requestMessages,
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          if (seq != _chatSeq) return;
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;
          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty)
            assistant.content += content;
          final reasoning = delta['reasoning_content'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) {
            assistant.thinking += reasoning;
          }
          _safeNotify();
        },
        onDone: () {},
        onError: (msg) {
          if (seq == _chatSeq && chatError.isEmpty) chatError = msg;
        },
      );
    } catch (e) {
      if (seq == _chatSeq && chatError.isEmpty) {
        chatError = e.toString().replaceFirst('Exception: ', '');
      }
    }

    // 流式不可用或没有输出时回退一次非流式请求（与章节链路一致的兜底）
    if (seq == _chatSeq && !_cancelled && assistant.content.trim().isEmpty) {
      try {
        final fallback = await _service.chatOnce(
          apiKey: settings.apiKey,
          apiParams: apiParams,
          messages: requestMessages,
        );
        if (fallback.isNotEmpty) assistant.content = fallback;
      } catch (_) {
        // 兜底失败：交给下方统一提示
      }
    }

    if (seq != _chatSeq) return; // 已被新一轮对话/停止接管
    assistant.streaming = false;
    chatting = false;
    _cancelToken = null;
    if (assistant.content.trim().isEmpty && chatError.isEmpty && !_cancelled) {
      chatError = '未获取到内容，请重试';
    }
    _safeNotify();
  }

  /// 停止当前生成（保留已生成的部分内容）
  void stopChat() {
    if (!chatting) return;
    _cancelled = true;
    _chatSeq++; // 让旧轮次的回调与收尾全部失效
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final m in messages) {
      m.streaming = false;
    }
    chatting = false;
    _safeNotify();
  }

  /// 清空对话记录（生成中不可清空）
  void clearChat() {
    if (chatting) return;
    messages.clear();
    chatError = '';
    _safeNotify();
  }

  /// 上下文章节：优先用本小说的全部章节（DB 最新），加载失败时退回所选章节
  List<OutlineChapter> _orderedContext() {
    final list = allChapters.isNotEmpty
        ? allChapters
        : drafts.map((d) => d.chapter).toList();
    return List<OutlineChapter>.from(list)
      ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
  }

  /// 事件行文本：同一条目在本页有未保存改动时取最新值，保证 AI 看到的是当前大纲
  String _eventLine(OutlineChapter c) {
    var title = c.eventTitle;
    var summary = c.eventSummary;
    for (final d in drafts) {
      if (d.chapterId == c.id) {
        title = d.title;
        summary = d.summary;
        break;
      }
    }
    final label = c.eventType == 'major' ? '【大事件】' : '【章节】';
    return '$label${title.isEmpty ? "（未命名）" : title}：${summary.isEmpty ? "（无概要）" : summary}';
  }

  /// 所属大事件（标题 + 概要），无则返回空串
  String _parentMajorText(OutlineEditDraft draft) {
    OutlineChapter? parent;
    for (final c in _orderedContext()) {
      if (c.eventIndex >= draft.eventIndex) break;
      if (c.eventType == 'major') parent = c;
    }
    if (parent == null) return '';
    return _eventLine(parent).replaceFirst(RegExp(r'^【(大事件|章节)】'), '');
  }

  /// 相邻事件文本：[forward] 为后续事件，否则为前置事件；各取最近 2 条
  String _adjacentText(OutlineEditDraft draft, {required bool forward}) {
    const count = 2;
    final ordered = _orderedContext();
    final idx = ordered.indexWhere((c) => c.id == draft.chapterId);
    if (idx < 0) return '';
    final picked = <OutlineChapter>[];
    if (forward) {
      for (int i = idx + 1; i < ordered.length && picked.length < count; i++) {
        picked.add(ordered[i]);
      }
    } else {
      // 从最近的往前取，插入头部保持时间顺序
      for (int i = idx - 1; i >= 0 && picked.length < count; i--) {
        picked.insert(0, ordered[i]);
      }
    }
    return picked.map(_eventLine).join('\n');
  }

  /// 剧情状态：优先当前事件之前最近一章保存的账本，其次记录中的账本
  String _storyStateText(OutlineEditDraft draft) {
    OutlineChapter? prev;
    for (final c in _orderedContext()) {
      if (c.eventIndex >= draft.eventIndex) break;
      prev = c;
    }
    final prevState = prev?.storyState.trim() ?? '';
    return prevState.isNotEmpty ? prevState : storyState;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _historyTimer?.cancel();
    _historyTimer = null;
    _chatSeq++;
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final d in drafts) {
      d.dispose();
    }
    drafts.clear();
    super.dispose();
  }
}

/// 撤销 / 反撤销用的大纲快照：按章节 id 记录该章标题与概要
class _OutlineSnapshot {
  final Map<int, _OutlineDraftState> states;

  const _OutlineSnapshot(this.states);

  bool sameAs(_OutlineSnapshot other) {
    if (states.length != other.states.length) return false;
    for (final e in states.entries) {
      final o = other.states[e.key];
      if (o == null || !o.sameAs(e.value)) return false;
    }
    return true;
  }
}

class _OutlineDraftState {
  final String title;
  final String summary;

  const _OutlineDraftState(this.title, this.summary);

  bool sameAs(_OutlineDraftState other) =>
      title == other.title && summary == other.summary;
}
