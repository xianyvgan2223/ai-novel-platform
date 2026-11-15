import 'dart:async';
import 'dart:ui' show TextRange;

import 'package:flutter/foundation.dart';

import '../../shared/data/outline_chapter_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/domain/character_profile.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/outline_text_sync.dart';
import '../background/outline_listening_notification.dart';
import '../model/listening_segment.dart';
import '../service/name_ai_service.dart';
import '../service/name_finder.dart';
import '../service/outline_rename.dart';
import '../service/tts_engine.dart';
import '../service/hybrid_tts_engine.dart';

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
    OutlineListeningNotification? notification,
  }) : _engine = engine ?? HybridTtsEngine(),
       _nameAi = nameAiService ?? OutlineNameAiService(),
       _notification = notification ?? OutlineListeningNotification.instance,
       outlineContent = outline.content {
    _engine.setCallbacks(
      // 逐句朗读：一次 onDone 只代表「这一句读完了」，由这里决定是下一句
      // 还是下一个事件（见 _handleSentenceDone / _handleSegmentDone）。
      onDone: _handleSentenceDone,
      onError: _handleEngineError,
    );
  }

  final TtsEngine _engine;
  final OutlineNameAiService _nameAi;

  /// 后台朗读通知桥；单元测试可注入假实现，非 Android 平台自动 no-op。
  final OutlineListeningNotification _notification;

  TtsEngine get engine => _engine;

  /// 是否正在用本机内置离线语音（选了系统引擎且系统引擎不可用时）
  bool get usingBuiltinVoice {
    final engine = _engine;
    return engine is HybridTtsEngine && engine.usingBuiltinVoice;
  }

  /// 大纲正文（改标题 / 概要、批量改名都会合并写回其中并持久化）
  String outlineContent;

  /// 落库后的**当前**小说设定：类型 / 主题 / 主角简介 / 世界观 / 人物档案。
  ///
  /// 为什么单独存一份：[OutlineRecord] 的字段是 final（不可变），而本页的改名
  /// 可以改设定（面板上的「同时改小说设定」）。写回时一律用这里的最新值，
  /// 否则撤回改名时会把设定写回打开页面那一刻的旧值。
  late String _appliedGenre = outline.genre;
  late String _appliedTheme = outline.theme;
  late String _appliedProtagonist = outline.protagonist;
  late String _appliedWorldview = outline.worldview;

  /// 人物档案 JSON（`outline_records.characters`）——改名时名字 / 描述 / 能力 /
  /// 性格里的同名文字都要一起换，否则章节提示词注入的还是旧人设。
  late String _appliedCharacters = outline.characters;

  /// 一个事件一张卡片（顺序与事件序号一致）
  List<OutlineListenSegment> segments = [];

  /// 伏笔清单（改名时一并替换，保证提示词注入的那份也跟着改）
  ///
  /// **必须从整条记录里取**：列表页传下来的是只含小字段的摘要（见
  /// `OutlineRecordDbHelper.getAllSummaries`），`foreshadows` / `characters`
  /// 这类大字段为空；页面读库拿到完整记录后通过 [init] 的 `record` 参数补上。
  /// 不补的话保存 / 改名时 `_persistOutline` 会把这两列写成空串。
  late String foreshadows = outline.foreshadows;

  /// 朗读与显示设置
  OutlineSpeechSettings settings = const OutlineSpeechSettings();

  /// 当前朗读到第几个事件；-1 表示还没开始读
  int activeIndex = -1;

  /// 是否正在朗读
  bool playing = false;

  bool saving = false;
  String saveError = '';
  String errorMessage = '';

  /// 进页面时体检出来的语音引擎问题（空串 = 没发现问题）
  String engineHint = '';
  bool _engineChecked = false;

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

  // ─── 句子级朗读（高亮 / 每事件拖动进度共用） ─────────────────

  /// 当前事件内读到第几句（0 起）；-1 = 没开始 / 当前事件已读完
  int activeSentenceIndex = -1;

  /// 每个事件的朗读计划缓存。
  ///
  /// 句子切分按事件懒算（几百个事件 × 每事件几百字，全量预算没必要）；
  /// 朗读模式变化、卡片文本变化、列表重建时整体失效重算。
  final Map<int, SpeechPlan> _planCache = {};

  // ─── 后台朗读通知 ────────────────────────────────────────────

  /// 本次朗读是否已经向原生发过 start（决定后续 update 还是 start）。
  bool _listenTaskActive = false;

  /// 通知栏当前是否还挂着这条朗读通知（进度态或完成态）。
  bool _listenTaskNotified = false;

  // ---- 初始化 ----

  /// 从章节行建出卡片（构造后由页面调用一次）。
  ///
  /// [reload] 为 true 时还会在后台再读一次库：列表页传下来的章节可能是快照，
  /// 期间「大纲编辑」或章节生成可能已经改过。页面自己刚从库里读完时传 false，
  /// 免得同一个查询紧挨着跑两遍。
  ///
  /// [record] 是页面用 `latestOutlineRecord` 读到的**完整记录**（含正文 / 伏笔 /
  /// 人物档案 / 设定）：列表页传下来的 `OutlineRecord` 只有小字段，
  /// `content` / `foreshadows` / `characters` 都是空的，不补进来的话
  /// 保存与改名会把这几列覆盖成空串。
  void init(
    List<OutlineChapter> chapters, {
    bool reload = true,
    OutlineRecord? record,
  }) {
    if (record != null) _adoptRecordFields(record);
    segments = _buildSegments(chapters);
    _invalidateSpeechPlans();
    // 进页面时的状态就是「上一次提交状态」：第一次改动的撤回基线由它提供
    _lastCommitted = _takeSnapshot();
    _loading = false;
    notifyListeners();
    if (reload) unawaited(_reloadFromDb());
  }

  /// 采用读库拿到的最新记录字段（正文 / 小说设定 / 伏笔 / 人物档案）。
  void _adoptRecordFields(OutlineRecord record) {
    outlineContent = record.content;
    _appliedGenre = record.genre;
    _appliedTheme = record.theme;
    _appliedProtagonist = record.protagonist;
    _appliedWorldview = record.worldview;
    _appliedCharacters = record.characters;
    foreshadows = record.foreshadows;
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
    _invalidateSpeechPlans();
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
    final ordered = [...chapters]
      ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
    // 卡片上的序号按**大纲正文的写法**算（与「大纲编辑」页同一套）：
    // 大事件全篇只数大事件；小事件在所属大事件内部从 1 重新计数。不能直接用
    // eventIndex：它是所有事件的连续序号，大事件也占号，小事件会跳号
    // （大事件1 后面跟着小事件2、3……），与正文里的「○ 小事件1」对不上。
    final majorNumbers = majorEventNumbers(ordered);
    final minorNumbers = minorEventNumbers(ordered);
    final out = <OutlineListenSegment>[];
    for (var i = 0; i < ordered.length; i++) {
      final segment = _segmentForChapter(
        ordered[i],
        majorNumber: majorNumbers[i],
        minorNumber: minorNumbers[i],
      );
      segment.onChanged = () => _onSegmentChanged(segment);
      out.add(segment);
    }
    return out;
  }

  OutlineListenSegment _segmentForChapter(
    OutlineChapter c, {
    required int? majorNumber,
    required int? minorNumber,
  }) => OutlineListenSegment(
    chapterId: c.id ?? 0,
    eventIndex: c.eventIndex,
    isMajor: c.isMajor,
    majorNumber: majorNumber,
    minorNumber: minorNumber,
    title: c.eventTitle,
    summary: c.eventSummary,
    content: c.content,
  );

  // ---- 设置 ----

  /// 改朗读设置。
  ///
  /// 卡片本身与事件一一对应，所以改设置（含朗读范围 / 事件范围）**不用重建
  /// 列表**——朗读范围只影响 [OutlineListenSegment.speechText]/句子计划。
  ///
  /// 例外：**语速改了要立刻生效**——正在读的这一条直接从开头重读一遍，否则用户
  /// 拖了 3.0x 还得等当前这条读完（几十秒）才听出新速度，等于没改成。
  /// 其它设置（音调 / 朗读范围 / 事件范围 / 连读 / 循环）仍然「下一条生效」，
  /// 中途重读更烦；但「事件范围」把当前事件排除掉时，必须跳到范围内下一个事件，
  /// 否则会出现「设置说只听大事件、却在读小事件」的错位。
  void updateSettings(OutlineSpeechSettings next) {
    if (next == settings) return;
    final rateChanged = next.rate != settings.rate;
    final modeChanged = next.mode != settings.mode;
    final scopeChanged = next.scope != settings.scope;
    settings = next;
    if (modeChanged) {
      // 句子计划跟着朗读范围变：旧计划作废，当前句序号按新计划夹紧
      _invalidateSpeechPlans();
    }
    notifyListeners();
    if (rateChanged && playing && activeIndex >= 0) {
      unawaited(replayCurrent());
      return;
    }
    if (scopeChanged &&
        playing &&
        activeIndex >= 0 &&
        !isPlayableAt(activeIndex)) {
      final nextIndex = _nextPlayableIndex(activeIndex);
      unawaited(nextIndex >= 0 ? playFrom(nextIndex) : pause());
    }
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

  /// 朗读进度文案，如「第 3/28 个事件」。
  ///
  /// 「只听大 / 小事件」时只数范围内的事件：开了范围还拿全篇事件数当分母，
  /// 用户会以为「读了一半就到底了」。
  String get progressLabel {
    if (segments.isEmpty) return '暂无内容';
    final playable = playableIndices;
    if (playable.isEmpty) return '当前范围内没有可朗读的事件';
    if (activeIndex < 0) {
      return settings.scope == OutlineListenScope.all
          ? '共 ${segments.length} 个事件'
          : '共 ${playable.length} 个事件 · ${settings.scope.label}';
    }
    return '第 $activePlayableOrdinal/${playable.length} 个事件';
  }

  /// 已读完的事件数（暂停 / 停止后保留，作为「听到哪儿了」的粗略进度）
  int get spokenCount => _spokenCount;

  // ---- 句子级朗读（高亮 / 拖动进度共用） ----

  /// 某个事件的朗读计划（懒算 + 缓存）
  SpeechPlan planForIndex(int index) {
    if (index < 0 || index >= segments.length) return SpeechPlan.empty;
    return _planCache.putIfAbsent(
      index,
      () => buildSpeechPlan(segments[index], settings.mode),
    );
  }

  /// 某个事件可朗读的句数（拖动进度条的分母；0 = 没有可读内容）
  int sentenceCountForIndex(int index) => planForIndex(index).length;

  /// 当前事件可朗读的句数
  int get activeSentenceCount =>
      activeIndex < 0 ? 0 : sentenceCountForIndex(activeIndex);

  /// 当前正在读的句子（null = 没在读 / 已停下 / 当前事件读完）
  SpeechPiece? get activePiece {
    if (activeIndex < 0) return null;
    return planForIndex(activeIndex).pieceAt(activeSentenceIndex);
  }

  /// 当前句文本（播放器提示条 / 通知副文本用）
  String get activeSentenceText => activePiece?.text ?? '';

  /// 当前句序号（1 起；0 = 没有当前句）
  int get activeSentenceOrdinal =>
      activeSentenceIndex >= 0 ? activeSentenceIndex + 1 : 0;

  /// 当前事件内的句子进度（0~1，单事件拖动条用）
  double get activeSentenceProgress {
    final total = activeSentenceCount;
    if (total <= 0 || activeSentenceIndex < 0) return 0;
    return ((activeSentenceIndex + 1) / total).clamp(0.0, 1.0);
  }

  /// 整篇朗读进度（0~1）：范围内事件序号 + 事件内句子占比。
  ///
  /// 注意：**通知栏进度条不用它**——长篇大纲里全书百分比一整个事件只动不到 1%，
  /// 看起来像没有进度条；通知栏改用「当前事件内句子进度」（见
  /// `OutlineListeningNotificationContent`）。这里保留给统计 / 测试使用。
  double get overallProgress {
    final playable = playableIndices;
    if (playable.isEmpty) return 0;
    final pos = playable.indexOf(activeIndex);
    if (pos < 0) return 0;
    final total = planForIndex(activeIndex).length;
    final done = activeSentenceIndex < 0 ? 0 : activeSentenceIndex;
    final frac = total <= 0 ? 0.0 : done / total;
    return ((pos + frac) / playable.length).clamp(0.0, 1.0);
  }

  /// 范围过滤后参与朗读的事件下标（升序）
  List<int> get playableIndices => [
    for (var i = 0; i < segments.length; i++)
      if (isPlayableAt(i)) i,
  ];

  /// 这条事件在当前朗读范围里读不读
  bool isPlayableAt(int index) =>
      index >= 0 &&
      index < segments.length &&
      settings.scope.matches(segments[index].isMajor);

  int get playableCount => playableIndices.length;

  /// 当前事件在范围内是第几个（1 起；0 = 不在范围内 / 没开始）
  int get activePlayableOrdinal {
    if (activeIndex < 0) return 0;
    final idx = playableIndices.indexOf(activeIndex);
    return idx < 0 ? 0 : idx + 1;
  }

  /// 会话是否还有「值得保留」的状态：有朗读位置（含暂停 / 听完停在末尾）。
  ///
  /// 页面关闭时用它决定 controller 是转到后台会话里继续活着，还是直接释放。
  bool get isSessionNeeded => activeIndex >= 0;

  int _firstPlayableIndex() {
    for (var i = 0; i < segments.length; i++) {
      if (isPlayableAt(i)) return i;
    }
    return -1;
  }

  int _nextPlayableIndex(int after) {
    for (var i = after + 1; i < segments.length; i++) {
      if (isPlayableAt(i)) return i;
    }
    return -1;
  }

  int _previousPlayableIndex(int before) {
    for (var i = before - 1; i >= 0; i--) {
      if (isPlayableAt(i)) return i;
    }
    return -1;
  }

  void _invalidateSpeechPlans() {
    _planCache.clear();
    _clampSentenceIndex();
  }

  void _clampSentenceIndex() {
    final count = activeSentenceCount;
    if (count <= 0) {
      activeSentenceIndex = -1;
      return;
    }
    if (activeSentenceIndex < 0) activeSentenceIndex = 0;
    if (activeSentenceIndex >= count) activeSentenceIndex = count - 1;
  }

  /// 播放 / 暂停
  Future<void> toggle() async {
    if (playing) {
      await pause();
      return;
    }
    await play();
  }

  /// 播放（暂停后继续从当前句读；未开始时从范围内第一个事件开始）
  Future<void> play() async {
    if (segments.isEmpty) return;
    var target = activeIndex;
    if (target < 0 || target >= segments.length || !isPlayableAt(target)) {
      target = _firstPlayableIndex();
    }
    if (target < 0) {
      errorMessage = '当前朗读范围内没有可播放的事件';
      playing = false;
      notifyListeners();
      return;
    }
    activeIndex = target;
    final plan = planForIndex(activeIndex);
    if (plan.isEmpty) {
      // 空事件不占朗读时间：算它读完，直接走连读逻辑（与旧行为一致）
      playing = true;
      _handleSegmentDone();
      return;
    }
    if (activeSentenceIndex < 0 || activeSentenceIndex >= plan.length) {
      activeSentenceIndex = 0;
    }
    finished = false;
    playing = true;
    errorMessage = '';
    // 先把「后台继续朗读」标志立起来再发朗读请求：用户可能点完播放立刻按 Home，
    // 若等 speak 返回再设置，Activity onStop 可能先到一步把第一句停掉。
    unawaited(_setBackgroundPlayback(true));
    final started = await _speakCurrent();
    if (_disposed) return;
    if (!started) playing = false;
    unawaited(_setBackgroundPlayback(playing));
    notifyListeners();
  }

  /// 暂停：停掉引擎但**保留当前位置**（事件 + 句子都保留，再点播放从当前句继续）
  Future<void> pause() async {
    if (!playing) return;
    _speechSeq++;
    playing = false;
    await _engine.stop();
    unawaited(_setBackgroundPlayback(false));
    notifyListeners();
  }

  /// 停止并回到开头
  Future<void> stop() async {
    _speechSeq++;
    playing = false;
    finished = false;
    activeIndex = -1;
    activeSentenceIndex = -1;
    _spokenCount = 0;
    await _engine.stop();
    unawaited(_setBackgroundPlayback(false));
    notifyListeners();
  }

  /// 从第 [index] 个事件开始读（点卡片上的播放按钮）。
  ///
  /// [sentenceIndex] 用于单事件拖动条：从该事件的第几句开始读。
  Future<void> playFrom(int index, {int sentenceIndex = 0}) async {
    if (index < 0 || index >= segments.length) return;
    var target = index;
    if (!isPlayableAt(target)) {
      // 点到了范围外的事件：优先从它后面最近的可读事件开始
      final next = _nextPlayableIndex(target - 1);
      target = next >= 0 ? next : _firstPlayableIndex();
    }
    if (target < 0) return;
    _speechSeq++;
    playing = false;
    await _engine.stop();
    activeIndex = target;
    final count = sentenceCountForIndex(target);
    activeSentenceIndex = count <= 0 ? 0 : sentenceIndex.clamp(0, count - 1);
    finished = false;
    notifyListeners();
    await play();
  }

  /// 从指定事件的指定句子开始朗读（每事件拖动进度条松手时调用）
  Future<void> playFromSentence(int index, int sentenceIndex) =>
      playFrom(index, sentenceIndex: sentenceIndex);

  /// 跳到当前事件内的第 [sentenceIndex] 句（媒体通知 seekbar 拖动 / 外部调用）。
  ///
  /// 语义与页面上的句子进度条一致：
  /// - 正在朗读：从落点句继续读（停掉当前 utterance，从该句重新发声）；
  /// - 已暂停：只把位置移过去（高亮 / 通知 / 进度同步），等用户点播放再从该句继续；
  /// - 没有朗读位置、或当前事件没有句子：什么都不做。
  Future<void> seekToSentence(int sentenceIndex) async {
    if (activeIndex < 0 || activeIndex >= segments.length) return;
    final count = sentenceCountForIndex(activeIndex);
    if (count <= 0) return;
    final target = sentenceIndex.clamp(0, count - 1);
    if (playing) {
      await playFrom(activeIndex, sentenceIndex: target);
      return;
    }
    activeSentenceIndex = target;
    notifyListeners();
  }

  /// 按当前事件内的相对进度（0~1）跳句——通知进度条点击分区的事件用它。
  Future<void> seekToFraction(double fraction) async {
    if (activeIndex < 0 || activeIndex >= segments.length) return;
    final count = sentenceCountForIndex(activeIndex);
    if (count <= 0) return;
    final normalized = fraction.clamp(0.0, 1.0);
    final target = (normalized * count).floor().clamp(0, count - 1);
    await seekToSentence(target);
  }

  /// 在当前事件内相对跳 [delta] 句（通知展开视图「退 3 句 / 进 3 句」按钮）。
  ///
  /// 越界由 [seekToSentence] 统一夹紧：退到事件开头 / 进到事件最后一句为止，
  /// 不跨事件（跨事件交给上一个 / 下一个按钮，避免两个动作语义混在一起）。
  Future<void> seekBy(int delta) async {
    if (activeIndex < 0 || activeIndex >= segments.length) return;
    if (activeSentenceIndex < 0) return;
    await seekToSentence(activeSentenceIndex + delta);
  }

  /// 下一个范围内事件（到末尾：开了循环就回到第一个，否则停下并置 [finished]）
  Future<void> next() async {
    if (segments.isEmpty) return;
    final nextIndex = _nextPlayableIndex(activeIndex);
    if (nextIndex < 0) {
      if (!settings.repeat) {
        await pause();
        finished = true;
        activeSentenceIndex = -1;
        notifyListeners();
        return;
      }
      final first = _firstPlayableIndex();
      if (first < 0) return;
      await playFrom(first);
      return;
    }
    await playFrom(nextIndex);
  }

  /// 上一个范围内事件（在第一个时回到第一个重读）
  Future<void> previous() async {
    if (segments.isEmpty) return;
    final first = _firstPlayableIndex();
    if (first < 0) return;
    final prev = _previousPlayableIndex(activeIndex);
    await playFrom(prev >= 0 ? prev : first);
  }

  /// 重读当前这一个事件（从它的第一句开始）
  Future<void> replayCurrent() async {
    if (activeIndex < 0) {
      await play();
      return;
    }
    await playFrom(activeIndex);
  }

  /// 发送朗读请求（只读当前这一句）；返回是否成功开始。
  ///
  /// 逐句朗读是「高亮当前句 / 单事件拖动进度」的基础：引擎没有「读到第几个字」
  /// 的回调，把事件拆成句子依次读，每句结束时推进高亮与进度，天然精确。
  /// 句子之间的间隔对系统 TTS 只有几十毫秒，听感上就是正常的句间停顿。
  Future<bool> _speakCurrent() async {
    final segment = activeSegment;
    if (segment == null) return false;
    final plan = planForIndex(activeIndex);
    if (plan.isEmpty) {
      // 空卡片（标题、概要、正文都空）不占朗读时间：算它读完，立刻往下走
      _handleSegmentDone();
      return true;
    }
    if (activeSentenceIndex < 0) activeSentenceIndex = 0;
    if (activeSentenceIndex >= plan.length) {
      _handleSegmentDone();
      return true;
    }
    final text = plan.pieces[activeSentenceIndex].text.trim();
    if (text.isEmpty) {
      _handleSentenceDone();
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
      // 引擎起来了：进页面体检时留下的提示（可能是在引擎还没就绪时问出来的）
      // 就不该再挂着——真机上出现过「一边正常朗读、一边提示不支持中文」
      _clearEngineHint();
    }
    final seq = ++_speechSeq;
    final started = await _engine.speak(
      TtsSpeechRequest(
        text: text,
        language: settings.language,
        rate: settings.rate,
        pitch: settings.pitch,
        voiceId: settings.ttsVoice,
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

  /// 引擎报「这一句读完了」：还有下一句就继续，读完整个事件再交给连读逻辑。
  void _handleSentenceDone() {
    if (_disposed) return;
    if (!playing) {
      notifyListeners();
      return;
    }
    final plan = activeIndex >= 0
        ? planForIndex(activeIndex)
        : SpeechPlan.empty;
    if (activeSentenceIndex + 1 < plan.length) {
      activeSentenceIndex++;
      notifyListeners();
      unawaited(_continueSpeaking());
      return;
    }
    _handleSegmentDone();
  }

  /// 引擎报「这个事件读完了」：记进度，并按设置自动读下一个事件
  void _handleSegmentDone() {
    if (_disposed) return;
    // 只有「本次播放真的读完了这一个事件」才计数：用户点下一个 / 暂停时原生
    // stop 可能刚好把它读完，那种收尾不该记进「已听 N 个」
    if (playing) _spokenCount++;
    activeSentenceIndex = -1;
    if (!playing) {
      notifyListeners();
      return;
    }
    if (!settings.autoNext) {
      playing = false;
      final lastIndex = playableIndices.isEmpty ? -1 : playableIndices.last;
      finished = activeIndex >= lastIndex;
      unawaited(_setBackgroundPlayback(false));
      notifyListeners();
      return;
    }
    final lastIndex = playableIndices.isEmpty ? -1 : playableIndices.last;
    final last = activeIndex >= lastIndex;
    if (last && !settings.repeat) {
      playing = false;
      finished = true;
      unawaited(_setBackgroundPlayback(false));
      notifyListeners();
      return;
    }
    activeIndex = last
        ? _firstPlayableIndex()
        : _nextPlayableIndex(activeIndex);
    if (activeIndex < 0) {
      playing = false;
      finished = true;
      notifyListeners();
      return;
    }
    activeSentenceIndex = 0;
    notifyListeners();
    unawaited(_continueSpeaking());
  }

  /// 连读：当前位置已经推进，这里只发请求（不再走 [play] 的整段状态重置）
  Future<void> _continueSpeaking() async {
    final ok = await _speakCurrent();
    if (_disposed) return;
    if (!ok) {
      playing = false;
      unawaited(_setBackgroundPlayback(false));
      notifyListeners();
    }
  }

  void _handleEngineError(String message) {
    if (_disposed) return;
    errorMessage = message;
    playing = false;
    unawaited(_setBackgroundPlayback(false));
    notifyListeners();
  }

  Future<void> _setBackgroundPlayback(bool enabled) async {
    try {
      await _engine.setBackgroundPlayback(enabled);
    } catch (_) {
      // 后台开关是加分项：失败不影响前台朗读
    }
  }

  // ---- 后台朗读通知（Android 前台服务 + 通知栏进度） ----

  /// 每次状态变化顺带同步一次后台通知与朗读高亮。
  ///
  /// 和「一键生成大纲」一样放在 notifyListeners 这一层：播放、暂停、句子推进、
  /// 停止、听完、出错、事件范围切换都从这一个出口走，不会漏状态。
  @override
  void notifyListeners() {
    if (_disposed) return;
    _applySpeechHighlight();
    _syncListenNotification();
    super.notifyListeners();
  }

  /// 把「当前正在读的句子」高亮同步到卡片的标题 / 概要输入框。
  ///
  /// 只设置 TextEditingController 上的高亮区间（不会触发文本变更回调），
  /// 页面在这一轮重建时 EditableText 会按新区间重绘。
  void _applySpeechHighlight() {
    final active = activeIndex;
    final piece = active >= 0 ? activePiece : null;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      TextRange? titleRange;
      TextRange? summaryRange;
      if (i == active && piece != null) {
        switch (piece.part) {
          case SpeechPiecePart.title:
            if (segment.titleCtrl.text.isNotEmpty) {
              titleRange = TextRange(
                start: 0,
                end: segment.titleCtrl.text.length,
              );
            }
            break;
          case SpeechPiecePart.summary:
            summaryRange = TextRange(start: piece.start, end: piece.end);
            break;
          case SpeechPiecePart.content:
            // 正文没有编辑框：当前句显示在播放器提示条 / 通知栏里
            break;
        }
      }
      segment.titleCtrl.setHighlight(titleRange);
      segment.summaryCtrl.setHighlight(summaryRange);
    }
  }

  /// 通知栏文案：播放中 / 暂停 / 听完，以及「停在第几个事件第几句」。
  void _syncListenNotification() {
    try {
      if (finished) {
        if (!_listenTaskActive) return;
        _listenTaskActive = false;
        _listenTaskNotified = true;
        final content = OutlineListeningNotificationContent.finished(
          bookTitle: outline.title,
          eventCount: playableCount > 0 ? playableCount : segments.length,
        );
        unawaited(_notification.finish(content, success: true));
        return;
      }
      if (activeIndex < 0 || activeIndex >= segments.length) {
        if (!_listenTaskActive) return;
        _listenTaskActive = false;
        _listenTaskNotified = false;
        unawaited(_notification.cancel());
        return;
      }
      final segment = segments[activeIndex];
      final eventOrdinal = activePlayableOrdinal > 0
          ? activePlayableOrdinal
          : activeIndex + 1;
      final eventTotal = playableCount > 0 ? playableCount : segments.length;
      final sentenceTotal = activeSentenceCount;
      final sentenceOrdinal = activeSentenceOrdinal;
      final content = playing
          ? OutlineListeningNotificationContent.playing(
              bookTitle: outline.title,
              eventLabel: segment.typeLabel,
              eventOrdinal: eventOrdinal,
              eventTotal: eventTotal,
              sentenceOrdinal: sentenceOrdinal,
              sentenceTotal: sentenceTotal,
              sentence: activeSentenceText,
            )
          : OutlineListeningNotificationContent.paused(
              bookTitle: outline.title,
              eventLabel: segment.typeLabel,
              eventOrdinal: eventOrdinal,
              eventTotal: eventTotal,
              sentenceOrdinal: sentenceOrdinal,
              sentenceTotal: sentenceTotal,
              sentence: activeSentenceText,
              errorMessage: errorMessage,
            );
      _listenTaskNotified = true;
      if (!_listenTaskActive) {
        _listenTaskActive = true;
        unawaited(_notification.ensurePermission());
        unawaited(_notification.start(content));
      } else {
        _notification.update(content);
      }
    } catch (error) {
      // 通知同步是加分项：任何异常都不能反过来影响朗读
      debugPrint('[outline-listen] 同步后台通知失败：$error');
    }
  }

  /// 清掉错误提示（用户点了重试 / 关掉提示）
  void clearError() {
    if (errorMessage.isEmpty) return;
    errorMessage = '';
    notifyListeners();
  }

  /// 「重试」：先把引擎丢掉重建，再从当前位置读一次。
  ///
  /// 为什么不能只调 [play]：原生侧把引擎实例与初始化结果都缓存了，用户按提示去
  /// 系统里装好 / 启用好语音引擎再回来，光重发一次 init 拿回的还是同一个失败结果
  /// （真机复现：恢复引擎后点重试，logcat 里连一次 rebind 都没有，必须杀 App 重开）。
  /// 所以这里先 [TtsEngine.reset] 让下一次 init 真的重建引擎。
  ///
  /// 返回是否真的开始了朗读，供页面给一句反馈。
  Future<bool> retryPlay() async {
    if (_disposed) return false;
    _engineReady = false;
    await _engine.reset();
    if (_disposed) return false;
    errorMessage = '';
    if (segments.isEmpty) {
      notifyListeners();
      return false;
    }
    await play();
    if (playing) _clearEngineHint();
    return playing;
  }

  /// 打开系统「文字转语音」设置页（装引擎 / 换引擎 / 调发音人都在这）
  Future<bool> openTtsSettings() => _engine.openTtsSettings();

  /// 打开应用商店搜索页找语音引擎。
  ///
  /// 这条是本机**根本没有引擎**时唯一能自助走下去的路：系统「文字转语音」页里
  /// 首选引擎显示「无」，用户到那儿也没东西可挑（魅族 18 真机上就是这个画面）。
  Future<bool> openVoiceEngineStore({String query = '语音引擎'}) =>
      _engine.openVoiceEngineStore(query: query);

  /// 设置面板可选用的朗读引擎（跟随系统 / 内置语音 / 本机各个系统引擎）
  Future<List<TtsEngineOption>> availableEngines() =>
      _engine.availableEngines();

  /// 当前选中的引擎标识
  String get selectedEngineId => _engine.selectedEngineId;

  /// 换朗读引擎：记住选择 → 重新初始化 → 刷新体检提示。
  ///
  /// 选中「内置语音」时不需要系统引擎；选中某个系统引擎（如 eSpeak）则只走那一个，
  /// 起不来就如实报错（用户明确指定了，不该偷偷换回别的）。
  Future<bool> selectEngine(String engineId) async {
    if (_disposed || engineId == _engine.selectedEngineId) return _engineReady;
    await _engine.selectEngine(engineId);
    if (_disposed) return false;
    _engineReady = false;
    errorMessage = '';
    notifyListeners();

    final ok = await _engine.init(language: settings.language);
    if (_disposed) return false;
    _engineReady = ok;
    if (ok) {
      _clearEngineHint();
    } else {
      errorMessage = _engine.errorMessage.isNotEmpty
          ? _engine.errorMessage
          : '这个引擎没能启动，换一个试试';
    }
    notifyListeners();
    return ok;
  }

  /// 进页面时先问一次本机语音引擎情况：不可用就在页面上提前说清，而不是
  /// 等用户点了播放才报错。返回要展示的提示（可用时为空串）。
  ///
  /// 只查一次（[_engineChecked]）：这是给用户的提示，不是每次操作都要跑的检查。
  Future<String> refreshEngineHint() async {
    if (_disposed || _engineChecked) return engineHint;
    _engineChecked = true;
    engineHint = '';
    final status = await _engine.diagnose();
    if (_disposed) return '';
    if (!status.hasEngine) {
      engineHint =
          '未配置 DeepSeek API Key，DeepSeek 朗读不可用；'
          '请先到「设置」中填写 API Key 后重试';
    } else if (status.zhState == 'missing_data') {
      // 只有在**明确问出**缺中文语音包时才提示。引擎还没就绪时原生侧返回
      // unknown（不是 missing_data），这里就不会误报。
      engineHint = '${status.zhStateLabel}，朗读可能读不出中文；请点「去系统设置」下载中文语音包';
    }
    notifyListeners();
    return engineHint;
  }

  /// 清掉进页面体检的提示（引擎已经证明可用时调）
  void _clearEngineHint() {
    if (engineHint.isEmpty) return;
    engineHint = '';
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
    // 文本改了：这个事件的句子计划作废（正在读的句子保持原 utterance，
    // 高亮区间按新计划在下一句推进时自然对齐）
    _invalidateSpeechPlans();
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
  Future<void> _applyHistory(
    _HistoryEntry entry, {
    required bool toUndo,
  }) async {
    if (_applyingHistory) return;
    // 朗读中的文本马上要被换掉：先停下，免得读的是已经不存在的字
    await pause();

    _applyingHistory = true;
    try {
      _applySnapshot(toUndo ? entry.baseline : entry.after);
      // 改名是即时落库的：撤回要按**反向**映射把库（章节行 / 设定）改回去，
      // 取消撤回则要按**正向**映射再把库改回新名字。两处都不能跳过——
      // 页面上的文本由快照还原，但库里的行与小说设定不在整页快照里。
      final step = entry.step;
      if (step != null) {
        await _writeRename(toUndo ? step : step.reversed(), applyToText: false);
      }
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
    // 撤回 / 取消撤回会把卡片文本整段换掉：句子计划与高亮区间跟着重算
    _invalidateSpeechPlans();
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

  /// 落库大纲记录（正文 / 小说设定 / 伏笔清单 / 人物档案），并同步「上一次提交状态」。
  ///
  /// [_lastCommitted] 统一在这里跟上：正文可能被改名、保存、撤回三处改写，
  /// 任何一处漏掉都会让下一次改动的「改动前」快照错位（撤回退成空大纲）。
  /// **注意它在提前 return 之前就赋值**——章节行还没入库时（新大纲 / 测试环境）
  /// 不落库，但内存里的基线仍然要正确。
  Future<void> _persistOutline() async {
    _lastCommitted = _takeSnapshot();
    final id = outline.id;
    if (id == null) return;
    await OutlineRecordDbHelper().update(id, <String, dynamic>{
      'content': outlineContent,
      'title': outline.title,
      // 小说设定：改名勾了「同时改小说设定」时是替换后的新值，否则是原值
      // （一律写回当前内存值，避免把「打开页面时的快照」盖到用户刚改的设定上）
      'genre': _appliedGenre,
      'theme': _appliedTheme,
      'protagonist': _appliedProtagonist,
      'worldview': _appliedWorldview,
      // 人物档案 / 伏笔清单是大字段：读页面时必须从完整记录补进来，
      // 原样回写，不然只改个名就把它们清空了
      'characters': _appliedCharacters,
      'foreshadows': foreshadows,
    });
  }

  // ---- 一键改名 ----

  /// 小说设定的可搜索字段（类型 / 主题 / 主角简介 / 世界观 / 人物档案）
  List<OutlineSettingText> _settingTexts() => outlineSettingTexts(
    genre: _appliedGenre,
    theme: _appliedTheme,
    protagonist: _appliedProtagonist,
    worldview: _appliedWorldview,
    characters: _appliedCharacters,
  );

  /// 人物档案里的姓名（候选专名用：人物简介里的名字也要能出现在候选里）
  List<String> get characterNames => [
    for (final c
        in tryParseCharacterProfiles(_appliedCharacters) ??
            const <CharacterProfile>[])
      if (c.name.trim().isNotEmpty) c.name.trim(),
  ];

  /// 人物档案的提示词文本（AI 识别专名时一并交给模型）
  String get _charactersPromptText {
    final buf = StringBuffer();
    for (final c
        in tryParseCharacterProfiles(_appliedCharacters) ??
            const <CharacterProfile>[]) {
      final name = c.name.trim();
      if (name.isEmpty) continue;
      final extras = <String>[
        if (c.abilities.trim().isNotEmpty) '能力：${c.abilities.trim()}',
        if (c.personality.trim().isNotEmpty) '性格：${c.personality.trim()}',
      ];
      buf.writeln(
        '$name：${c.description.trim()}${extras.isEmpty ? "" : "（${extras.join("；")}）"}',
      );
    }
    return buf.toString().trim();
  }

  /// 重算候选专名（离线规则）
  void refreshNameCandidates() {
    nameCandidates = findOutlineNameCandidates(
      content: outlineContent,
      protagonist: _appliedProtagonist,
      characterNames: characterNames,
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
        characters: _charactersPromptText,
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

  /// 查一个词在大纲正文 **与小说设定**里的命中（替换面板的实时预览用）。
  ///
  /// 设定里的命中单独放在 [OutlineRenameResult.settingHits]：面板要如实显示
  /// 「世界观 / 主题 / 主角简介 / 人物档案里也有几处」，并在用户勾选
  /// 「同时改小说设定」后一起替换。
  OutlineRenameResult checkName(String source) =>
      findRenameHits(outlineContent, source, settings: _settingTexts());

  /// 一键改名：把 [rules]（原文 → 新文）应用到**大纲正文 + 所有章节行 +
  /// 伏笔清单 + 内存里的卡片**，并即时落库。
  ///
  /// [updateSettings] 为 true 时连**小说设定**一起改（类型 / 主题 / 主角简介 /
  /// 世界观 / 人物档案里的同样的名字）——这几处以前完全搜不到也改不了，
  /// 改名后提示词里注入的还是旧名字。默认 false：设定是作者自己填的，
  /// 只改大纲不改设定是一个合理的选择（例如设定里写的是笔名 / 别名）。
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

    // 处数按**实际会被替换**的范围统计：勾了「同时改小说设定」才把设定算进来
    var count = 0;
    for (final s in mapping.keys) {
      count += findRenameHits(
        outlineContent,
        s,
        settings: updateSettings ? _settingTexts() : const [],
      ).totalCount;
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
  /// [applyToText] 为 false 时**不动内存里的正文 / 卡片文本**，只按映射重算
  /// 设定、章节行与库：撤回 / 取消撤回时整页快照已经把这些文本还原过了，
  /// 再改一次会让正文来回打转（伏笔清单同样已由快照还原，这里也不重复替换）。
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
      // 文本整体变了：句子计划与高亮区间都要按新文本重算
      _invalidateSpeechPlans();
    }

    // 小说设定：类型 / 主题 / 主角简介 / 世界观 / 人物档案
    // （勾了「同时改小说设定」才动；撤回 / 取消撤回同样按反向 / 正向映射走这里）
    if (step.includeSettings) {
      final next = renameSettingValues(
        genre: _appliedGenre,
        theme: _appliedTheme,
        protagonist: _appliedProtagonist,
        worldview: _appliedWorldview,
        characters: _appliedCharacters,
        mapping: mapping,
      );
      _appliedGenre = next.genre;
      _appliedTheme = next.theme;
      _appliedProtagonist = next.protagonist;
      _appliedWorldview = next.worldview;
      _appliedCharacters = next.characters;
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
      characterNames: characterNames,
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
    _planCache.clear();
    // 控制器被丢弃（页面关闭且没有后台会话）时：关掉「后台继续朗读」开关、
    // 停掉 TTS、清掉通知，避免留下没有主人的声音 / 通知。
    unawaited(_engine.setBackgroundPlayback(false));
    _listenTaskActive = false;
    if (_listenTaskNotified) {
      _listenTaskNotified = false;
      unawaited(_notification.cancel());
    }
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

  const _HistoryEntry({required this.baseline, required this.after, this.step});
}
