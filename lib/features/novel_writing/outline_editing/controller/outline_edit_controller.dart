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

/// 新事件的标题占位：卡片标题留空会让大纲正文写出「大事件3：」这类断行，
/// 下次解析时该行不成事件、整块消失，所以新增时就给一个可编辑的占位标题。
const String kNewEventTitle = '新事件';

/// 「大纲编辑」控制器（只编辑大纲，不改动正文）。
///
/// 负责：
/// - 所选章节的大纲草稿（每章一份 OutlineEditDraft，标题 + 概要）
/// - **增删事件**：在所选事件之间插入新的大事件 / 小事件，或删除某个事件；
///   改动同时落在大纲正文与该事件上，保证「大纲转章节」重解析时结构一致
/// - 保存：只写 outline_chapters 的标题/概要（新增行 INSERT、删除行 DELETE、
///   序号批量重编），并把改动同步回大纲正文文本
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

  /// 全部章节是否已读到（[_loadContext] 完成）。
  /// 读回来之前 [allChapters] 为空，此时增删事件不去猜全篇结构。
  bool _contextLoaded = false;

  /// 大事件序号表（chapter.id → 序号，只数大事件），与正文里的「大事件N」一致。
  /// 与 [allChapters] 一起在 [_loadContext] 里建好——编辑页只拿到勾选的几章，
  /// 单看 [drafts] 会把大事件编成 1、2……，和正文对不上。
  Map<int, int?> majorNumbersById = const {};

  /// 某章的大事件序号；小事件 / 尚未读出全篇章节时为 null
  int? majorNumberOf(OutlineChapter chapter) {
    final id = chapter.id;
    return id == null ? null : majorNumbersById[id];
  }

  /// 某张草稿卡片的大事件序号（按行 id 兜底按局部 id 反查）。
  ///
  /// 只信 [majorNumbersById] 是错的：它是**按行 id** 键的，只在
  /// [_loadContext] 读完全篇章节后才建好；而增删事件会当场改变「第几个大事件」，
  /// 在上下文还没读完（或读失败）时查表拿到的是**旧编号**，界面上就会出现
  /// 「新加的大事件是 2、后面的丙也还是 2」。所以先按当前草稿顺序现算，
  /// 算得到就以它为准；只有这张卡片不在本次编辑范围内时才回退查表。
  int? majorNumberOfDraft(OutlineEditDraft draft) {
    final local = _localMajorNumbers()[draft.localId];
    if (local != null) return local;
    final id = draft.chapterId;
    return id == 0 ? null : majorNumbersById[id];
  }

  /// 本次会话内的大事件序号（局部 id → 序号），新增行还没入库时用它显示序号
  Map<int, int> _localMajorNumbers() {
    final map = <int, int>{};
    var seq = 0;
    for (final d in drafts) {
      if (d.isMajor) map[d.localId] = ++seq;
    }
    return map;
  }

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

  /// AI 生成时额外注入「同批勾选的其他事件」：AI 面板上的开关，默认关闭
  /// （关闭时提示词与历史版本完全一致）
  bool injectSelectedEvents = false;

  CancelToken? _cancelToken;
  bool _cancelled = false;
  bool _disposed = false;
  // 对话轮次号：新一轮对话/主动停止会让旧轮次的回调失效，
  // 避免旧请求的收尾代码清掉新一轮的生成状态
  int _chatSeq = 0;

  // ---- 结构改动（增删事件） ----
  // 草稿列表的局部 id 自增源
  int _nextLocalId = 0;
  // 本次会话删过、库里还有行的章节 id。存的是「删过哪些」而不是「现在缺哪些」：
  // 撤销把卡片恢复回来之后，保存时就不能再删它了（由 [_removedChapterIds] 现算）。
  final Set<int> _deletedChapterIds = {};

  /// 有结构改动尚未保存（新增 / 删除事件）。
  /// 与**已落库结构**比卡片数量与顺序现算：撤销回原结构后这个标记会自己
  /// 变回 false，不会留下假的「未保存」。
  bool get hasStructureChanges =>
      _savedShape != null && !_savedShape!.sameShapeAs(_takeSnapshot());

  OutlineEditDraft? get aiTargetDraft =>
      aiTargetIndex >= 0 && aiTargetIndex < drafts.length
      ? drafts[aiTargetIndex]
      : null;

  int get dirtyCount => drafts.where((d) => d.isDirty).length;

  bool get hasUnsaved => dirtyCount > 0 || hasStructureChanges;

  /// 保存时要真的 DELETE 的章节 id：删过、且**现在确实不在页面上**
  /// （撤销把卡片恢复回来之后就不该再删了）
  Set<int> get _removedChapterIds {
    final alive = drafts.map((d) => d.chapterId).toSet();
    return _deletedChapterIds.where((id) => !alive.contains(id)).toSet();
  }

  // ---- 提示词上下文 ----
  /// 前后相邻事件各注入几条（【前一事件】/【后续事件】）
  static const int _adjacentCount = 2;

  /// 「注入同批所选事件」最多注入几条：勾选过多时提示词会爆，超出部分不注入
  static const int _maxSelectedInject = 30;

  // ---- 撤销 / 反撤销 ----
  // 编辑历史：把**整页草稿列表**（含刚新增、尚未入库的卡片）快照成一份状态，
  // 连续输入合并为一步（停顿后并入撤销栈），最多保留 100 步。
  // 快照必须带上卡片本身而不只是每章的文本：新增 / 删除事件也要能撤销 /
  // 反撤销，只记文本的话撤销后新建的卡片会留在页面上。
  //
  // 三个基点各管一件事，别混用：
  // - [_historyBaseline]：**上一次改动前**的状态，压撤销栈的就是它。
  //   压「改动后」的状态等于撤销到原地，点了什么也不会发生。
  // - [_committed]：窗口内第一次改动**之后**的状态；同一段连续输入只记一个
  //   撤销起点，靠它判断这段输入有没有真的改出东西。
  // - [_savedShape]：**已落库**时的卡片结构，只用于未保存判定。
  static const int _maxHistory = 100;
  final List<_OutlineSnapshot> _undoStack = [];
  final List<_OutlineSnapshot> _redoStack = [];
  _OutlineSnapshot? _historyBaseline; // 上一次改动前的状态
  _OutlineSnapshot? _committed; // 窗口起点之后的状态
  _OutlineSnapshot? _savedShape; // 已落库结构（未保存判定用）
  Timer? _historyTimer; // 连续输入的合并计时器
  bool _applyingHistory = false; // 撤销/反撤销回写文本时不重复记录历史
  bool _pendingHistory = false; // 尚有未并入撤销栈的改动

  bool get canUndo => _undoStack.isNotEmpty || _pendingHistory;

  bool get canRedo => _redoStack.isNotEmpty && !_pendingHistory;

  /// 载入待编辑章节（仅内存，不落库）
  void init(List<OutlineChapter> chapters) {
    for (final c in chapters) {
      if (c.id == null) continue;
      drafts.add(
        OutlineEditDraft(c, localId: _nextLocalId++)
          ..onChanged = _onDraftChanged,
      );
    }
    final snap = _takeSnapshot();
    _historyBaseline = snap;
    _committed = snap;
    _savedShape = snap;
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
        // 大事件序号跟着全篇章节一起刷新（顺序与 outline_chapters.event_index 一致）
        majorNumbersById = majorEventNumbersById(allChapters);
      }
      final row = await OutlineRecordDbHelper().getById(outline.id!);
      if (row != null) {
        foreshadows = row['foreshadows'] as String? ?? '';
        storyState = row['story_state'] as String? ?? '';
        final content = row['content'] as String? ?? '';
        if (content.isNotEmpty) outlineContent = content;
      }
      _safeNotify();
    } catch (e, st) {
      // 读取失败不影响编辑，沿用进入页面时的快照；但不静默，便于排查
      debugPrint('[outline_edit] 读取大纲上下文失败：$e\n$st');
    } finally {
      _contextLoaded = true;
    }
  }

  void setAiTarget(int index) {
    if (index < 0 || index >= drafts.length || index == aiTargetIndex) return;
    aiTargetIndex = index;
    _safeNotify();
  }

  /// 开关「注入同批所选事件」（只影响之后的对话，已经发出去的请求不变）
  void setInjectSelectedEvents(bool value) {
    if (injectSelectedEvents == value) return;
    injectSelectedEvents = value;
    _safeNotify();
  }

  // ---- 增删事件 ----

  /// 删除某个事件的「影响面」：删之前界面要如实告诉用户会顺带丢什么
  ({bool hasContent, int contentLength, int childCount, int childContentCount})
  deleteImpact(OutlineEditDraft draft) {
    final at = drafts.indexOf(draft);
    var childCount = 0;
    var childContentCount = 0;
    if (draft.isMajor && at >= 0) {
      // 大事件名下的内容 = 它下面直到下一个大事件之前的小事件
      for (var i = at + 1; i < drafts.length && !drafts[i].isMajor; i++) {
        childCount++;
        if (drafts[i].hasContent) childContentCount++;
      }
    }
    return (
      hasContent: draft.hasContent,
      contentLength: draft.contentLength,
      childCount: childCount,
      childContentCount: childContentCount,
    );
  }

  /// 在 [index] 之前插入一个新事件（[index] 等于现有事件数时追加到末尾）。
  ///
  /// 返回新卡片的局部 id（页面据此把新卡片滚到可见位置）。
  /// 改动同时落在大纲正文（[insertEventIntoOutlineText] 写出标题占位行）与
  /// 草稿列表上，两者的第 N 个事件始终指同一条——否则保存时按序号写回会改错行。
  int addEvent({
    required int index,
    required bool isMajor,
    String title = '',
  }) {
    final before = _flushPendingHistory();
    final at = index.clamp(0, drafts.length);
    final eventIndex = at + 1;
    final cleanTitle = title.trim();
    final useTitle = cleanTitle.isEmpty ? kNewEventTitle : cleanTitle;

    outlineContent = insertEventIntoOutlineText(
      outlineContent,
      eventIndex: eventIndex,
      isMajor: isMajor,
      title: useTitle,
    );

    final chapter = OutlineChapter(
      outlineId: outline.id ?? 0,
      eventIndex: eventIndex,
      eventType: isMajor ? 'major' : 'minor',
      eventTitle: useTitle,
    );
    final draft = OutlineEditDraft(
      chapter,
      localId: _nextLocalId++,
      isNew: true,
    )..onChanged = _onDraftChanged;
    drafts.insert(at, draft);
    _renumberDrafts();
    _adoptChapterIntoContext(chapter, at);
    _syncAllChaptersOrder();
    _syncHistoryAfterStructureChange(before);
    _safeNotify();
    return draft.localId;
  }

  /// 删除一个事件（含它在大纲正文里的标题行与概要区）。
  ///
  /// 只有界面确认过「可以丢正文」（[deleteImpact] 已经告知用户）之后才该调用。
  /// 已写正文的行在保存时才会真的从库里 DELETE。
  void deleteEvent(OutlineEditDraft draft) {
    final at = drafts.indexOf(draft);
    if (at < 0) return;
    final before = _flushPendingHistory();
    outlineContent = removeEventFromOutlineText(
      outlineContent,
      draft.eventIndex,
    );
    drafts.removeAt(at);
    if (draft.chapterId != 0 && !draft.isNew) {
      _deletedChapterIds.add(draft.chapterId);
      allChapters.removeWhere((c) => c.id == draft.chapterId);
    }
    if (chatting) stopChat(); // 删掉的正是 AI 正在生成的那一条时别让它继续写
    draft.dispose();
    _renumberDrafts();
    _syncAllChaptersOrder();
    _syncHistoryAfterStructureChange(before);
    _safeNotify();
  }

  /// 按当前顺序重编所有草稿的事件序号
  void _renumberDrafts() {
    for (var i = 0; i < drafts.length; i++) {
      final d = drafts[i];
      if (d.eventIndex == i + 1) continue;
      d.reindex(i + 1);
    }
  }

  /// 把新增行挂进章节上下文（AI 生成要拿它算「所属大事件 / 前后事件」）
  void _adoptChapterIntoContext(OutlineChapter chapter, int at) {
    if (!_contextLoaded || allChapters.isEmpty) return;
    // 全篇章节按序号插：插在编辑页顺序的对应位置，上下文顺序才是对的
    final beforeId = at > 0 ? drafts[at - 1].chapterId : 0;
    if (beforeId != 0) {
      final hit = allChapters.indexWhere((c) => c.id == beforeId);
      if (hit >= 0) {
        allChapters.insert(hit + 1, chapter);
        return;
      }
    }
    final afterId = at + 1 < drafts.length ? drafts[at + 1].chapterId : 0;
    if (afterId != 0) {
      final hit = allChapters.indexWhere((c) => c.id == afterId);
      if (hit >= 0) {
        allChapters.insert(hit, chapter);
        return;
      }
    }
    allChapters.add(chapter);
  }

  /// 任意一张卡片文本变化：刷新页面并（合并后）记录一步历史
  void _onDraftChanged(int localId) {
    _safeNotify();
    if (_applyingHistory) return;
    // 窗口内第一次改动时记下「改动前」的状态，之后连续输入共用它：
    // 一次连续输入只留一个撤销起点。
    // 注意：回调是在新文本已经写进去之后才来的（见 [_baselineSnapshot]），
    // 所以这里不能直接 _takeSnapshot()，那样记下的是「改动后」，撤销会原地不动。
    _historyBaseline ??= _baselineSnapshot(localId);
    _pendingHistory = true;
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 600), _commitHistory);
  }

  /// 把「上一提交状态」压入撤销栈；连续输入只保留一个撤销起点
  void _commitHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
    _redoStack.clear();
    // 撤销栈里压的是**改动前**的状态（[_historyBaseline]）：
    // 压当前状态等于撤销到原地，点了什么也不会发生
    final baseline = _historyBaseline;
    _historyBaseline = null;
    final cur = _takeSnapshot();
    if (baseline != null && !baseline.sameAs(cur)) {
      _undoStack.add(baseline);
      if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    }
    _committed = cur;
    _pendingHistory = false;
  }

  /// 撤销上一步编辑（文本改动或增删事件）
  void undo() {
    if (_historyTimer != null) _commitHistory();
    if (_undoStack.isEmpty) return;
    if (chatting) stopChat(); // 撤销会把卡片列表换掉，正在生成的对话先停掉
    _redoStack.add(_takeSnapshot());
    final target = _undoStack.removeLast();
    _applySnapshot(target);
    _commitSnapshot(target);
    if (_chatTargetGone()) aiTargetIndex = 0;
    _safeNotify();
  }

  /// 反撤销（重做）刚刚撤销的编辑
  void redo() {
    if (_historyTimer != null) _commitHistory();
    if (_redoStack.isEmpty) return;
    if (chatting) stopChat();
    _undoStack.add(_takeSnapshot());
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    final target = _redoStack.removeLast();
    _applySnapshot(target);
    _commitSnapshot(target);
    if (_chatTargetGone()) aiTargetIndex = 0;
    _safeNotify();
  }

  /// 撤销 / 反撤销回到 [snap] 之后：它是新的撤销基线。
  /// 卡片结构也跟着变了时（撤销「新增」/「删除」），未保存判定基线一起跟上，
  /// 否则「已落库结构」还停在旧形状上，界面上会误报还有未保存的结构改动。
  void _commitSnapshot(_OutlineSnapshot snap) {
    _historyTimer?.cancel();
    _historyTimer = null;
    _historyBaseline = snap;
    _committed = snap;
    _pendingHistory = false;
    if (_savedShape != null && !_savedShape!.sameShapeAs(snap)) {
      _savedShape = snap;
    }
  }

  /// AI 目标是否已经不在页面上（被撤销 / 反撤销换掉了）
  bool _chatTargetGone() => aiTargetIndex >= drafts.length || aiTargetIndex < 0;

  /// 当前所有草稿的**完整**快照：卡片本身 + 标题 + 概要 + 未保存判定基线。
  /// 带上卡片是为了撤销 / 反撤销能连同「刚新增的卡片」「刚删掉的卡片」一起还原。
  _OutlineSnapshot _takeSnapshot() => _OutlineSnapshot([
    for (final d in drafts)
      _OutlineDraftState(
        localId: d.localId,
        chapter: d.chapter,
        title: d.titleCtrl.text,
        summary: d.summaryCtrl.text,
        savedTitle: d.savedTitle,
        savedSummary: d.savedSummary,
        isNew: d.isNew,
      ),
  ]);

  /// [localId] 这张卡片在**上一次改动前**的状态。
  ///
  /// 文本监听是在 `titleCtrl.text = ...` 之后才回调的，那时新文本已经写进去了，
  /// 所以「改动前的文本」只能从 [_committed] / [_redoStack] 里最近一份含这张卡片
  /// 的快照上取。取到就把文本按旧值组装成基线（卡片其余字段用现在的），
  /// 再配上一个**全新的**_OutlineSnapshot：绝不能把 [_committed] 原样当基线压栈，
  /// 后面改标题时 `chapter` 是可变对象，会把旧快照一起改脏。
  _OutlineSnapshot _baselineSnapshot(int localId) {
    String? oldTitle;
    String? oldSummary;
    var oldSavedTitle = '';
    var oldSavedSummary = '';
    var oldIsNew = false;
    for (final snap in [_committed, ..._redoStack.reversed]) {
      if (snap == null) continue;
      for (final s in snap.states) {
        if (s.localId != localId) continue;
        oldTitle = s.title;
        oldSummary = s.summary;
        oldSavedTitle = s.savedTitle;
        oldSavedSummary = s.savedSummary;
        oldIsNew = s.isNew;
        break;
      }
      if (oldTitle != null) break;
    }
    return _OutlineSnapshot([
      for (final d in drafts)
        _OutlineDraftState(
          localId: d.localId,
          chapter: d.chapter,
          title: d.localId == localId && oldTitle != null
              ? oldTitle
              : d.titleCtrl.text,
          summary: d.localId == localId && oldSummary != null
              ? oldSummary
              : d.summaryCtrl.text,
          savedTitle: d.localId == localId ? oldSavedTitle : d.savedTitle,
          savedSummary: d.localId == localId
              ? oldSavedSummary
              : d.savedSummary,
          isNew: d.localId == localId ? oldIsNew : d.isNew,
        ),
    ]);
  }

  /// 按快照重建草稿列表：文本回写，快照里有、现在没有的卡片重新建出来
  /// （反撤销「删除事件」），快照里没有的卡片释放掉（撤销「新增事件」）。
  ///
  /// 重建过程中的监听不记录历史（[_applyingHistory]）。
  void _applySnapshot(_OutlineSnapshot snap) {
    _applyingHistory = true;
    try {
      final current = <int, OutlineEditDraft>{
        for (final d in drafts) d.localId: d,
      };
      final rebuilt = <OutlineEditDraft>[];
      for (final s in snap.states) {
        var d = current.remove(s.localId);
        if (d == null) {
          d = OutlineEditDraft.restore(
            chapter: s.chapter,
            localId: s.localId,
            isNew: s.isNew,
            title: s.title,
            summary: s.summary,
            savedTitle: s.savedTitle,
            savedSummary: s.savedSummary,
          );
        } else {
          d.isNew = s.isNew;
          d.savedTitle = s.savedTitle;
          d.savedSummary = s.savedSummary;
          if (d.titleCtrl.text != s.title) d.titleCtrl.text = s.title;
          if (d.summaryCtrl.text != s.summary) d.summaryCtrl.text = s.summary;
        }
        d.onChanged = _onDraftChanged;
        rebuilt.add(d);
      }
      // 快照里没有的卡片（撤销「新增事件」）：释放掉，别再留着占位
      for (final gone in current.values) {
        gone.dispose();
      }
      drafts
        ..clear()
        ..addAll(rebuilt);
      // 局部 id 自增源至少越过快照里的最大值，避免恢复出来的卡片与后续新增撞 id
      for (final s in snap.states) {
        if (s.localId >= _nextLocalId) _nextLocalId = s.localId + 1;
      }
    } finally {
      _applyingHistory = false;
    }
  }

  /// 结构改动（增删事件）前先把「还没并入的文本改动」落地成一步历史，
  /// 并返回**改动前**的状态（结构改完之后拿它压撤销栈）。
  ///
  /// 必须在**动结构之前**调用，而且要先取快照再 [_commitHistory]：
  /// [_commitHistory] 会把 [_historyBaseline] 清空，调完再取就只剩
  /// 「已经改完」的状态了。
  /// 结构改动（增删事件）前先把「还没并入的文本改动」落地成一步历史，
  /// 并返回**改动前**的状态（结构改完之后拿它压撤销栈）。
  ///
  /// 顺序不能颠倒：先 [_commitHistory] 把挂着的文本改动压进撤销栈，
  /// 再取快照。反过来的话，[before] 和 [_commitHistory] 内部取的
  /// 「当前状态」是同一份（都含刚改好的文本），于是这一步结构改动压进去的
  /// 是和改动后一模一样的快照 —— 点撤销原地不动，而真正的文本改动
  /// 反而被这一步挤没了。
  _OutlineSnapshot _flushPendingHistory() {
    _commitHistory();
    return _takeSnapshot();
  }


  /// 结构改动（增删事件）后把编辑历史接上。
  ///
  /// 记法与文本改动一致：把「改动前的状态」压进撤销栈，改动后的状态作为
  /// 新的撤销基线。这样撤销 / 反撤销能连同卡片本身一起还原（[undo] /
  /// [redo] 里会重建或释放卡片）。
  ///
  /// 栈里**形状与 [before] 相同**的旧快照要留着：它们的卡片集合和「刚改动前」
  /// 一致，套回页面不会出事（撤销链因此可以继续往回走，比如「先改标题 →
  /// 再加事件」仍能一步步退回）。形状不同的（多一张少一张卡片）才清掉，
  /// 那种快照套回页面就是「结构是旧的、文本是新的」。
  void _syncHistoryAfterStructureChange(_OutlineSnapshot before) {
    final cur = _takeSnapshot();
    if (!before.sameShapeAs(cur)) {
      _undoStack.removeWhere((s) => !s.sameShapeAs(before));
      _undoStack.add(before);
      if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _historyBaseline = cur;
    _committed = cur;
  }

  /// 保存所有有改动的章节大纲，返回实际保存的章节数。
  ///
  /// 只写标题与概要（outline_chapters 的 event_title / event_summary），
  /// 正文内容与生成状态不受影响；结构改动（新增 / 删除事件）另按
  /// [_saveStructure] 落库，正文与章节行始终一致。
  Future<int> saveAll() async {
    if (saving) return 0;
    final dirty = drafts.where((d) => d.isDirty).toList();
    final structureDirty = hasStructureChanges;
    if (dirty.isEmpty && !structureDirty) return 0;
    saving = true;
    saveError = '';
    _safeNotify();
    int saved = 0;
    try {
      // 1) 结构先落库：新增行入库拿到 id、删除行删掉、按最终顺序重编序号。
      //    新增行的标题 / 概要在 INSERT 时就已经写进去了（随后 markSaved 会把
      //    它们的 isDirty 清掉），所以这里要把插入数一并计入返回值，
      //    否则保存完会提示「没有需要保存的修改」。
      if (structureDirty) saved += await _saveStructure();

      // 2) 再写标题与概要（含上一步刚入库的新行），并同步回大纲正文
      for (final d in dirty) {
        if (d.chapterId == 0) continue; // 结构未保存成功时不硬写
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
      _deletedChapterIds.clear();
      // 保存后当前状态就是新的「已提交状态」与「已落库结构」
      _committed = _takeSnapshot();
      _savedShape = _committed;
    } catch (e) {
      saveError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      saving = false;
      _safeNotify();
    }
    return saved;
  }

  /// 把结构改动落库：新增行 INSERT、删除行 DELETE、其余按最终顺序重编序号。
  /// 返回**新增行数**（调用方据此汇报「保存了几章」）。
  ///
  /// 这里刻意**不删**「已写正文的事件」：带正文的行一旦删掉，正文与 AI 小结 /
  /// 剧情账本都找不回来。界面上删除带正文的事件会先确认，确认后才把行 id
  /// 放进 [_removedChapterIds]；这里只删这些已确认的行。
  Future<int> _saveStructure() async {
    final outlineId = outline.id;
    if (outlineId == null) return 0;
    final helper = OutlineChapterDbHelper();
    var inserted = 0;

    // 新增行先入库（顺序即最终顺序，正文里的占位行也是按这个顺序插的）
    for (final d in drafts) {
      if (!d.isNew || d.chapterId != 0) continue;
      final id = await helper.insertEvent(
        outlineId: outlineId,
        eventIndex: d.eventIndex,
        eventType: d.chapter.eventType,
        // 空标题回填占位标题，与大纲正文里写的标题保持一致
        eventTitle: d.title.isEmpty ? kNewEventTitle : d.title,
        eventSummary: d.summary,
      );
      _adoptInsertedId(d, id, outlineId);
      inserted++;
    }

    // 删除已确认的旧行
    for (final id in _removedChapterIds) {
      await helper.deleteById(id);
    }

    // 按最终顺序重编序号：增删之后 event_index 必须与正文里的第几个事件一致，
    // 否则下次进页面按序号写回会改错行
    final indexById = <int, int>{};
    for (var i = 0; i < drafts.length; i++) {
      final id = drafts[i].chapterId;
      if (id != 0) indexById[id] = i + 1;
    }
    await helper.updateEventIndices(indexById);
    return inserted;
  }

  /// 新增行入库后：把行 id 接回草稿与章节上下文（原对象上改，不换实例）。
  ///
  /// 不重新读库——重读会把用户在页面上还没保存的标题 / 概要冲掉，
  /// 也会把正文编辑框里的光标位置弄丢。
  void _adoptInsertedId(OutlineEditDraft draft, int id, int outlineId) {
    final chapter = draft.chapter.copyWith(
      id: id,
      outlineId: outlineId,
      eventIndex: draft.eventIndex,
    );
    draft.adoptChapter(chapter);
    draft.isNew = false;

    // 章节上下文里换成同一行，AI 生成时的「所属大事件 / 前后事件」才带得上它
    final ctxAt = allChapters.indexWhere((c) => c.id == id);
    if (ctxAt >= 0) {
      allChapters[ctxAt] = chapter;
    } else {
      allChapters.add(chapter);
      _syncAllChaptersOrder();
    }
    majorNumbersById = majorEventNumbersById(allChapters);
  }

  /// 让 [allChapters] 的序号与本次编辑后的结构一致。
  ///
  /// 增删事件后库里记的 `event_index` 会短暂与最终结构错位，
  /// 按住它排序再取「所属大事件」就会取错一条，所以这里按草稿顺序重编——
  /// 选中部分章节时编辑页与全篇的相对顺序是一致的（上一页整表按大纲正文
  /// 解析入库），因此重编后未参与编辑的章节也不会排错。
  /// [allChapters] 还没读回来时不猜结构（等读完自然是对的）。
  void _syncAllChaptersOrder() {
    if (!_contextLoaded) return;
    // 全篇章节还没读回来（或这本小说还没解析过章节）时退回草稿自己的章节：
    // 至少要保证「序号」与页面一致，否则大事件序号会按旧编号显示
    if (allChapters.isEmpty) {
      allChapters = [
        for (var i = 0; i < drafts.length; i++)
          drafts[i].chapter.copyWith(eventIndex: i + 1),
      ];
      majorNumbersById = majorEventNumbersById(allChapters);
      return;
    }
    final byId = <int, OutlineChapter>{};
    for (final c in allChapters) {
      final id = c.id;
      if (id != null) byId[id] = c;
    }
    final ordered = <OutlineChapter>[];
    for (var i = 0; i < drafts.length; i++) {
      final c = byId.remove(drafts[i].chapterId);
      if (c == null) continue;
      ordered.add(c.copyWith(eventIndex: i + 1));
      drafts[i].adoptChapter(ordered.last); // 草稿与上下文留着同一份序号
    }
    ordered.addAll(byId.values); // 未参与编辑的章节（勾选了部分章节时）
    allChapters = ordered;
    majorNumbersById = majorEventNumbersById(allChapters);
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
      // 开关打开时把「同批勾选的其他事件」也交给 AI（已注入的前后事件不重复）
      selectedEvents: aiSelectedEventsText,
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
          if (content != null && content.isNotEmpty) {
            assistant.content += content;
          }
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

  /// 所属大事件（当前事件之前最近的一个大事件），无则 null
  OutlineChapter? _parentMajor(OutlineEditDraft draft) {
    OutlineChapter? parent;
    for (final c in _orderedContext()) {
      if (c.eventIndex >= draft.eventIndex) break;
      if (c.isMajor) parent = c;
    }
    return parent;
  }

  /// 所属大事件（标题 + 概要），无则返回空串
  String _parentMajorText(OutlineEditDraft draft) {
    final parent = _parentMajor(draft);
    if (parent == null) return '';
    return _eventLine(parent).replaceFirst(RegExp(r'^【(大事件|章节)】'), '');
  }

  /// 相邻事件文本：[forward] 为后续事件，否则为前置事件；各取最近 [_adjacentCount] 条
  String _adjacentText(OutlineEditDraft draft, {required bool forward}) {
    final ordered = _orderedContext();
    final idx = ordered.indexWhere((c) => c.id == draft.chapterId);
    if (idx < 0) return '';
    final picked = <OutlineChapter>[];
    if (forward) {
      for (
        int i = idx + 1;
        i < ordered.length && picked.length < _adjacentCount;
        i++
      ) {
        picked.add(ordered[i]);
      }
    } else {
      // 从最近的往前取，插入头部保持时间顺序
      for (int i = idx - 1; i >= 0 && picked.length < _adjacentCount; i--) {
        picked.insert(0, ordered[i]);
      }
    }
    return picked.map(_eventLine).join('\n');
  }

  /// 提示词里**已经注入过**的章节 id：当前事件 + 所属大事件 + 前后各
  /// [_adjacentCount] 条。「注入同批所选事件」按它去重，
  /// 同一个事件不在提示词里出现两次。
  Set<int> _injectedContextIds(OutlineEditDraft draft) {
    final ids = <int>{draft.chapterId};
    final ordered = _orderedContext();
    final idx = ordered.indexWhere((c) => c.id == draft.chapterId);
    if (idx >= 0) {
      for (var k = 1; k <= _adjacentCount; k++) {
        final before = idx - k;
        final after = idx + k;
        if (before >= 0) {
          final id = ordered[before].id;
          if (id != null) ids.add(id);
        }
        if (after < ordered.length) {
          final id = ordered[after].id;
          if (id != null) ids.add(id);
        }
      }
    }
    final parent = _parentMajor(draft);
    if (parent?.id != null) ids.add(parent!.id!);
    return ids;
  }

  /// 同批勾选、正在编辑的其他事件文本：跳过当前事件、所属大事件与前后各
  /// [_adjacentCount] 条（它们已经在提示词里了）；勾选过多时按
  /// [_maxSelectedInject] 截断，并在提示词里说明省略了多少条。
  String _selectedEventsText(OutlineEditDraft draft) {
    final skip = _injectedContextIds(draft);
    final picked = <OutlineChapter>[];
    for (final d in drafts) {
      final c = d.chapter;
      final id = c.id;
      if (id == null || skip.contains(id)) continue;
      picked.add(c);
    }
    if (picked.isEmpty) return '';
    final head = picked.length > _maxSelectedInject
        ? picked.sublist(0, _maxSelectedInject)
        : picked;
    final text = head.map(_eventLine).join('\n');
    if (head.length == picked.length) return text;
    return '$text\n……（同批所选事件较多，其余 ${picked.length - head.length} 条未注入）';
  }

  /// 本次对话额外注入的「同批所选事件」文本：
  /// 开关关闭、或除当前事件外没有别的所选事件时为空串（提示词里就不出现该栏目）
  String get aiSelectedEventsText {
    final draft = aiTargetDraft;
    if (!injectSelectedEvents || draft == null) return '';
    return _selectedEventsText(draft);
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

/// 撤销 / 反撤销用的大纲快照：按**本次会话的卡片**（[OutlineEditDraft.localId]）
/// 记录整页草稿状态。用局部 id 而不是行 id：新增的卡片还没入库、没有行 id，
/// 撤销「新增事件」时必须认得出它。
class _OutlineSnapshot {
  /// 快照时的卡片顺序（与页面上的顺序一致）
  final List<_OutlineDraftState> states;

  const _OutlineSnapshot(this.states);

  /// 文本是否完全一致（决定要不要压一步撤销栈）
  bool sameAs(_OutlineSnapshot other) {
    if (states.length != other.states.length) return false;
    for (var i = 0; i < states.length; i++) {
      if (!states[i].sameAs(other.states[i])) return false;
    }
    return true;
  }

  /// 卡片结构（数量与顺序）是否一致。增删事件后用它把撤销栈里
  /// 「缺了 / 多了卡片」的旧快照清掉——否则撤销会把旧结构套回页面。
  bool sameShapeAs(_OutlineSnapshot other) {
    if (states.length != other.states.length) return false;
    for (var i = 0; i < states.length; i++) {
      if (states[i].localId != other.states[i].localId) return false;
    }
    return true;
  }
}

class _OutlineDraftState {
  final int localId;
  // 存一份快照：草稿上的 chapter 在重编号 / 补行 id 时会被换掉
  final OutlineChapter chapter;
  final String title;
  final String summary;
  final String savedTitle;
  final String savedSummary;
  final bool isNew;

  const _OutlineDraftState({
    required this.localId,
    required this.chapter,
    required this.title,
    required this.summary,
    required this.savedTitle,
    required this.savedSummary,
    required this.isNew,
  });

  bool sameAs(_OutlineDraftState other) =>
      localId == other.localId &&
      title == other.title &&
      summary == other.summary &&
      savedTitle == other.savedTitle &&
      savedSummary == other.savedSummary &&
      isNew == other.isNew &&
      chapter.id == other.chapter.id &&
      chapter.eventIndex == other.chapter.eventIndex &&
      chapter.eventType == other.chapter.eventType;
}
