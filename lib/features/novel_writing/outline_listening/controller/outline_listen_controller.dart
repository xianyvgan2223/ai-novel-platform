import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../shared/data/outline_chapter_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/outline_text_sync.dart';
import '../model/listening_segment.dart';
import '../service/name_ai_service.dart';
import '../service/name_finder.dart';
import '../service/outline_rename.dart';
import '../service/tts_engine.dart';

/// 「听大纲改名」控制器：把一条大纲拆成**一个事件一张卡片**，逐事件朗读，
/// 并负责把改动写回 `outline_chapters` 与大纲正文。
///
/// 与「大纲编辑」的分工：编辑页面向「批量勾选章节、逐条改、最后统一保存」，
/// 本页面向**边听边改**——播放中随时暂停、就地改这一个事件、继续听；改名也是
/// 面向「听到第 5 个事件发现这个人名想换」这种场景，一次改完整篇。
///
/// 关键约定：
/// - 标题 / 概要的改动先落在内存，点「保存」才写库；
/// - **改名的落库是即时的**：一次改名会动几十个事件，攒着不写风险太大，
///   而用户对「一键改名」的预期本来就是「点完就好了」；
/// - 大纲正文是结构来源，因此每次写库都把改动同步回正文
///   （[mergeEventIntoOutlineText]），否则「大纲转章节」下次重解析会把改的吃回去。
class OutlineListenController extends ChangeNotifier {
  final OutlineRecord outline;

  OutlineListenController(
    this.outline, {
    TtsEngine? engine,
    OutlineNameAiService? nameAiService,
  })  : _engine = engine ?? createTtsEngine(),
        _nameAi = nameAiService ?? OutlineNameAiService(),
        outlineContent = outline.content {
    _engine.setCallbacks(
      onDone: _handleSegmentDone,
      onError: _handleEngineError,
    );
  }

  final TtsEngine _engine;
  final OutlineNameAiService _nameAi;

  TtsEngine get engine => _engine;

  /// 大纲正文（改标题 / 概要、批量改名都会合并写回其中并持久化）
  String outlineContent;

  /// 落库后的**当前**主角 / 世界观设定。
  ///
  /// 为什么单独存一份：[OutlineRecord] 的字段是 final（不可变），而本页的改名
  /// 可以改设定（面板上的「同时改小说设定」）。写回时一律用这里的最新值，
  /// 否则撤回改名时会把设定写回打开页面那一刻的旧值。
  late String _appliedProtagonist = outline.protagonist;
  late String _appliedWorldview = outline.worldview;

  /// 一个事件一张卡片（顺序与事件序号一致）
  List<OutlineListenSegment> segments = [];

  /// 伏笔清单（改名时一并替换，保证提示词注入的那份也跟着改）
  String foreshadows = '';

  /// 朗读与显示设置
  OutlineSpeechSettings settings = const OutlineSpeechSettings();

  /// 当前朗读到第几个事件；-1 表示还没开始读
  int activeIndex = -1;

  /// 是否正在朗读
  bool playing = false;

  bool saving = false;
  String saveError = '';
  String errorMessage = '';

  /// 是否读完了全部内容（自动连读走到末尾）
  bool finished = false;

  /// 上方播控区是否收起：收起后只留一个展开按钮，把屏幕让给下面的卡片
  bool playerCollapsed = false;

  /// 正在识别候选专名（AI 识别用）
  bool detectingNames = false;

  /// 改名候选（离线规则挑出来的 + AI 识别的）
  List<OutlineNameCandidate> nameCandidates = [];

  bool _loading = true;
  bool get loading => _loading;

  bool _engineReady = false;
  bool _disposed = false;

  /// 朗读连读用的轮次号：暂停 / 跳转 / 新一轮播放都会让旧回调失效
  int _speechSeq = 0;

  /// 已读完的事件数（「听到哪儿了」的粗略进度）
  int _spokenCount = 0;

  // ---- 初始化 ----

  /// 从章节行建出卡片（构造后由页面调用一次）。
  ///
  /// [reload] 为 true 时还会在后台再读一次库：列表页传下来的章节可能是快照，
  /// 期间「大纲编辑」或章节生成可能已经改过。页面自己刚从库里读完时传 false，
  /// 免得同一个查询紧挨着跑两遍。
  void init(List<OutlineChapter> chapters, {bool reload = true}) {
    segments = _buildSegments(chapters);
    // 进页面时的状态就是「上一次提交状态」：第一次改动的撤回基线由它提供
    _lastCommitted = _takeSnapshot();
    _loading = false;
    notifyListeners();
    if (reload) unawaited(_reloadFromDb());
  }

  /// 重读最新的章节与正文：进入页面时传入的可能是列表页的快照。
  ///
  /// 只在「库里多出了当前没有的事件」时才重建卡片，否则会把用户正在编辑的
  /// 文本折腾一遍（重建虽然按事件沿用文本，但没必要）。
  Future<void> _reloadFromDb() async {
    final id = outline.id;
    if (id == null) return;
    try {
      if (outlineContent.trim().isEmpty) {
        final content = await OutlineRecordDbHelper().getContentById(id);
        if (content != null && content.isNotEmpty && !_disposed) {
          outlineContent = content;
        }
      }
      final rows = await OutlineChapterDbHelper().getByOutlineId(id);
      if (rows.isEmpty || _disposed) return;
      final chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      final incoming = chapters.map((c) => c.id).whereType<int>().toSet();
      final known = segments.map((s) => s.chapterId).toSet();
      if (known.containsAll(incoming)) return; // 没有多出来的事件，不重建
      // 重建卡片会沿用用户已经改过的文本，**不该记成一次新的编辑**：
      // 后台读回来一份结构不算用户的动作，否则撤回会退到「读库前」的状态
      final pending = _pendingHistory;
      final timer = _historyTimer;
      _historyTimer = null;
      _replaceSegments(chapters);
      _pendingHistory = pending;
      _historyTimer = timer;
    } catch (e, st) {
      debugPrint('[outline_listen] 读取大纲上下文失败：$e\n$st');
    } finally {
      // 正文可能刚从库里读回来：提交基线跟着刷新，
      // 否则第一次改动算出来的「改动前」还带着空正文，撤回会退成空大纲
      if (!_disposed) _lastCommitted = _takeSnapshot();
    }
    if (!_disposed) notifyListeners();
  }

  /// 按新的章节列表重建卡片；用户在旧卡片上的未保存改动**按事件序号沿用**，
  /// 免得「后台读回来一份新结构」把正在改的字抹掉。
  void _replaceSegments(List<OutlineChapter> chapters) {
    final snapshot = <int, OutlineListenSegment>{
      for (final s in segments) s.eventIndex: s,
    };
    final rebuilt = _buildSegments(chapters);
    for (final s in rebuilt) {
      final old = snapshot[s.eventIndex];
      if (old == null) continue;
      if (old.titleCtrl.text != s.titleCtrl.text) {
        s.replaceTitle(old.titleCtrl.text);
      }
      if (old.summaryCtrl.text != s.summaryCtrl.text) {
        s.replaceSummary(old.summaryCtrl.text);
      }
      // 已保存基线也跟着沿用，否则刚改过的内容会被重新标成「未保存」
      s.savedTitle = old.savedTitle;
      s.savedSummary = old.savedSummary;
    }
    for (final s in segments) {
      s.dispose();
    }
    segments = rebuilt;
    if (segments.isEmpty) {
      activeIndex = -1;
    } else if (activeIndex >= segments.length) {
      activeIndex = segments.length - 1;
    }
    // 卡片表换了：提交基线跟着走，否则下一次改动的撤回基线会指向旧结构
    _lastCommitted = _takeSnapshot();
  }

  /// 把章节列表变成卡片列表（一个事件一张）
  List<OutlineListenSegment> _buildSegments(List<OutlineChapter> chapters) {
    final ordered = [...chapters]..sort(
      (a, b) => a.eventIndex.compareTo(b.eventIndex),
    );
    final out = <OutlineListenSegment>[];
    for (final c in ordered) {
      final segment = _segmentForChapter(c);
      segment.onChanged = () => _onSegmentChanged(segment);
      out.add(segment);
    }
    return out;
  }

  OutlineListenSegment _segmentForChapter(OutlineChapter c) =>
      OutlineListenSegment(
        chapterId: c.id ?? 0,
        eventIndex: c.eventIndex,
        isMajor: c.isMajor,
        title: c.eventTitle,
        summary: c.eventSummary,
        content: c.content,
      );

  // ---- 设置 ----

  /// 改朗读设置。卡片本身与事件一一对应，所以改设置（含朗读范围）**不用重建
  /// 列表**——朗读范围只影响 [OutlineListenSegment.speechText]。
  void updateSettings(OutlineSpeechSettings next) {
    if (next == settings) return;
    settings = next;
    notifyListeners();
  }

  /// 收起 / 展开上方播控区
  void setPlayerCollapsed(bool value) {
    if (playerCollapsed == value) return;
    playerCollapsed = value;
    notifyListeners();
  }

  // ---- 播放 ----

  OutlineListenSegment? get activeSegment =>
      activeIndex >= 0 && activeIndex < segments.length
      ? segments[activeIndex]
      : null;

  /// 朗读进度文案，如「第 3/28 个事件」
  String get progressLabel => segments.isEmpty
      ? '暂无内容'
      : (activeIndex < 0
            ? '共 ${segments.length} 个事件'
            : '第 ${activeIndex + 1}/${segments.length} 个事件');

  /// 已读完的事件数（暂停 / 停止后保留，作为「听到哪儿了」的粗略进度）
  int get spokenCount => _spokenCount;

  /// 播放 / 暂停
  Future<void> toggle() async {
    if (playing) {
      await pause();
      return;
    }
    await play();
  }

  /// 从 [activeIndex]（未开始时从第一个事件）开始朗读
  Future<void> play() async {
    if (segments.isEmpty) return;
    if (activeIndex < 0 || activeIndex >= segments.length) activeIndex = 0;
    finished = false;
    playing = true;
    errorMessage = '';
    final started = await _speakCurrent();
    if (_disposed) return;
    if (!started) playing = false;
    notifyListeners();
  }

  /// 暂停：停掉引擎但**保留当前位置**（再点播放从这一个事件开头重听）
  Future<void> pause() async {
    if (!playing) return;
    _speechSeq++;
    playing = false;
    await _engine.stop();
    notifyListeners();
  }

  /// 停止并回到开头
  Future<void> stop() async {
    _speechSeq++;
    playing = false;
    finished = false;
    activeIndex = -1;
    _spokenCount = 0;
    await _engine.stop();
    notifyListeners();
  }

  /// 从第 [index] 个事件开始读（点卡片上的播放按钮）
  Future<void> playFrom(int index) async {
    if (index < 0 || index >= segments.length) return;
    _speechSeq++;
    playing = false;
    await _engine.stop();
    activeIndex = index;
    finished = false;
    notifyListeners();
    await play();
  }

  /// 下一个事件（到末尾：开了循环就回到第一个，否则停下并置 [finished]）
  Future<void> next() async {
    if (segments.isEmpty) return;
    final last = activeIndex >= segments.length - 1;
    if (last) {
      if (!settings.repeat) {
        await pause();
        finished = true;
        notifyListeners();
        return;
      }
      await playFrom(0);
      return;
    }
    await playFrom(activeIndex + 1);
  }

  /// 上一个事件（在第一个时回到第一个重读）
  Future<void> previous() async {
    if (segments.isEmpty) return;
    await playFrom(activeIndex <= 0 ? 0 : activeIndex - 1);
  }

  /// 重读当前这一个事件
  Future<void> replayCurrent() async {
    if (activeIndex < 0) {
      await play();
      return;
    }
    await playFrom(activeIndex);
  }

  /// 发送朗读请求；返回是否成功开始
  ///
  /// 每次都从头读当前这一个事件：系统 TTS 没有「从中间继续」的能力，而且用户点
  /// 暂停多半是想改点什么，回来后从事件开头重听一遍才符合预期。
  Future<bool> _speakCurrent() async {
    final segment = activeSegment;
    if (segment == null) return false;
    final text = segment.speechText(settings.mode).trim();
    if (text.isEmpty) {
      // 空卡片（标题与概要都空）不占朗读时间：算它读完，立刻往下走
      _handleSegmentDone();
      return true;
    }
    if (!_engineReady) {
      final ok = await _engine.init(language: settings.language);
      if (_disposed) return false;
      _engineReady = ok;
      if (!ok) {
        errorMessage = _engine.errorMessage.isNotEmpty
            ? _engine.errorMessage
            : '本机没有可用的语音引擎';
        notifyListeners();
        return false;
      }
    }
    final seq = ++_speechSeq;
    final started = await _engine.speak(
      TtsSpeechRequest(
        text: text,
        language: settings.language,
        rate: settings.rate,
        pitch: settings.pitch,
      ),
    );
    if (_disposed || seq != _speechSeq) return false;
    if (!started) {
      errorMessage = _engine.errorMessage.isNotEmpty
          ? _engine.errorMessage
          : '朗读失败，请重试';
      playing = false;
      notifyListeners();
      return false;
    }
    return true;
  }

  /// 引擎报「读完了」：记进度，并按设置自动读下一个事件
  void _handleSegmentDone() {
    if (_disposed) return;
    // 只有「本次播放真的读完了这一个事件」才计数：用户点下一个 / 暂停时原生
    // stop 可能刚好把它读完，那种收尾不该记进「已听 N 个」
    if (playing) _spokenCount++;
    if (!playing) {
      notifyListeners();
      return;
    }
    if (!settings.autoNext) {
      playing = false;
      finished = activeIndex >= segments.length - 1;
      notifyListeners();
      return;
    }
    final last = activeIndex >= segments.length - 1;
    if (last && !settings.repeat) {
      playing = false;
      finished = true;
      notifyListeners();
      return;
    }
    activeIndex = last ? 0 : activeIndex + 1;
    notifyListeners();
    unawaited(_continueSpeaking());
  }

  /// 连读：当前位置已经推进，这里只发请求（不再走 [play] 的整段状态重置）
  Future<void> _continueSpeaking() async {
    final ok = await _speakCurrent();
    if (_disposed) return;
    if (!ok) {
      playing = false;
      notifyListeners();
    }
  }

  void _handleEngineError(String message) {
    if (_disposed) return;
    errorMessage = message;
    playing = false;
    notifyListeners();
  }

  /// 清掉错误提示（用户点了重试 / 关掉提示）
  void clearError() {
    if (errorMessage.isEmpty) return;
    errorMessage = '';
    notifyListeners();
  }

  // ---- 边听边改 ----

  int get dirtyCount => segments.where((s) => s.isDirty).length;

  bool get hasUnsaved => dirtyCount > 0;

  /// 卡片文本变更回调：只刷新「未保存」标记；**不在打字时打断朗读**——
  /// 正在读的那一个事件改了一半就重读，会一直被打断；下次点播放时自然从头读它。
  ///
  /// 同时记录「撤回」历史：把改过的卡片记进 [_editingKeys]，撤回基线在
  /// [_flushHistory] 里按「上一份提交状态 + 这些卡片的旧文本」现算。
  void _onSegmentChanged(OutlineListenSegment segment) {
    if (_disposed) return;
    notifyListeners();
    if (_applyingHistory) return;
    _editingKeys.add(segment.eventIndex);
    _pendingHistory = true;
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 600), _flushHistory);
  }

  // ---- 撤回 / 取消撤回 ----
  //
  // 与「大纲编辑」同一套语义：把**整页状态**（每张卡片的标题 / 概要 + 大纲正文 +
  // 伏笔清单）快照成一份历史，连续输入合并为一步（停顿 600ms 后并入撤回栈），
  // 最多 100 步。
  //
  // 一键改名也是一步历史。改名是**即时落库**的，所以撤回它不能只改内存里的字：
  // 历史里连「反向改名」一起记（[RenameStep]），撤回时把它原样改回去并再次落库，
  // 库与页面才不会说两套话。
  static const int _maxHistory = 100;
  final List<_HistoryEntry> _entries = [];
  final List<_HistoryEntry> _redoEntries = [];
  Timer? _historyTimer;

  /// **本次提交窗口内**改过的卡片（按事件序号记）。
  ///
  /// 撤回基线（「改动前」的文本）就靠它现算：文本监听是在新文本已经写进控制器
  /// 之后才回调的，那一刻页面上已经没有旧字了。
  final Set<int> _editingKeys = {};

  bool _applyingHistory = false; // 撤回 / 取消撤回回写文本时不重复记历史
  bool _pendingHistory = false; // 尚有未并入撤回栈的改动

  /// **上一次提交状态**：本次改动前那一份快照（未提交改动的撤回基线由它推出）。
  _OutlineListenSnapshot? _lastCommitted;

  bool get canUndo => _entries.isNotEmpty || _pendingHistory;

  bool get canRedo => _redoEntries.isNotEmpty && !_pendingHistory;

  /// 撤回上一步（文本改动或一键改名）
  ///
  /// 与「大纲编辑」同一套：**先把挂着的改动提交成一步**，再撤它。
  /// 少了这一步，「刚改完就点撤回」会跳过一次改动——那一步还没并入栈，
  /// 撤回会直接退回上一次。
  Future<void> undo() async {
    _flushHistory();
    if (_entries.isEmpty) return;
    final entry = _entries.removeLast();
    await _applyHistory(entry, toUndo: true);
  }

  /// 取消撤回（重做刚刚撤回的那一步）
  ///
  /// 有挂着的改动时先收尾：它让「重做分支」作废（新的改动之后不该再重做旧的）。
  Future<void> redo() async {
    if (_pendingHistory) _flushHistory();
    if (_redoEntries.isEmpty) return;
    final entry = _redoEntries.removeLast();
    await _applyHistory(entry, toUndo: false);
  }

  /// 把「上一提交状态」压入撤回栈；连续输入只保留一个撤回起点
  void _flushHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
    if (!_pendingHistory) return;
    _pendingHistory = false;
    // 压的是**改动前**的状态：压当前状态等于撤回原地，点了什么也不会发生
    final after = _takeSnapshot();
    final baseline = _buildBaseline(_editingKeys, after);
    _editingKeys.clear();
    if (baseline.sameAs(after)) return;
    _entries.add(_HistoryEntry(baseline: baseline, after: after));
    if (_entries.length > _maxHistory) _entries.removeAt(0);
    _redoEntries.clear();
    _lastCommitted = after;
  }

  /// 按「上一份提交状态 + [keys] 里那些卡片的旧文本」拼出「改动前」的整页状态。
  ///
  /// 正文与伏笔清单用**当前值**：撤回基线是给文本改动用的，而改名走
  /// [applyRenameRules] 自己压的那一步（正文与库一起管）。把提交状态里的旧正文
  /// 塞进来反而会让撤回连同「刚读回来的正文」一起退掉。
  _OutlineListenSnapshot _buildBaseline(
    Set<int> keys,
    _OutlineListenSnapshot current,
  ) {
    final committed = _lastCommitted;
    if (committed == null) return current;
    final old = <int, _SegmentState>{
      for (final s in committed.segments) s.key: s,
    };
    return _OutlineListenSnapshot(
      segments: [
        for (final s in current.segments)
          if (keys.contains(s.key)) (old[s.key] ?? s) else s,
      ],
      outlineContent: current.outlineContent,
      foreshadows: current.foreshadows,
    );
  }

  /// 撤回 / 取消撤回：把 [entry] 的目标状态装回去
  ///
  /// 注意调用顺序：**先把这一条从栈里摘下来**（调用方负责），再走这里。
  /// 若先在这里压栈再取目标，压进去的就是「改动后」的状态，撤回会原地不动。
  Future<void> _applyHistory(_HistoryEntry entry, {required bool toUndo}) async {
    if (_applyingHistory) return;
    // 朗读中的文本马上要被换掉：先停下，免得读的是已经不存在的字
    await pause();

    _applyingHistory = true;
    try {
      _applySnapshot(toUndo ? entry.baseline : entry.after);
      // 只有**撤回**才需要动库：改名是即时落库的，撤回它得按反向改名把库一起
      // 改回去；而「取消撤回」回到的 [after] 正是当初已经写进库的状态，再写一次
      // 反而会把刚撤回的结果又改回去。
      final step = entry.step;
      if (toUndo && step != null) await _writeRename(step, applyToText: false);
      _lastCommitted = _takeSnapshot();
      if (toUndo) {
        _redoEntries.add(entry);
      } else {
        _entries.add(entry);
      }
    } finally {
      _applyingHistory = false;
      notifyListeners();
    }
  }

  /// 整页状态快照：每张卡片的标题 / 概要 / 已保存基线 + 大纲正文 + 伏笔清单。
  ///
  /// 带上「已保存」基线，是为了撤回后**未保存标记也跟着回到当时的样子**：
  /// 只还原文本的话，撤回一个「已保存过的改动」会把它重新显示成「未保存」。
  _OutlineListenSnapshot _takeSnapshot() => _OutlineListenSnapshot(
    segments: [
      for (final s in segments)
        _SegmentState(
          key: s.eventIndex,
          title: s.titleCtrl.text,
          summary: s.summaryCtrl.text,
          savedTitle: s.savedTitle,
          savedSummary: s.savedSummary,
          content: s.content,
        ),
    ],
    outlineContent: outlineContent,
    foreshadows: foreshadows,
  );

  void _applySnapshot(_OutlineListenSnapshot snapshot) {
    final byKey = <int, _SegmentState>{
      for (final s in snapshot.segments) s.key: s,
    };
    for (final s in segments) {
      final state = byKey[s.eventIndex];
      if (state == null) continue;
      s.replaceTitle(state.title);
      s.replaceSummary(state.summary);
      s.savedTitle = state.savedTitle;
      s.savedSummary = state.savedSummary;
      s.content = state.content;
    }
    outlineContent = snapshot.outlineContent;
    foreshadows = snapshot.foreshadows;
  }

  /// 清理历史合并计时器（页面退出前调用，免得 Timer 挂在已销毁的控制器上）
  void cancelPendingHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
  }

  // ---- 保存 ----

  /// 保存所有改动：事件标题 / 概要写回 `outline_chapters`，改动合并回大纲正文
  /// （与「大纲编辑」同一套定位规则，见 [mergeEventIntoOutlineText]）。
  /// 返回实际写入的事件数；失败时 [saveError] 有原因。
  Future<int> saveAll() async {
    if (saving) return 0;
    final dirty = segments.where((s) => s.isDirty).toList();
    if (dirty.isEmpty) return 0;
    saving = true;
    saveError = '';
    notifyListeners();

    var saved = 0;
    try {
      final helper = OutlineChapterDbHelper();
      for (final s in dirty) {
        final oldTitle = s.savedTitle;
        // 标题不允许为空：空标题会让大纲正文出现「大事件1：」断行，
        // 下次解析时该行不成事件、整块消失（与「大纲编辑」同一处理）。
        // 回填原标题的同时**把输入框也补回去**，否则页面上那张卡片看起来还是空的。
        final title = s.title.isEmpty ? oldTitle : s.title;
        if (s.title.isEmpty) s.replaceTitle(oldTitle);
        final summary = s.summary;

        if (s.canPersist) {
          await helper.updateSummary(s.chapterId, title, summary);
        }
        outlineContent = mergeEventIntoOutlineText(
          outlineContent,
          oldTitle: oldTitle,
          newTitle: title,
          newSummary: summary,
          eventIndex: s.eventIndex,
        );
        s.savedTitle = title;
        s.savedSummary = summary;
        s.markSaved();
        saved++;
      }
      await _persistOutline();
    } catch (e) {
      saveError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      saving = false;
      notifyListeners();
    }
    return saved;
  }

  /// 落库大纲记录（正文 / 设定 / 伏笔清单），并同步「上一次提交状态」。
  ///
  /// [_lastCommitted] 统一在这里跟上：正文可能被改名、保存、撤回三处改写，
  /// 任何一处漏掉都会让下一次改动的「改动前」快照错位（撤回退成空大纲）。
  /// **注意它在提前 return 之前就赋值**——章节行还没入库时（新大纲 / 测试环境）
  /// 不落库，但内存里的基线仍然要正确。
  Future<void> _persistOutline({
    String? protagonist,
    String? worldview,
  }) async {
    _appliedProtagonist = protagonist ?? _appliedProtagonist;
    _appliedWorldview = worldview ?? _appliedWorldview;
    _lastCommitted = _takeSnapshot();
    final id = outline.id;
    if (id == null) return;
    await OutlineRecordDbHelper().update(id, <String, dynamic>{
      'content': outlineContent,
      'title': outline.title,
      'genre': outline.genre,
      'theme': outline.theme,
      // 设定字段：改名勾了「同时改小说设定」时写新值，否则写当前值（原样回写）
      'protagonist': _appliedProtagonist,
      'worldview': _appliedWorldview,
      'foreshadows': foreshadows,
    });
  }

  // ---- 一键改名 ----

  /// 重算候选专名（离线规则）
  void refreshNameCandidates() {
    nameCandidates = findOutlineNameCandidates(
      content: outlineContent,
      protagonist: _appliedProtagonist,
    );
    notifyListeners();
  }

  /// AI 辅助识别：结果与离线候选合并（**已存在的候选不重复**）
  Future<int> detectNamesWithAi() async {
    if (detectingNames) return 0;
    detectingNames = true;
    notifyListeners();
    var added = 0;
    try {
      final found = await _nameAi.detect(
        content: outlineContent,
        title: outline.title,
        protagonist: _appliedProtagonist,
        worldview: _appliedWorldview,
      );
      final known = nameCandidates.map((c) => c.text).toSet();
      final fresh = found.where((c) => known.add(c.text)).toList();
      nameCandidates = [...nameCandidates, ...fresh];
      added = fresh.length;
    } catch (e, st) {
      debugPrint('[outline_listen] AI 识别专名失败：$e\n$st');
    } finally {
      detectingNames = false;
      notifyListeners();
    }
    return added;
  }

  /// 查一个词在大纲里的命中（替换面板的实时预览用）
  OutlineRenameResult checkName(String source) =>
      findRenameHits(outlineContent, source);

  /// 一键改名：把 [rules]（原文 → 新文）应用到**大纲正文 + 所有章节行 +
  /// 伏笔清单 + 内存里的卡片**，并即时落库。
  ///
  /// [updateSettings] 为 true 时连**小说设定**一起改（主角 / 世界观等字段里的
  /// 同样的名字）。默认 false：设定是作者自己填的，只改大纲不改设定是一个
  /// 合理的选择（例如设定里写的是笔名 / 别名），所以交给用户勾。
  ///
  /// 返回替换处数与「反向改名」（供撤回 / 取消撤回原样改回来）。
  Future<({int count, RenameStep reverse})> applyRenameRules(
    List<({String source, String target})> rules, {
    bool updateSettings = false,
  }) async {
    final mapping = <String, String>{};
    for (final r in rules) {
      final s = r.source.trim();
      final t = r.target.trim();
      if (s.isEmpty || t.isEmpty || s == t) continue;
      if (!mapping.containsKey(s)) mapping[s] = t;
    }
    if (mapping.isEmpty) {
      return (count: 0, reverse: RenameStep.empty());
    }

    // 步骤 1：先取「改名之前」的整页状态当基线，**再**把挂着的文本改动收尾。
    //
    // 顺序不能颠倒：[_flushHistory] 把挂着的改动并成一步之后，页面上就已经是
    // 「改过」的状态了，那时再取基线，改名的撤回会退成「改动后」。
    // 基线必须从**当前**状态出发，不能直接拿 [_lastCommitted]：它可能落后于本页
    // （正文是进页面后从库里异步读回来的）。
    final baseline = _takeSnapshot();
    _flushHistory();

    // 处数用改名前的正文统计
    var count = 0;
    for (final s in mapping.keys) {
      count += findRenameHits(outlineContent, s).totalCount;
    }

    final step = RenameStep(
      mapping: mapping,
      includeSettings: updateSettings,
      count: count,
    );
    // 步骤 2：把改名落到页面上并拿到**反向改名**，历史里存的就是它：
    // 撤回 / 取消撤回都只需「再执行一次这一步」。
    final reverse = await _writeRename(step);
    // 步骤 3：这一步历史压在最上面。挂着的文本改动（如果有）在步骤 1 里已经
    // 成了它下面独立的一步——顺序不能反，否则「撤回一次」会把两件事一起退掉。
    _pendingHistory = true;
    _entries.add(
      _HistoryEntry(baseline: baseline, after: _takeSnapshot(), step: reverse),
    );
    _pendingHistory = false;
    if (_entries.length > _maxHistory) _entries.removeAt(0);
    _redoEntries.clear();
    notifyListeners();
    return (count: count, reverse: reverse);
  }

  /// 把 [step] 的改名真正落到「大纲正文 + 伏笔清单 + 设定 + 章节行 + 卡片」上，
  /// 并即时落库。返回它的**反向改名**（用于撤回 / 取消撤回）。
  ///
  /// [applyToText] 为 false 时**不动内存里的文本**，只按映射重算设定与库：
  /// 撤回时整页快照已经把文本还原过了，再改一次会让正文来回打转。
  ///
  /// 章节行始终按行 id 改：撤回到的那份快照里卡片文本是对的，但库里的行还写着
  /// 改名后的名字，不写回去下次打开就变回来了。
  Future<RenameStep> _writeRename(
    RenameStep step, {
    bool applyToText = true,
  }) async {
    final mapping = step.mapping;
    final reverse = <String, String>{};
    for (final entry in mapping.entries) {
      // 新名字已经存在时不能盲目反向替换（会撞名），这种情况交给快照兜底
      if (mapping.containsKey(entry.value)) continue;
      reverse[entry.value] = entry.key;
    }

    if (applyToText) {
      outlineContent = renameInOutlineText(outlineContent, mapping);
      foreshadows = renameInOutlineText(
        foreshadows,
        mapping,
        fallbackToPlainText: true,
      );
      for (final s in segments) {
        s.renameAll((text) => _replaceAll(text, mapping));
        s.markSaved();
      }
    } else {
      foreshadows = renameInOutlineText(
        foreshadows,
        mapping,
        fallbackToPlainText: true,
      );
    }

    // 设定字段：改了设定才动它，其余字段原样回写
    if (step.includeSettings) {
      _appliedProtagonist = _replaceAll(_appliedProtagonist, mapping);
      _appliedWorldview = _replaceAll(_appliedWorldview, mapping);
    }

    // 章节行（改名不动结构，序号不变，按行 id 直接写回）
    final helper = OutlineChapterDbHelper();
    final id = outline.id;
    if (id != null) {
      final rows = await helper.getByOutlineId(id);
      for (final row in rows) {
        final chapter = OutlineChapter.fromMap(row);
        final chapterId = chapter.id;
        if (chapterId == null) continue;
        final title = _replaceAll(chapter.eventTitle, mapping);
        final summary = _replaceAll(chapter.eventSummary, mapping);
        if (title == chapter.eventTitle && summary == chapter.eventSummary) {
          continue;
        }
        await helper.updateSummary(chapterId, title, summary);
      }
    }

    await _persistOutline();
    nameCandidates = findOutlineNameCandidates(
      content: outlineContent,
      protagonist: _appliedProtagonist,
    );
    return RenameStep(
      mapping: reverse,
      includeSettings: step.includeSettings,
      count: step.count,
    );
  }

  String _replaceAll(String text, Map<String, String> mapping) {
    var out = text;
    for (final entry in mapping.entries) {
      if (!out.contains(entry.key)) continue;
      out = out.replaceAll(entry.key, entry.value);
    }
    return out;
  }

  // ---- 释放 ----

  @override
  void dispose() {
    _disposed = true;
    _speechSeq++;
    cancelPendingHistory();
    for (final s in segments) {
      s.dispose();
    }
    segments = [];
    unawaited(_engine.dispose());
    super.dispose();
  }
}

/// 一步「一键改名」：原文 → 新文的映射 + 是否连小说设定一起改。
///
/// 历史里存的是它的**反向**版本（[reversed]），于是「撤回」与「取消撤回」都能
/// 用同一句话实现：再执行一次这一步。
@immutable
class RenameStep {
  final Map<String, String> mapping;
  final bool includeSettings;
  final int count;

  const RenameStep({
    required this.mapping,
    required this.includeSettings,
    required this.count,
  });

  const RenameStep.empty()
      : mapping = const {},
        includeSettings = false,
        count = 0;

  /// 反向映射（新文 → 原文）。
  ///
  /// 新名字与某个原文撞名时**跳过那一条**：`甲→乙`、`乙→丙` 同时改过之后，
  /// 盲目反向替换会把本来就叫「乙」的那位改成「甲」。这种少见情况由撤回时的
  /// 整页快照兜底（页面文本一定正确，只是库里那一条名字不会被改回来）。
  RenameStep reversed() => RenameStep(
    mapping: {
      for (final e in mapping.entries)
        if (!mapping.containsKey(e.value)) e.value: e.key,
    },
    includeSettings: includeSettings,
    count: count,
  );
}

/// 整页历史快照：每张卡片的文本 + 大纲正文 + 伏笔清单
@immutable
class _OutlineListenSnapshot {
  final List<_SegmentState> segments;
  final String outlineContent;
  final String foreshadows;

  const _OutlineListenSnapshot({
    required this.segments,
    required this.outlineContent,
    required this.foreshadows,
  });

  bool sameAs(_OutlineListenSnapshot other) {
    if (outlineContent != other.outlineContent ||
        foreshadows != other.foreshadows ||
        segments.length != other.segments.length) {
      return false;
    }
    for (var i = 0; i < segments.length; i++) {
      if (!segments[i].sameAs(other.segments[i])) return false;
    }
    return true;
  }
}

/// 单张卡片快照（按事件序号 [key] 认卡片）
@immutable
class _SegmentState {
  final int key;
  final String title;
  final String summary;
  final String savedTitle;
  final String savedSummary;
  final String content;

  const _SegmentState({
    required this.key,
    required this.title,
    required this.summary,
    required this.savedTitle,
    required this.savedSummary,
    required this.content,
  });

  bool sameAs(_SegmentState other) =>
      key == other.key &&
      title == other.title &&
      summary == other.summary &&
      savedTitle == other.savedTitle &&
      savedSummary == other.savedSummary &&
      content == other.content;
}

/// 撤回栈 / 取消撤回栈里的一步
@immutable
class _HistoryEntry {
  /// 改动**之前**的整页状态（压栈的就是它：压「改动后」等于撤回原地）
  final _OutlineListenSnapshot baseline;

  /// 改动**之后**的整页状态（取消撤回时回到它）
  final _OutlineListenSnapshot after;

  /// 这一步是「一键改名」时，存它的**反向改名**（撤回时再执行一次）；
  /// 普通文本改动为 null（状态快照已经足够）
  final RenameStep? step;

  const _HistoryEntry({
    required this.baseline,
    required this.after,
    this.step,
  });
}
