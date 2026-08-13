import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../service/outline_service.dart';
import '../../shared/domain/outline_setting.dart';
import '../../shared/domain/outline_record.dart';

/// 大纲生成控制器，管理业务逻辑与状态
///
/// 采用多步生成策略（Chain-of-Thought + 分批精写）：
/// 1. 定调：生成书名 + 核心概念（JSON 结构化输出，失败自动重试）
/// 2. 骨架：粗骨架规划（全部大事件仅标题+定位，锁定全局轨迹）
///    → 按约 1/10（最少 2 个、封顶 5 个）分批精写大事件 → 按批间隔抽取伏笔账本（含伏笔/角色状态/悬念）
/// 3. 展开：顺序逐块展开大/小事件细节（每块最多 3 个大事件），
///    每块注入「前文已展开的详细内容 + 后文待展开的大事件」，
///    保证跨块小事件因果承接、状态不漂移、伏笔连续
///
/// 可靠性特性：
/// - 步骤 1/2 解析失败自动重试（最多 2 次、指数退避）；步骤 3 块级请求网络失败自动重试
/// - 每步结果本地落盘，支持从失败步骤断点续跑
/// - 步骤 3 各块顺序生成（注入前文/后文上下文），UI 按序合并展示
class OutlineController extends ChangeNotifier {
  // ─── 输入控制器 ──────────────────────────────────────────────
  final genreController = TextEditingController(text: '玄幻');
  final themeController = TextEditingController();
  final protagonistController = TextEditingController();
  final worldViewController = TextEditingController();
  final scrollController = ScrollController();
  final OutlineService _outlineService;

  int majorEventCount = 5;
  int minorEventCount = 3;

  // ─── 状态 ────────────────────────────────────────────────────
  bool loading = false;
  String? error;
  String? warning;
  String? message; // 用户提示（保存成功/中断可续跑），页面消费后清空
  String rawText = ''; // 已完成并刷入的最终文本
  String title = '';
  CancelToken? _cancelToken;

  // ─── 多步生成状态 ────────────────────────────────────────────
  static const int _maxEventsPerChunk = 3; // 每个展开块包含的大事件数
  // 展开块并发数。为保障跨块小事件连贯性（每块需注入前文已展开内容），
  // 目前固定为顺序执行（1）；保留并行基础设施，未来如需提速可调大并配合边界状态预规划。
  static const int _maxConcurrentChunks = 1;
  static const int _maxRetries = 2;
  static const int _maxChunkRetries = 2; // 展开块未收到内容时的网络失败自动重试次数
  static const int _maxContinuations = 5; // 展开块因 max_tokens 截断时的最大自动续写次数
  static const int _ledgerInterval = 2; // 每 N 批抽取一次伏笔账本（末批必定抽取）
  static const Duration _throttleInterval = Duration(milliseconds: 300);
  static const String _progressFileName = 'outline_progress.json';

  int currentStep = 0;
  int totalSteps = 0;
  List<String> stepLabels = [];
  final List<_StepStat> _stepStats = [];

  String _liveText = ''; // 正在流式输出的文本（多块时按序合并）
  final List<OutlineStepBubble> _bubbles = []; // 已提交的展示气泡（步骤/尝试级快照）
  String _stepPreview = ''; // 步骤1/2完成后的格式化结果（书名概念 + 三幕骨架），展开阶段前持续展示
  bool _cancelled = false;
  String? _step1Text; // 步骤 1 的展示文本（书名+概念）
  _Step1Result? _step1Json;
  _Step2Result? _step2Json;
  String? _coarseSkeletonSnapshot; // 粗骨架规划阶段的原始渲染文本（精写前的标题+定位），供「大事件返回上一步」展示
  String _systemPrompt = ''; // 本次运行使用的系统提示词（重新展开步骤3时复用）

  // ─── 步骤 2 分批精写状态 ─────────────────────────────────────
  List<_Step2Batch> _step2Batches = []; // 本轮按幕顺序切好的批次
  int _step2BatchCount = 0; // 批次数（用于进度标签）
  int _ledgerBatchCount = 0; // 需抽取账本的批次数
  int _step2SubStepCount = 1; // 步骤 2 子调用数 = 1（粗骨架）+ 精写批次 + 账本批次
  int _refinedBatchCount = 0; // 已完成（精写+账本）的批次数，断点续跑从此继续
  bool _step2RefinedThisRun = false; // 本次运行是否实际执行过精写批次（检查点触发条件）
  final List<Map<String, dynamic>> _ledgerForeshadows = []; // 伏笔账本：伏笔列表
  final List<String> _ledgerCharacters = []; // 伏笔账本：角色状态
  final List<String> _ledgerUnresolved = []; // 伏笔账本：未解决悬念

  late String _apiKey;
  late OutlineSetting _outlineSetting;
  late Map<String, dynamic> _baseParams;

  final List<CancelToken> _activeTokens = [];
  DateTime _lastNotifyTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastScrollTime = DateTime.fromMillisecondsSinceEpoch(0);
  File? _progressFile;
  Future<void>? _runFuture; // 当前正在执行的生成流程，启动新流程前需等待其彻底结束

  // 并行展开状态
  List<_ExpandChunk> _chunks = [];
  int _flushIndex = 0; // 已按序刷入 rawText 的块数
  int _completedChunkCount = 0; // 已完成的块数（含乱序完成）

  // ─── 检查点（生成暂停审查）状态 ──────────────────────────────
  bool paused = false; // 是否处于检查点暂停
  String?
  checkpointKind; // 当前检查点类型：'skeleton'（粗骨架）| 'events'（大事件）| 'title'（书名/概念）
  String checkpointText = ''; // 当前检查点的可编辑文本（三幕骨架渲染）
  String? checkpointBackSource; // 当前检查点是从哪个检查点返回来的（null=正常入口，非 null 时页面显示「下一步」）
  String _checkpointOriginalText = ''; // 进入检查点时的原始文本（判断是否编辑过）
  bool _checkpointEdited = false; // 用户是否编辑过内容（大事件检查点继续后需重提炼账本）
  Completer<void>? _checkpointResumer; // 暂停等待用户操作
  _CheckpointAction _checkpointAction = _CheckpointAction.none; // 用户操作意图
  String? _restoreCheckpointKind; // 断点续跑恢复的检查点类型
  String? _restoreCheckpointText; // 断点续跑恢复的检查点文本
  bool _restoreCheckpointFromMinor = false; // 恢复的大事件检查点是否来自小事件返回链
  Map<String, dynamic>? _lastSavedCheckpoint; // 最近一次暂停保存的检查点（取消后沿用，避免覆盖丢失）
  String _fallbackForeshadows = ''; // 局部重新生成时的原记录伏笔清单（新账本为空时沿用）
  Timer? _checkpointSyncTimer; // 检查点编辑防抖落盘定时器
  Future<void> _writeQueue = Future.value(); // 串行写入队列：同一时刻仅一个写操作在途

  /// 当前步骤的显示标签
  String get stepLabel =>
      currentStep < stepLabels.length ? stepLabels[currentStep] : '';

  /// 当前展示文本 = 已完成内容（最终文本或结构化步骤预览）+ 正在流式的文本
  String get displayText {
    final base = rawText.isNotEmpty ? rawText : _stepPreview;
    if (base.isNotEmpty && _liveText.isNotEmpty) {
      return '$base\n\n$_liveText';
    }
    if (_liveText.isNotEmpty) return _liveText;
    return base;
  }

  /// 已提交的展示气泡（步骤/尝试级内容快照，失败重试时也会保留）
  List<OutlineStepBubble> get bubbles => List.unmodifiable(_bubbles);

  /// 当前正在流式输出的文本（多气泡视图的实时气泡使用）
  String get liveText => _liveText;

  /// 进度（0~1）
  double get progress {
    if (totalSteps <= 0) return 0;
    final p = (currentStep + 1) / totalSteps;
    return p.clamp(0.0, 1.0);
  }

  /// 进度文案
  String get progressText {
    final continuing = _chunks.any((c) => c.continuing);
    final suffix = continuing ? ' · 自动续写中' : '';
    if (_chunks.isEmpty) {
      return '$stepLabel (${currentStep + 1}/$totalSteps)$suffix';
    }
    return '$stepLabel · 已完成 $_completedChunkCount/${_chunks.length} 块$suffix';
  }

  /// 最近完成一步的耗时/token 统计
  String? get lastStepSummary =>
      _stepStats.isEmpty ? null : _stepStats.last.summary;

  /// 预估 AI 调用次数（步骤1 + 粗骨架 + 精写批次 + 账本批次 + 展开块数）
  int get estimatedApiCalls {
    final batchSize = _calcBatchSize(majorEventCount);
    final batchCount = batchSize <= 0
        ? 0
        : (majorEventCount / batchSize).ceil();
    final ledgerCount = _countLedgerBatches(batchCount);
    return 2 +
        batchCount +
        ledgerCount +
        (majorEventCount / _maxEventsPerChunk).ceil();
  }

  /// 是否存在可续跑的进度草稿（同步判断，文件路径已知时）
  bool get hasPendingDraft => _progressFile?.existsSync() ?? false;

  OutlineController({OutlineService? outlineService})
    : _outlineService = outlineService ?? OutlineService();

  // ─── 对外辅助 ────────────────────────────────────────────────

  /// 异步检查是否存在可续跑的草稿
  Future<bool> checkPendingDraft() async {
    final file = await _ensureProgressFile();
    return file.existsSync();
  }

  /// 消费一次性提示消息
  String? consumeMessage() {
    final m = message;
    message = null;
    return m;
  }

  // ─── 检查点用户操作（页面调用） ───────────────────────────────

  /// 用户确认检查点内容并继续：若内容被编辑则解析回填三幕骨架，再放行生成流程。
  /// 解析失败时设置 [error] 并保持暂停，不推进流程。
  Future<void> continueCheckpoint(String editedText) async {
    final kind = checkpointKind;
    final resumer = _checkpointResumer;
    if (kind == null || resumer == null || resumer.isCompleted) return;
    final trimmed = editedText.trim();
    if (trimmed.isEmpty) {
      error = '检查点内容不能为空';
      notifyListeners();
      return;
    }
    if (trimmed != _checkpointOriginalText.trim() || _checkpointEdited) {
      if (kind == 'minor') {
        // 小事件检查点：编辑的是最终全文（rawText）
        rawText = trimmed;
        _checkpointEdited = true;
      } else if (kind == 'title') {
        // 书名与核心概念检查点：首行为「书名：《xxx》」，其余为核心概念简介
        final parsed = _parseTitleText(trimmed);
        if (parsed == null) {
          error = '编辑内容无法解析，请保留「书名：《xxx》」首行与核心概念简介';
          notifyListeners();
          return;
        }
        _step1Json = parsed;
        _step1Text = trimmed;
        _stepPreview = _step1Text!;
        title = parsed.title;
        _upsertBubble('书名与核心概念', _step1Text!);
        _checkpointEdited = true;
      } else {
        final parsed = _parseSkeletonText(trimmed);
        if (parsed == null) {
          error = '编辑内容无法解析为三幕结构，请保留「══ 第一幕/第二幕/第三幕」幕标题与大事件N：标题 行格式';
          notifyListeners();
          return;
        }
        _step2Json = parsed;
        _stepPreview = '${_step1Text ?? ''}\n\n${_renderSkeleton()}';
        _coarseSkeletonSnapshot = _renderSkeleton(); // 编辑后快照同步，返回上一步时展示最新粗骨
        _upsertBubble('三幕粗骨架', _renderSkeleton());
        _checkpointEdited = true;
      }
    }
    _releaseCheckpoint(_CheckpointAction.none);
  }

  /// 解析用户编辑后的书名/核心概念文本（检查点「返回上一步」编辑用）
  _Step1Result? _parseTitleText(String text) {
    final lines = text
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final m = RegExp(
      r'^书名\s*[：:]\s*(?:《([^》]+)》|(.+))$',
    ).firstMatch(lines.first);
    final t = (m?.group(1) ?? m?.group(2) ?? '').trim();
    final concept = lines.skip(1).join('\n').trim();
    if (t.isEmpty || concept.isEmpty) return null;
    return _Step1Result(title: t, concept: concept);
  }

  /// 更新（或新增）指定标签的气泡内容：检查点编辑/重新生成后原位刷新展示
  void _upsertBubble(String label, String content) {
    for (final b in _bubbles) {
      if (b.label == label) {
        b.content = content;
        return;
      }
    }
    _bubbles.add(OutlineStepBubble(label: label, content: content));
  }

  /// 用户要求重新生成当前检查点对应阶段：
  /// 粗骨架检查点重跑整个步骤 2；大事件检查点重跑精写批次与伏笔账本。
  void regenerateCheckpoint() {
    _releaseCheckpoint(_CheckpointAction.regenerate);
  }

  /// 用户要求返回上一步（检查点回退）：
  /// 大事件检查点回到粗骨架检查点；粗骨架检查点回到书名与核心概念检查点。
  void backCheckpoint() {
    _releaseCheckpoint(_CheckpointAction.back);
  }

  /// 用户要求下一步（反悔返回）：回到返回上一步之前的检查点。
  /// 书名/概念检查点回到粗骨架检查点；粗骨架检查点回到大事件检查点。
  void forwardCheckpoint() {
    _releaseCheckpoint(_CheckpointAction.forward);
  }

  /// 检查点暂停期间，页面把用户编辑实时同步到控制器（防抖落盘），
  /// 防止用户意外退出页面（返回上一页/系统返回/杀掉应用）后编辑内容丢失。
  /// 仅记录文本与「是否编辑过」标记，不校验格式、不阻塞输入。
  void syncCheckpointEdit(String text) {
    if (!paused || checkpointKind == null) return;
    if (text == checkpointText) return;
    checkpointText = text;
    _checkpointEdited = text.trim() != _checkpointOriginalText.trim();
    // 防抖：停止输入约 300ms 后落盘，避免每次按键都写本地文件
    _checkpointSyncTimer?.cancel();
    _checkpointSyncTimer = Timer(
      const Duration(milliseconds: 300),
      _persistProgress,
    );
  }

  /// 立即把尚未落盘的检查点编辑写入本地草稿（退出页面/释放检查点前调用）。
  void flushCheckpointSync() {
    _checkpointSyncTimer?.cancel();
    _checkpointSyncTimer = null;
    if (!paused || checkpointKind == null) return;
    _persistProgress();
  }

  /// 「书名与核心概念」检查点循环：编辑或重新生成，供用户审查后继续。
  /// 返回 null 表示取消或出错（调用方终止流程）；
  /// 其余见 [_TitleBackResult]。
  Future<_TitleBackResult?> _runTitleCheckpointBack() async {
    var changed = false;
    var isRestore = _restoreCheckpointKind == 'title';
    while (true) {
      // 每轮都取最新的 _step1Text，重新生成后展示新内容；续跑恢复时展示上次会话编辑的文本
      final action = await _checkpointPause(
        'title',
        initialText: isRestore
            ? (_restoreCheckpointText ?? _step1Text)
            : _step1Text,
        backSource: 'skeleton',
        originalText: isRestore ? _step1Text : null,
        keepEdited: isRestore,
      );
      _restoreCheckpointText = null;
      isRestore = false;
      if (action == _CheckpointAction.cancel) {
        await _persistProgress(phase: 2);
        loading = false;
        notifyListeners();
        return null;
      }
      if (action == _CheckpointAction.forward) {
        return _TitleBackResult.forward; // 下一步：回到骨架检查点
      }
      if (action == _CheckpointAction.regenerate) {
        final ok1 = await _regenerateStep1();
        if (!ok1 || _cancelled || error != null) return null;
        changed = true;
        continue; // 重新生成后再次暂停供审查
      }
      // 继续：若用户编辑过（含恢复自上次会话的编辑），已通过 continueCheckpoint 回填 _step1Json
      if (_checkpointEdited) changed = true;
      break;
    }
    return changed ? _TitleBackResult.changed : _TitleBackResult.unchanged;
  }

  /// 大事件检查点循环（含返回上一步 → 粗骨架 → 书名/概念 的整条回退链）。
  ///
  /// [fromMinor] 表示是否从小事件检查点返回而来：为 true 时，
  /// 「继续/下一步」回到小事件检查点（调用方据此决定是否重展步骤3）；
  /// 为 false 时（正常流程）「继续」进入步骤3。
  ///
  /// 返回 null 表示取消或出错（调用方终止流程）；
  /// true 表示期间发生过大事件/骨架/书名的改动（需要重新展开小事件）；
  /// false 表示无改动。
  Future<bool?> _runEventsCheckpoint({required bool fromMinor}) async {
    var rerunNeeded = false; // 是否发生改动，需要重新展开步骤3（小事件）
    var isRestore = _restoreCheckpointKind == 'events';
    // 仅在确实恢复到大事件检查点（带上次会话的编辑文本）时才保留「已编辑」标记与基线；
    // 经骨架检查点「下一步」转入时无恢复文本，按全新检查点处理，避免标记跨检查点泄漏
    var restoreText = isRestore ? _restoreCheckpointText : null;
    _restoreCheckpointKind = null;
    _restoreCheckpointText = null;
    _restoreCheckpointFromMinor = false;
    while (true) {
      final action = await _checkpointPause(
        'events',
        initialText: restoreText,
        backSource: fromMinor ? 'minor' : null,
        originalText: (isRestore && restoreText != null)
            ? _renderSkeleton()
            : null,
        keepEdited: isRestore && restoreText != null,
      );
      restoreText = null;
      isRestore = false;
      if (action == _CheckpointAction.cancel) {
        await _persistProgress(phase: 3);
        loading = false;
        notifyListeners();
        return null;
      }
      if (action == _CheckpointAction.regenerate) {
        final ok = await _runStep2(forceRefine: true);
        if (!ok || _cancelled || error != null) return null;
        rerunNeeded = true;
        continue; // 重新生成后再次暂停，供用户审查
      }
      if (action == _CheckpointAction.forward) {
        // 下一步：反悔返回小事件检查点（仅 fromMinor 时有意义）
        if (fromMinor) return rerunNeeded;
        break; // 防御：正常流程无「下一步」，等同继续
      }
      if (action == _CheckpointAction.back) {
        // 返回上一步：回到粗骨架检查点，可编辑骨架后重新精写
        var needRefine = false;
        var skeletonReRan = false;
        while (true) {
          final skAction = await _checkpointPause(
            'skeleton',
            initialText: _coarseSkeletonSnapshot ?? _renderSkeleton(),
            backSource: 'events',
          );
          if (skAction == _CheckpointAction.cancel) {
            await _persistProgress(phase: 3);
            loading = false;
            notifyListeners();
            return null;
          }
          if (skAction == _CheckpointAction.forward) {
            // 下一步：反悔返回大事件检查点（内容未动），由外层重新暂停
            break;
          }
          if (skAction == _CheckpointAction.back) {
            // 再返回一步：书名与核心概念
            final tRes = await _runTitleCheckpointBack();
            if (tRes == null || _cancelled || error != null) return null;
            if (tRes == _TitleBackResult.forward) {
              continue; // title 点了「下一步」：重新暂停骨架检查点
            }
            if (tRes == _TitleBackResult.changed) {
              final ok = await _runStep2(forceSkeleton: true);
              if (!ok || _cancelled || error != null) return null;
              skeletonReRan = true;
            }
            break;
          }
          if (skAction == _CheckpointAction.regenerate) {
            final ok = await _runStep2(forceSkeleton: true);
            if (!ok || _cancelled || error != null) return null;
            skeletonReRan = true;
            break;
          }
          // 继续：仅当骨架被编辑过才需要重新精写
          if (_checkpointEdited) needRefine = true;
          break;
        }
        if (!skeletonReRan && needRefine) {
          final ok = await _runStep2(forceRefine: true);
          if (!ok || _cancelled || error != null) return null;
        }
        if (skeletonReRan || needRefine) rerunNeeded = true;
        continue; // 回到大事件检查点，供用户审查
      }
      // 继续：若用户编辑过大事件，重新提炼一次伏笔账本
      if (_checkpointEdited) {
        _checkpointEdited = false;
        final okLedger = await _refreshLedgerFromSkeleton();
        if (!okLedger || _cancelled || error != null) return null;
        rerunNeeded = true;
      }
      break;
    }
    return rerunNeeded;
  }

  /// 重新生成书名与核心概念（步骤 1）。成功返回 true；取消/出错返回 false。
  Future<bool> _regenerateStep1() async {
    currentStep = 0;
    _liveText = '正在重新生成书名和核心概念...';
    notifyListeners();
    final t0 = DateTime.now();
    final r = await _runStructuredStep<_Step1Result>(
      systemPrompt: OutlinePromptTemplate.jsonSystemPrompt,
      userPrompt: OutlinePromptTemplate.buildStep1Prompt(
        genre: genreController.text,
        theme: themeController.text,
        protagonist: protagonistController.text,
        worldview: worldViewController.text,
      ),
      maxTokens: _outlineSetting.maxTokens,
      temperature: 0.3,
      failureMessage: '书名和核心概念生成失败：模型输出无法解析',
      validate: (map) {
        final t = map['title'];
        final c = map['concept'];
        if (t is String &&
            t.trim().isNotEmpty &&
            c is String &&
            c.trim().isNotEmpty) {
          return _Step1Result(title: t.trim(), concept: c.trim());
        }
        return null;
      },
    );
    if (_cancelled || error != null || r == null) {
      await _persistProgress(phase: 1);
      loading = false;
      notifyListeners();
      return false;
    }
    _step1Json = r;
    _step1Text = '书名：《${r.title}》\n\n${r.concept}';
    _stepPreview = _step1Text!;
    _liveText = '';
    _upsertBubble('书名与核心概念', _step1Text!);
    title = r.title;
    _stepStats.add(
      _StepStat(
        '生成书名和核心概念',
        DateTime.now().difference(t0).inSeconds,
        r.concept.length,
      ),
    );
    await _persistProgress(phase: 2);
    notifyListeners();
    return true;
  }

  /// 结束检查点等待：记录用户操作意图并完成 resumer，让暂停中的生成流程继续
  void _releaseCheckpoint(_CheckpointAction action) {
    _checkpointAction = action;
    // 释放暂停前先把未落盘的编辑立即写入草稿，防止继续/取消/退出时丢失最近输入
    flushCheckpointSync();
    final resumer = _checkpointResumer;
    if (resumer != null && !resumer.isCompleted) {
      resumer.complete();
    }
  }

  // ─── 取消 / 部分保存 ─────────────────────────────────────────

  Future<void> cancel() async {
    _cancelled = true;
    loading = false;
    for (final t in List.of(_activeTokens)) {
      t.cancel();
    }
    _activeTokens.clear();
    _cancelToken?.cancel();
    _cancelToken = null;
    // 若正处于检查点暂停，先释放等待，让生成流程能感知取消并退出
    _releaseCheckpoint(_CheckpointAction.cancel);
    if (_step1Json != null || _step2Json != null || rawText.isNotEmpty) {
      await _persistProgress();
    }
    notifyListeners();
  }

  /// 保存当前已生成的部分内容到历史记录
  Future<void> savePartial() async {
    if (rawText.trim().isEmpty) return;
    try {
      await _outlineService.saveRecord(_buildRecord());
      message = '已保存当前已生成的部分大纲';
    } catch (e) {
      error = '保存失败：${e.toString().replaceFirst('Exception: ', '')}';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _checkpointSyncTimer?.cancel();
    for (final t in _activeTokens) {
      t.cancel();
    }
    _activeTokens.clear();
    _cancelToken?.cancel();
    genreController.dispose();
    themeController.dispose();
    protagonistController.dispose();
    worldViewController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  /// 智能滚动：仅当用户接近底部时才自动滚动到底
  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      final pos = scrollController.position;
      if (!pos.hasContentDimensions) return;
      final max = pos.maxScrollExtent;
      if (pos.pixels < max - 200) return;
      scrollController.animateTo(
        max,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    });
  }

  // ─── 主入口：全新生成 / 断点续跑 ───────────────────────────

  Future<void> generate() async {
    if (themeController.text.trim().isEmpty ||
        protagonistController.text.trim().isEmpty) {
      error = '请填写主题和主角设定';
      notifyListeners();
      return;
    }
    await _waitForPreviousRun();
    _resetState();
    await _deleteProgress();
    await _runAll();
  }

  Future<void> resume() async {
    final data = await _loadProgress();
    if (data == null) return;
    await _waitForPreviousRun();
    _resetState();
    _applyProgress(data);
    await _runAll();
  }

  /// 基于历史大纲记录做「局部重新生成」：
  /// 解析出书名/概念与三幕骨架后，直接进入指定检查点（粗骨/大事件）供编辑，
  /// 继续后仅重新生成对应下游内容，并作为新记录保存（不覆盖原大纲）。
  /// [kind]：'skeleton'（编辑粗骨 → 重新精写大事件+账本+展开小事件）
  ///        | 'events'（编辑大事件 → 重新展开小事件）
  Future<void> regenerateFromRecord(
    OutlineRecord record, {
    required String kind,
  }) async {
    _resetState();
    await _deleteProgress();
    if (!_seedFromRecord(record)) {
      error = '无法从该大纲解析出三幕结构，可能原大纲内容格式不完整';
      loading = false;
      notifyListeners();
      return;
    }
    _restoreCheckpointKind = kind;
    _restoreCheckpointText = _renderSkeleton();
    await _runAll();
  }

  /// 从未完成的历史大纲记录继续生成：恢复骨架、伏笔账本与已生成的小事件内容，
  /// 直接从未完成的展开块继续生成剩余小事件，并另存为新记录（不覆盖原大纲）。
  Future<void> continueFromRecord(OutlineRecord record) async {
    _resetState();
    await _deleteProgress();
    if (!_seedContinueFromRecord(record)) {
      error = '无法从该大纲恢复未完成的生成进度，可能原大纲内容格式不完整';
      loading = false;
      notifyListeners();
      return;
    }
    await _runAll();
  }

  /// 等待上一次生成流程彻底结束，再启动新流程。
  ///
  /// 取消生成后，旧流程的流式请求仍可能在后台收尾（刚取消的请求完成、
  /// 已收到的部分内容会被当作失败尝试处理）。若不等旧流程退出就重置
  /// [_cancelled] 并启动新流程，旧流程会把中断的旧内容与新内容并发生成，
  /// 导致本次输出混杂了上次中断的内容。
  Future<void> _waitForPreviousRun() async {
    final prev = _runFuture;
    if (prev == null) return;
    _cancelled = true;
    for (final t in List.of(_activeTokens)) {
      t.cancel();
    }
    _activeTokens.clear();
    _cancelToken?.cancel();
    _cancelToken = null;
    // 旧流程若正处于检查点暂停，先释放等待，避免挂起导致新流程无法启动
    _releaseCheckpoint(_CheckpointAction.cancel);
    try {
      await prev;
    } catch (_) {}
  }

  Future<void> _runAll() async {
    final future = _doRunAll();
    _runFuture = future;
    try {
      await future;
    } finally {
      if (identical(_runFuture, future)) _runFuture = null;
    }
  }

  Future<void> _doRunAll() async {
    try {
      final settings = await _outlineService.loadSettings();
      if (settings.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }
      _apiKey = settings.apiKey;
      _outlineSetting = settings.outlineSetting;
      _baseParams = {'model': settings.outlineSetting.model, 'stream': true};

      final estBatchSize = _calcBatchSize(majorEventCount);
      final estBatchCount = estBatchSize <= 0
          ? 0
          : (majorEventCount / estBatchSize).ceil();
      final estLedgerCount = _countLedgerBatches(estBatchCount);
      totalSteps =
          3 +
          estBatchCount +
          estLedgerCount +
          (majorEventCount / _maxEventsPerChunk).ceil();
      stepLabels = ['生成书名和核心概念', '规划三幕粗骨架', '展开细节'];

      final systemPrompt = OutlinePromptTemplate.buildSystemPrompt(
        settings.outlineSetting.systemPrompt,
      );
      _systemPrompt = systemPrompt;

      // ── 步骤 1：定调 — 书名 + 核心概念（JSON） ──────────
      if (_step1Json == null) {
        final ok1 = await _regenerateStep1();
        if (!ok1) return;
      }

      if (_cancelled || error != null) return;

      // ── 检查点恢复：书名与核心概念（可选）──
      // 断点续跑时若暂停在「返回上一步」的书名检查点，恢复暂停供用户继续
      var step2Done = false;
      if (_restoreCheckpointKind == 'title') {
        final changed = await _runTitleCheckpointBack();
        _restoreCheckpointKind = null;
        _restoreCheckpointText = null;
        if (changed == null || _cancelled || error != null) return;
        if (changed == _TitleBackResult.changed) {
          // 书名/概念有变更：整体重跑步骤 2（内部会再次暂停供审查）
          final ok2 = await _runStep2(forceSkeleton: true);
          if (!ok2 || _cancelled || error != null) return;
          step2Done = true;
        } else {
          // 继续/下一步：都回到返回前的位置（粗骨架检查点）继续审查，
          // 由 _runStep2 恢复检查点逻辑再决定回到大事件检查点或进入精写
          _restoreCheckpointKind = 'skeleton';
        }
      }

      if (_cancelled || error != null) return;

      // ── 步骤 2：骨架 — 粗骨架规划 + 分批精写 + 伏笔账本 ──
      if (!step2Done) {
        final ok2 = await _runStep2();
        if (!ok2 || _cancelled || error != null) return;
      }

      // ── 检查点：大事件（可选）—— 精写完成（含账本）后暂停审查 ──
      // 仅在「本次实际执行过精写」或「续跑恢复的大事件检查点」时触发，避免恢复运行重复暂停
      if (_restoreCheckpointKind == 'events' ||
          (_step2RefinedThisRun && _outlineSetting.pauseAfterEvents)) {
        final fromMinor =
            _restoreCheckpointKind == 'events' && _restoreCheckpointFromMinor;
        final rerun = await _runEventsCheckpoint(fromMinor: fromMinor);
        if (rerun == null || _cancelled || error != null) return;
        if (fromMinor && rerun) {
          // 恢复自小事件返回链的大事件检查点且发生改动：重新展开小事件
          await _rerunChunks();
          if (_cancelled || error != null) return;
        }
      }

      // ── 准备步骤 3：构建展开块（按每 5 个大事件拆分） ────
      _buildChunks();
      if (_cancelled || error != null) return;

      // ── 步骤 3a/b/c...：限流并行展开，按序合并 ──────────
      await _runChunksParallel(systemPrompt: _systemPrompt);

      if (_cancelled) {
        loading = false;
        notifyListeners();
        return;
      }

      if (error != null) {
        message = '生成中断，可通过「继续上次」按钮续跑';
        await _persistProgress(phase: 3);
        loading = false;
        notifyListeners();
        return;
      }

      // ── 检查点：小事件（可选）—— 步骤3全部展开完毕后暂停审查 ──
      // 仅在「本次实际展开过」或「续跑恢复的小事件检查点」时触发
      if (_restoreCheckpointKind == 'minor' ||
          (_chunks.isNotEmpty && _outlineSetting.pauseAfterMinor)) {
        var isRestore = _restoreCheckpointKind == 'minor';
        var restoreText = isRestore ? _restoreCheckpointText : null;
        _restoreCheckpointKind = null;
        _restoreCheckpointText = null;
        while (true) {
          final action = await _checkpointPause(
            'minor',
            initialText: restoreText ?? rawText,
            originalText: (isRestore && restoreText != null) ? rawText : null,
            keepEdited: isRestore && restoreText != null,
          );
          restoreText = null;
          isRestore = false;
          if (action == _CheckpointAction.cancel) {
            await _persistProgress(phase: 3);
            loading = false;
            notifyListeners();
            return;
          }
          if (action == _CheckpointAction.regenerate) {
            // 重新生成小事件：按当前骨架重新展开步骤3
            await _rerunChunks();
            if (_cancelled || error != null) return;
            continue; // 重新暂停在小事件检查点，供用户审查
          }
          if (action == _CheckpointAction.forward) {
            break; // 防御：小事件检查点无「下一步」（最底层）
          }
          if (action == _CheckpointAction.back) {
            // 返回上一步：大事件检查点（可继续向上到粗骨架/书名，改动后重新展开小事件）
            final rerun = await _runEventsCheckpoint(fromMinor: true);
            if (rerun == null || _cancelled || error != null) return;
            if (rerun) {
              await _rerunChunks();
              if (_cancelled || error != null) return;
            }
            continue; // 重新暂停在小事件检查点，供用户审查
          }
          // 继续：若编辑过，rawText 已在 continueCheckpoint 更新
          break;
        }
        if (_cancelled || error != null) return;
      }

      // ── 保存到历史记录（await + 失败提示） ───────────────
      if (rawText.isNotEmpty) {
        try {
          await _outlineService.saveRecord(_buildRecord());
          message = '大纲已保存到历史记录';
        } catch (e) {
          error =
              '大纲已生成，但保存历史失败：${e.toString().replaceFirst('Exception: ', '')}';
        }
      }

      await _deleteProgress();
      loading = false;
      notifyListeners();
    } catch (e) {
      if (!_cancelled) {
        error = e.toString().replaceFirst('Exception: ', '');
        await _persistProgress();
      }
      loading = false;
      notifyListeners();
    }
  }

  // ─── 结构化 JSON 步骤（含重试与校验） ───────────────────────

  Future<T?> _runStructuredStep<T>({
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
    required String failureMessage,
    required T? Function(Map<String, dynamic> json) validate,
  }) async {
    var attempt = 0;
    while (true) {
      if (_cancelled) return null;
      final token = CancelToken();
      _cancelToken = token;
      _activeTokens.add(token);
      String accumulated = '';
      String reasoningAccum = '';
      String? finishReason;
      final completer = Completer<void>();
      try {
        await _outlineService.streamGenerate(
          apiKey: _apiKey,
          apiParams: {
            ..._baseParams,
            'temperature': temperature,
            'max_tokens': maxTokens,
            'stream': true,
            'response_format': {'type': 'json_object'},
            if (!_outlineSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
          cancelToken: token,
          onChunk: (chunk) {
            final choices = chunk['choices'] as List?;
            if (choices == null || choices.isEmpty) return;
            final delta = choices[0]['delta'] as Map<String, dynamic>?;
            final content = delta?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              accumulated += content;
              _liveText = _mergeStructuredLiveText(accumulated, reasoningAccum);
              _throttledNotify();
              _throttledScroll();
            }
            final reasoning = delta?['reasoning_content'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) {
              reasoningAccum += reasoning;
              _liveText = _mergeStructuredLiveText(accumulated, reasoningAccum);
              _throttledNotify();
              _throttledScroll();
            }
            final fr = choices[0]['finish_reason'] as String?;
            if (fr != null && fr.isNotEmpty) finishReason = fr;
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (msg) {
            if (!completer.isCompleted) completer.completeError(msg);
          },
        );
        await completer.future;
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }

        final parsed = _extractJson(accumulated);
        if (parsed == null) {
          throw _StepParseException('模型输出不是合法 JSON');
        }
        final result = validate(parsed);
        if (result != null) {
          if (finishReason == 'length') {
            warning = '本轮结构生成被 max_tokens 截断，结果可能不完整';
          }
          return result;
        }
        throw _StepParseException(failureMessage);
      } on DioException catch (e) {
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }
        if (attempt < _maxRetries) {
          _preserveFailedOutput(
            accumulated,
            reasoningAccum,
            attempt: attempt,
            reason: '请求失败：${e.message}',
          );
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(
          accumulated,
          reasoningAccum,
          attempt: attempt,
          reason: '请求失败：${e.message}',
        );
        error = '请求失败：${e.message}';
        return null;
      } on _StepParseException catch (e) {
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }
        if (attempt < _maxRetries) {
          _preserveFailedOutput(
            accumulated,
            reasoningAccum,
            attempt: attempt,
            reason: e.message,
          );
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(
          accumulated,
          reasoningAccum,
          attempt: attempt,
          reason: e.message,
        );
        error = e.message;
        return null;
      } catch (e) {
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }
        if (attempt < _maxRetries) {
          _preserveFailedOutput(
            accumulated,
            reasoningAccum,
            attempt: attempt,
            reason: e.toString().replaceFirst('Exception: ', ''),
          );
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(
          accumulated,
          reasoningAccum,
          attempt: attempt,
          reason: e.toString().replaceFirst('Exception: ', ''),
        );
        error = e.toString().replaceFirst('Exception: ', '');
        return null;
      } finally {
        _activeTokens.remove(token);
        _cancelToken = null;
      }
    }
  }

  Future<void> _retryWait(int attempt) async {
    _liveText = '生成失败，正在自动重试（第$attempt次）...';
    notifyListeners();
    await Future.delayed(Duration(seconds: attempt));
  }

  /// 步骤 1/2 失败或取消时，把本次尝试的模型输出（思考过程 + 生成内容）提交为气泡。
  /// 多次重试的每次思考都会被保留，不再被清除；[reason] 为本次失败原因。
  void _preserveFailedOutput(
    String content,
    String reasoning, {
    required int attempt,
    String? reason,
  }) {
    if (content.trim().isEmpty &&
        reasoning.trim().isEmpty &&
        (reason == null || reason.trim().isEmpty)) {
      return;
    }
    final body = _mergeStructuredLiveText(content, reasoning);
    _bubbles.add(
      OutlineStepBubble(
        label: '${_currentStepLabel()} · 第${attempt + 1}次',
        content: [
          if (reason != null && reason.trim().isNotEmpty) '【失败原因】$reason',
          if (body.isNotEmpty) body,
        ].join('\n\n'),
        isError: true,
      ),
    );
    _liveText = '';
    notifyListeners();
  }

  /// 当前步骤的显示标签（用于失败气泡命名）
  String _currentStepLabel() =>
      stepLabels.length > currentStep ? stepLabels[currentStep] : '生成';

  /// 从文本中提取 JSON（容忍 markdown 代码围栏及前后杂文）
  Map<String, dynamic>? _extractJson(String text) {
    var t = text.trim();
    final fence = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$');
    final fm = fence.firstMatch(t);
    if (fm != null) t = fm.group(1)!.trim();
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(t.substring(start, end + 1));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

  /// 解析步骤 2 JSON，校验三幕结构与事件总数
  _Step2Result? _parseStep2(
    Map<String, dynamic> map, {
    required int expectedCount,
  }) {
    final actsRaw = map['acts'];
    if (actsRaw is! List || actsRaw.isEmpty) return null;
    final acts = <_Act>[];
    var total = 0;
    for (final raw in actsRaw) {
      if (raw is! Map) return null;
      final name = raw['act'] as String? ?? '';
      final eventsRaw = raw['events'];
      if (eventsRaw is! List || eventsRaw.isEmpty) return null;
      final events = <_Event>[];
      for (final er in eventsRaw) {
        if (er is! Map) return null;
        final t = er['title'];
        // 粗骨架使用 position（一句话定位），旧格式使用 summary
        final s = er['summary'] ?? er['position'];
        if (t is! String || t.trim().isEmpty) return null;
        if (s is! String || s.trim().isEmpty) return null;
        events.add(_Event(title: t.trim(), summary: s.trim()));
        total++;
      }
      acts.add(_Act(name: name, events: events));
    }
    if (acts.length != 3) return null;
    // 总数允许小幅偏差（±max(1, 期望/3)，上限 3），
    // 避免模型计数偏差导致「粗骨架生成失败」必现
    final tolerance = ((expectedCount / 3).ceil()).clamp(1, 3);
    if (total < 3 || (total - expectedCount).abs() > tolerance) return null;
    return _Step2Result(acts: acts);
  }

  // ─── 步骤 2：粗骨架规划 + 分批精写 + 伏笔账本 ──────────────────

  /// 进入检查点暂停：设置暂停状态、落盘、等待用户操作（继续/重新生成/返回上一步/下一步/取消）。
  /// 返回用户操作意图；[initialText] 用于续跑恢复时保留暂停前的编辑文本；
  /// [backSource] 记录当前检查点是从哪个检查点返回来的（非 null 时页面提供「下一步」返回）。
  Future<_CheckpointAction> _checkpointPause(
    String kind, {
    String? initialText,
    String? backSource,
    String? originalText, // 恢复场景：编辑前的基线文本，用于与恢复的编辑文本比较
    bool keepEdited = false, // 恢复场景：保留上次会话记录的「已编辑」标记
  }) async {
    paused = true;
    checkpointKind = kind;
    checkpointText = initialText ?? _renderSkeleton();
    checkpointBackSource = backSource;
    _checkpointOriginalText = originalText ?? checkpointText;
    if (!keepEdited) _checkpointEdited = false;
    _liveText = ''; // 清空残留流式内容，避免与检查点卡片同时展示
    loading = false;
    notifyListeners();
    await _persistProgress();
    _checkpointAction = _CheckpointAction.none;
    _checkpointResumer = Completer<void>();
    await _checkpointResumer!.future;
    paused = false;
    checkpointKind = null;
    checkpointBackSource = null;
    loading = true;
    notifyListeners();
    if (_cancelled) return _CheckpointAction.cancel;
    return _checkpointAction;
  }

  /// 把用户编辑后的三幕骨架文本解析回 [_Step2Result]。
  /// 兼容「══ 第一幕：开端 ══」等幕标题与大事件N：标题 行格式，概要支持多行。
  _Step2Result? _parseSkeletonText(String text) {
    final actRe = RegExp(r'^\s*[══=]+\s*(第一幕|第二幕|第三幕)');
    final eventRe = RegExp(r'^大事件\s*\d+\s*[：:]\s*(.+)$');
    final acts = <_Act>[];
    _Act? curAct;
    String? curTitle;
    final summaryBuf = StringBuffer();
    void flushEvent() {
      if (curAct != null && curTitle != null) {
        curAct.events.add(
          _Event(title: curTitle!, summary: summaryBuf.toString().trim()),
        );
      }
      curTitle = null;
      summaryBuf.clear();
    }

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final actM = actRe.firstMatch(line);
      if (actM != null) {
        flushEvent();
        curAct = _Act(name: actM.group(1)!, events: []);
        acts.add(curAct);
        continue;
      }
      final evM = eventRe.firstMatch(line.trim());
      if (evM != null) {
        flushEvent();
        curTitle = evM.group(1)!.trim();
        continue;
      }
      if (curTitle != null && line.trim().isNotEmpty) {
        if (summaryBuf.isNotEmpty) summaryBuf.writeln();
        summaryBuf.write(line.trim());
      }
    }
    flushEvent();
    if (acts.length != 3) return null;
    for (final a in acts) {
      if (a.events.isEmpty) return null;
    }
    return _Step2Result(acts: acts);
  }

  // ─── 历史记录解析（局部重新生成用） ──────────────────────────

  /// 从历史大纲记录重建状态：回填设定，解析书名/概念与三幕骨架。
  /// 优先使用记录中持久化的骨架 JSON（兼容内容不完整的部分保存），
  /// 旧记录无骨架字段时退回从 content 文本解析。
  /// 成功返回 true；格式不完整返回 false（调用方提示错误）。
  bool _seedFromRecord(OutlineRecord record) {
    genreController.text = record.genre;
    themeController.text = record.theme;
    protagonistController.text = record.protagonist;
    worldViewController.text = record.worldview;
    _fallbackForeshadows = record.foreshadows;

    if (!_restoreSkeletonFromRecord(record.skeleton)) {
      final titleConcept = _parseRecordTitleConcept(record);
      if (titleConcept == null) return false;
      _step1Json = titleConcept;

      final acts = _parseRecordActs(record.content);
      if (acts == null || acts.length != 3) return false;
      _step2Json = _Step2Result(acts: acts);
    }

    _step1Text = '书名：《${_step1Json!.title}》\n\n${_step1Json!.concept}';
    _stepPreview = _step1Text!;
    title = _step1Json!.title;
    majorEventCount = _step2Json!.acts.fold<int>(
      0,
      (s, a) => s + a.events.length,
    );
    _coarseSkeletonSnapshot = null; // 记录内容无粗骨架原始快照
    _refinedBatchCount = _estimateRefinedBatchCount(
      _step2Json!.acts,
    ); // 视为全部精写完成
    _stepPreview = '${_step1Text ?? ''}\n\n${_renderSkeleton()}';
    _upsertBubble('三幕粗骨架', _renderSkeleton());
    return true;
  }

  /// 从记录持久化的骨架 JSON 重建书名/概念与三幕骨架。
  /// 成功返回 true；字段缺失或解析失败返回 false（调用方回退到文本解析）。
  bool _restoreSkeletonFromRecord(String skeleton) {
    final map = _decodeSkeleton(skeleton);
    if (map == null) return false;
    final s1 = map['step1'];
    final s2 = map['step2'];
    if (s1 is! Map<String, dynamic> || s2 is! Map<String, dynamic>) {
      return false;
    }
    final step1 = _Step1Result.fromMap(s1);
    final step2 = _Step2Result.fromMap(s2);
    if (step1.title.trim().isEmpty ||
        step1.concept.trim().isEmpty ||
        step2.acts.length != 3 ||
        step2.acts.any((a) => a.events.isEmpty)) {
      return false;
    }
    _step1Json = step1;
    _step2Json = step2;
    return true;
  }

  /// 解析记录持久化的骨架 JSON；为空或非法时返回 null。
  Map<String, dynamic>? _decodeSkeleton(String skeleton) {
    if (skeleton.trim().isEmpty) return null;
    try {
      final map = jsonDecode(skeleton);
      return map is Map<String, dynamic> ? map : null;
    } catch (_) {
      return null;
    }
  }

  /// 从未完成大纲记录重建「继续生成」所需状态：
  /// 书名/概念 + 三幕骨架 + 已生成的小事件内容 + 展开块进度 + 伏笔账本。
  /// 成功返回 true；格式不完整返回 false。
  bool _seedContinueFromRecord(OutlineRecord record) {
    genreController.text = record.genre;
    themeController.text = record.theme;
    protagonistController.text = record.protagonist;
    worldViewController.text = record.worldview;
    _fallbackForeshadows = record.foreshadows;

    final map = _decodeSkeleton(record.skeleton);
    if (!_restoreSkeletonFromRecord(record.skeleton)) {
      // 旧记录未持久化骨架：退回从 content 文本解析（需内容完整）
      final titleConcept = _parseRecordTitleConcept(record);
      if (titleConcept == null) return false;
      _step1Json = titleConcept;

      final acts = _parseRecordActs(record.content);
      if (acts == null || acts.length != 3) return false;
      _step2Json = _Step2Result(acts: acts);
    }

    _step1Text = '书名：《${_step1Json!.title}》\n\n${_step1Json!.concept}';
    _stepPreview = _step1Text!;
    title = _step1Json!.title;

    // 先确定事件数量：优先使用记录持久化的原设定（保证与原始批次划分一致），
    // 缺失时从骨架实际事件数推导。
    final acts = _step2Json!.acts;
    majorEventCount = acts.fold<int>(0, (s, a) => s + a.events.length);
    if (map != null) {
      final major = map['majorEventCount'];
      if (major is int && major > 0) majorEventCount = major;
      final minor = map['minorEventCount'];
      if (minor is int && minor > 0) minorEventCount = minor;
    }

    _coarseSkeletonSnapshot = null;
    _refinedBatchCount = _estimateRefinedBatchCount(acts); // 视为全部精写完成

    // 续写状态：已生成的小事件内容与展开块进度
    rawText = record.content.trim();
    if (map != null) {
      final completed = map['completedChunks'];
      if (completed is int && completed >= 0) _completedChunkCount = completed;
      final ledger = map['ledger'];
      if (ledger is Map<String, dynamic>) {
        _ledgerForeshadows
          ..clear()
          ..addAll(
            (ledger['foreshadows'] as List?)
                    ?.whereType<Map<String, dynamic>>() ??
                const [],
          );
        _ledgerCharacters
          ..clear()
          ..addAll(
            (ledger['characters'] as List?)?.whereType<String>() ?? const [],
          );
        _ledgerUnresolved
          ..clear()
          ..addAll(
            (ledger['unresolved'] as List?)?.whereType<String>() ?? const [],
          );
      }
    }

    _stepPreview = '${_step1Text!}\n\n${_renderSkeleton()}';
    if (displayText.isNotEmpty) {
      _bubbles.add(OutlineStepBubble(label: '已生成内容', content: displayText));
    }
    return true;
  }

  /// 从历史大纲最终内容解析书名与核心概念（步骤 1 的文本形式）。
  /// 兼容旧格式：首行可为「书名：《xxx》」、《xxx》或直接回退记录的 title 字段。
  _Step1Result? _parseRecordTitleConcept(OutlineRecord record) {
    final lines = record.content
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final m = RegExp(
      r'^书名\s*[：:]\s*(?:《([^》]+)》|(.+))$',
    ).firstMatch(lines.first);
    var t = (m?.group(1) ?? m?.group(2) ?? '').trim();
    if (t.isEmpty) {
      // 旧格式可能没有「书名：」前缀：首行形如《xxx》则取之，否则回退记录 title 字段
      final t2 = RegExp(r'^《([^》]+)》').firstMatch(lines.first);
      t = t2?.group(1)?.trim() ?? record.title.trim();
    }
    if (t.isEmpty) return null;
    final conceptBuf = <String>[];
    for (final line in lines.skip(1)) {
      if (RegExp(r'^[══=]+\s*第\s*[一二三四五六七八九十0-9]+\s*幕').hasMatch(line)) {
        break;
      }
      conceptBuf.add(line);
    }
    final concept = conceptBuf.join('\n').trim();
    if (concept.isEmpty) return null;
    return _Step1Result(title: t, concept: concept);
  }

  /// 从历史大纲最终内容解析三幕骨架：每个大事件 = 标题 + 概述
  /// （概述只取标题后、第一个小事件展开之前的段落，小事件块不参与骨架）。
  /// 容错与章节事件解析器（[_parseEvents]）保持一致，兼容旧版生成的大纲：
  /// - 幕标题：`══ 第一幕：开端 ══` / `══ 第1幕 ══` 等（══ 装饰 + 中文/数字编号）
  /// - 大事件行：`══ 大事件N：标题 ══` / `大事件N：标题` / `事件N：标题` 等
  ///   （══ 包裹可有可无，前缀支持 大事件/Major/事件，编号支持数字/X/中文/带圈）
  List<_Act>? _parseRecordActs(String content) {
    final actRe = RegExp(r'^\s*[══=]+\s*(第\s*[一二三四五六七八九十0-9]+\s*幕)');
    final eventRe = RegExp(
      r'^\s*═*\s*(?:大事件|Major|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]\s*(.+?)\s*═*\s*$',
    );
    final acts = <_Act>[];
    _Act? curAct;
    String? curTitle;
    final summaryBuf = StringBuffer();
    var minorStarted = false; // 当前大事件是否已进入小事件展开块（概述到此为止）

    void flushEvent() {
      if (curAct != null && curTitle != null) {
        curAct.events.add(
          _Event(title: curTitle!, summary: summaryBuf.toString().trim()),
        );
      }
      curTitle = null;
      summaryBuf.clear();
      minorStarted = false;
    }

    for (final raw in content.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final actM = actRe.firstMatch(trimmed);
      if (actM != null) {
        flushEvent();
        curAct = _Act(name: actM.group(1)!, events: []);
        acts.add(curAct);
        continue;
      }
      final evM = eventRe.firstMatch(trimmed);
      if (evM != null) {
        flushEvent();
        curTitle = evM.group(1)!.trim();
        minorStarted = false;
        continue;
      }
      if (trimmed.startsWith('○') || trimmed.startsWith('小事件')) {
        minorStarted = true; // 进入小事件块，概述收集结束
        continue;
      }
      if (curTitle != null && !minorStarted) {
        if (summaryBuf.isNotEmpty) summaryBuf.writeln();
        summaryBuf.write(trimmed);
      }
    }
    flushEvent();
    if (acts.length != 3) return null;
    for (final a in acts) {
      if (a.events.isEmpty) return null;
    }
    return acts;
  }

  /// 预估精写批次数（与 [_buildBatches] 的批次划分保持一致），
  /// 用于把历史记录视为「全部精写完成」以跳过精写循环。
  int _estimateRefinedBatchCount(List<_Act> acts) {
    final batchSize = _calcBatchSize(majorEventCount);
    var count = 0;
    for (final act in acts) {
      count += _groupList(act.events, batchSize).length;
    }
    return count;
  }

  /// 大事件检查点继续且内容被编辑后，基于编辑后的完整骨架重新提炼一次伏笔账本。
  Future<bool> _refreshLedgerFromSkeleton() async {
    currentStep = 2;
    _liveText = '正在按编辑后的大事件重新提炼伏笔账本...';
    notifyListeners();
    final r = await _runStructuredStep<_LedgerResult>(
      systemPrompt: OutlinePromptTemplate.jsonSystemPrompt,
      userPrompt: OutlinePromptTemplate.buildLedgerPrompt(
        batchContent: _renderSkeleton(),
        prevLedgerText: '（基于编辑后的大事件全新提炼）',
      ),
      maxTokens: _outlineSetting.maxTokens,
      temperature: 0.3,
      failureMessage: '伏笔账本重新提炼失败',
      validate: _parseLedger,
    );
    if (_cancelled || error != null) return false;
    if (r != null) {
      _ledgerForeshadows
        ..clear()
        ..addAll(r.foreshadows);
      _ledgerCharacters
        ..clear()
        ..addAll(r.characterStates);
      _ledgerUnresolved
        ..clear()
        ..addAll(r.unresolved);
    }
    _liveText = '';
    notifyListeners();
    return true;
  }

  /// 执行步骤 2 全部子步骤：粗骨架 → 分批精写 → 批次间抽取伏笔账本。
  ///
  /// 支持断点续跑：粗骨架已存在则跳过；已完成的批次（[_refinedBatchCount]）跳过，
  /// 从未完成批次继续。返回 false 表示取消或出错，调用方应终止流程。
  ///
  /// [forceSkeleton] 重新生成粗骨架（清空骨架与全部精写/账本后重跑）；
  /// [forceRefine] 保留骨架，重跑全部精写批次与伏笔账本（大事件检查点「重新生成」用）。
  Future<bool> _runStep2({
    bool forceSkeleton = false,
    bool forceRefine = false,
  }) async {
    if (forceSkeleton) {
      _step2Json = null;
      _refinedBatchCount = 0;
      _ledgerForeshadows.clear();
      _ledgerCharacters.clear();
      _ledgerUnresolved.clear();
    }
    if (forceRefine) {
      _refinedBatchCount = 0;
      _ledgerForeshadows.clear();
      _ledgerCharacters.clear();
      _ledgerUnresolved.clear();
    }

    // ── 2a：粗骨架规划（全部大事件仅标题+定位，锁定全局轨迹） ──
    var skeletonGenerated = false; // 本次调用是否实际生成了粗骨架（检查点触发条件）
    if (_step2Json == null) {
      currentStep = 1;
      _liveText = '正在规划三幕粗骨架...';
      notifyListeners();
      final t0 = DateTime.now();
      final r = await _runStructuredStep<_Step2Result>(
        systemPrompt: OutlinePromptTemplate.jsonSystemPrompt,
        userPrompt: OutlinePromptTemplate.buildCoarseSkeletonPrompt(
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
          majorEventCount: majorEventCount,
          minorEventCount: minorEventCount,
          titleAndConcept: _step1Text!,
        ),
        maxTokens: _outlineSetting.maxTokens,
        temperature: 0.3,
        failureMessage: '粗骨架生成失败：三幕结构或事件数量与设定（$majorEventCount）不一致',
        validate: (map) => _parseStep2(map, expectedCount: majorEventCount),
      );
      if (_cancelled || error != null) {
        await _persistProgress(phase: 2);
        loading = false;
        notifyListeners();
        return false;
      }
      _step2Json = r;
      skeletonGenerated = true;
      final totalEvents = r!.acts.fold<int>(
        0,
        (sum, a) => sum + a.events.length,
      );
      if (totalEvents != majorEventCount) {
        warning = '生成的大事件数为 $totalEvents，与设定 $majorEventCount 略有差异，已按实际数量继续生成';
      }
      final totalChars = r.acts.fold<int>(
        0,
        (sum, a) => sum + a.events.fold<int>(0, (s, e) => s + e.summary.length),
      );
      _stepStats.add(
        _StepStat(
          '规划三幕粗骨架',
          DateTime.now().difference(t0).inSeconds,
          totalChars,
        ),
      );
      _stepPreview = '${_step1Text ?? ''}\n\n${_renderSkeleton()}';
      _coarseSkeletonSnapshot = _renderSkeleton(); // 保存粗骨架原始快照（精写前的标题+定位）
      _upsertBubble('三幕粗骨架', _renderSkeleton());
      await _persistProgress(phase: 2);
      notifyListeners();
    }

    if (_cancelled || error != null) return false;

    // ── 检查点：粗骨架（可选）—— 骨架生成完成后暂停，供编辑/重新生成/返回上一步 ──
    // 仅在「本次实际生成骨架」或「续跑恢复的骨架检查点」时触发，避免恢复运行重复暂停
    if (_restoreCheckpointKind == 'skeleton' ||
        (skeletonGenerated && _outlineSetting.pauseAfterSkeleton)) {
      final isRestore = _restoreCheckpointKind == 'skeleton';
      var restoreText = isRestore ? _restoreCheckpointText : null;
      // 恢复且精写已完成（从大事件检查点返回后取消）→ 提供「下一步」回到大事件检查点
      final backSource = isRestore && _refinedBatchCount > 0 ? 'events' : null;
      _restoreCheckpointKind = null;
      _restoreCheckpointText = null;
      while (true) {
        final action = await _checkpointPause(
          'skeleton',
          initialText:
              restoreText ?? _coarseSkeletonSnapshot ?? _renderSkeleton(),
          backSource: backSource,
          originalText: (isRestore && restoreText != null)
              ? (_coarseSkeletonSnapshot ?? _renderSkeleton())
              : null,
          keepEdited: isRestore && restoreText != null,
        );
        restoreText = null;
        if (action == _CheckpointAction.cancel) {
          await _persistProgress(phase: 2);
          loading = false;
          notifyListeners();
          return false;
        }
        if (action == _CheckpointAction.regenerate) {
          // 重新生成粗骨架：清空骨架与精写/账本后整体重跑步骤 2（内部会再次暂停供审查）
          return _runStep2(forceSkeleton: true);
        }
        if (action == _CheckpointAction.back) {
          // 返回上一步：编辑书名与核心概念
          final tRes = await _runTitleCheckpointBack();
          if (tRes == null) return false;
          if (tRes == _TitleBackResult.forward) {
            continue; // title 点了「下一步」：重新暂停骨架检查点
          }
          if (tRes == _TitleBackResult.changed) {
            return _runStep2(forceSkeleton: true);
          }
          // 未变更：等同直接继续
          break;
        }
        if (action == _CheckpointAction.forward) {
          // 下一步（恢复场景）：反悔返回大事件检查点，交由 _doRunAll 恢复检查点逻辑触发
          _restoreCheckpointKind = 'events';
          _restoreCheckpointFromMinor = rawText.isNotEmpty;
          break;
        }
        // 继续：若用户编辑过骨架，已通过 continueCheckpoint 回填到 _step2Json
        if (isRestore && _refinedBatchCount > 0) {
          if (_checkpointEdited) {
            // 骨架在精写完成后被编辑：按新骨架重新精写
            final ok = await _runStep2(forceRefine: true);
            if (!ok || _cancelled || error != null) return false;
          } else {
            // 未编辑：恢复大事件检查点供审查（修复返回后取消、继续未完成生成的丢失检查点问题）
            _restoreCheckpointKind = 'events';
            _restoreCheckpointFromMinor = rawText.isNotEmpty;
          }
        }
        break;
      }
    }

    if (_cancelled || error != null) return false;

    // ── 2b：按幕顺序切批次（每批约总数 1/10，封顶 5 个） ──
    _step2Batches = _buildBatches(_step2Json!.acts);
    _step2BatchCount = _step2Batches.length;
    _ledgerBatchCount = _countLedgerBatches(_step2BatchCount);
    _step2SubStepCount = 1 + _step2BatchCount + _ledgerBatchCount;
    final estChunks = (majorEventCount / _maxEventsPerChunk).ceil();
    totalSteps = 2 + _step2SubStepCount + estChunks;
    stepLabels = [
      '生成书名和核心概念',
      '规划三幕粗骨架',
      ..._buildBatchLabels(_step2BatchCount),
      ...List.generate(estChunks, (_) => '展开细节'),
    ];
    final totalBatches = _step2Batches.length;

    // ── 2c：逐批「精写 + 间隔抽取伏笔账本」 ──
    var subStepIndex = 2; // 步骤 2 内部子步骤序号（0/1 为书名概念、粗骨架）
    _step2RefinedThisRun = false;
    for (int b = _refinedBatchCount; b < totalBatches; b++) {
      if (_cancelled || error != null) break;
      _step2RefinedThisRun = true;
      final batch = _step2Batches[b];

      // 精写本批大事件（粒度由「大事件粒度定义」约束，保证不退化）
      currentStep = subStepIndex++;
      _liveText = '正在精写第 ${b + 1}/$totalBatches 批大事件...';
      notifyListeners();
      final t0 = DateTime.now();
      // 注入紧邻上一批已精写的完整概述（仅上批、非全部历史），保证跨批大事件因果承接
      final prevRefined = b > 0
          ? _renderRefinedBatchContent(_step2Batches[b - 1])
          : '';
      final r = await _runStructuredStep<List<_Event>>(
        systemPrompt: OutlinePromptTemplate.jsonSystemPrompt,
        userPrompt: OutlinePromptTemplate.buildRefineBatchPrompt(
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
          title: title,
          concept: _step1Json?.concept ?? '',
          coarseSkeletonText: _renderSkeleton(),
          batchContent: _renderBatchContent(batch),
          ledgerText: _renderLedgerText(),
          prevRefinedContent: prevRefined,
        ),
        maxTokens: _outlineSetting.maxTokens,
        temperature: _outlineSetting.temperature,
        failureMessage: '第 ${b + 1} 批大事件精写失败：数量或字段与设定不符',
        validate: (map) =>
            _parseRefinedBatch(map, expected: batch.coarseEvents.length),
      );
      if (_cancelled || error != null) {
        await _persistProgress(phase: 2);
        loading = false;
        notifyListeners();
        return false;
      }
      _applyRefinedBatch(batch, r!);
      _stepStats.add(
        _StepStat(
          '精写大事件 (${b + 1}/$totalBatches)',
          DateTime.now().difference(t0).inSeconds,
          r.fold<int>(0, (sum, e) => sum + e.summary.length),
        ),
      );
      notifyListeners();

      // 按间隔抽取伏笔账本（伏笔/角色状态/悬念，供后续批次与展开延续）
      if (_needsLedger(b, totalBatches)) {
        currentStep = subStepIndex++;
        _liveText = '正在抽取第 ${b + 1}/$totalBatches 批的伏笔账本...';
        notifyListeners();
        final t1 = DateTime.now();
        final ledger = await _runStructuredStep<_LedgerResult>(
          systemPrompt: OutlinePromptTemplate.jsonSystemPrompt,
          userPrompt: OutlinePromptTemplate.buildLedgerPrompt(
            batchContent: _renderRefinedBatchContent(batch),
            prevLedgerText: _renderLedgerText(),
          ),
          maxTokens: _outlineSetting.maxTokens,
          temperature: 0.3,
          failureMessage: '伏笔账本抽取失败',
          validate: _parseLedger,
        );
        if (_cancelled || error != null) {
          await _persistProgress(phase: 2);
          loading = false;
          notifyListeners();
          return false;
        }
        if (ledger != null) {
          _ledgerForeshadows.addAll(ledger.foreshadows);
          for (final c in ledger.characterStates) {
            if (!_ledgerCharacters.contains(c)) _ledgerCharacters.add(c);
          }
          for (final u in ledger.unresolved) {
            if (!_ledgerUnresolved.contains(u)) _ledgerUnresolved.add(u);
          }
        }
        _stepStats.add(
          _StepStat(
            '抽取伏笔账本 (${b + 1}/$totalBatches)',
            DateTime.now().difference(t1).inSeconds,
            _ledgerForeshadows.length * 20,
          ),
        );
      }
      _refinedBatchCount++;
      _stepPreview = '${_step1Text ?? ''}\n\n${_renderSkeleton()}';
      _upsertBubble('三幕粗骨架', _renderSkeleton()); // 精写推进后同步刷新骨架气泡
      await _persistProgress(phase: 2);
      notifyListeners();
    }

    return !_cancelled && error == null;
  }

  /// 按幕顺序把大事件切成批次，每批约总数的 1/10（封顶 5 个）
  List<_Step2Batch> _buildBatches(List<_Act> acts) {
    final batchSize = _calcBatchSize(majorEventCount);
    final batches = <_Step2Batch>[];
    var globalIndex = 0;
    for (int i = 0; i < acts.length; i++) {
      final events = acts[i].events;
      final groups = _groupList(events, batchSize);
      var start = 0;
      for (final g in groups) {
        batches.add(
          _Step2Batch(
            actIndex: i,
            startInAct: start,
            coarseEvents: g,
            globalStartIndex: globalIndex + 1,
          ),
        );
        globalIndex += g.length;
        start += g.length;
      }
    }
    return batches;
  }

  /// 批次大小：约总数的 1/10，限制在 2~5 个之间
  /// （最小 2 个一批，避免小数量时批次过多导致调用数翻倍）
  int _calcBatchSize(int total) {
    final s = (total / 10).ceil();
    return s < 2 ? 2 : (s > 5 ? 5 : s);
  }

  /// 该批是否需要抽取伏笔账本：按 [_ledgerInterval] 间隔抽取，末批必定抽取。
  /// 只依赖批次下标与总批次数，可确定性还原，断点续跑不受影响。
  bool _needsLedger(int batchIndex, int totalBatches) =>
      batchIndex == totalBatches - 1 || (batchIndex + 1) % _ledgerInterval == 0;

  /// [totalBatches] 个批次中需要抽取账本的批次数
  int _countLedgerBatches(int totalBatches) {
    if (totalBatches <= 0) return 0;
    var count = 0;
    for (int b = 0; b < totalBatches; b++) {
      if (_needsLedger(b, totalBatches)) count++;
    }
    return count;
  }

  /// 把精写结果回填到骨架对应位置
  void _applyRefinedBatch(_Step2Batch batch, List<_Event> refined) {
    final acts = List<_Act>.from(_step2Json!.acts);
    final old = acts[batch.actIndex];
    final newEvents = List<_Event>.from(old.events);
    for (int k = 0; k < refined.length; k++) {
      newEvents[batch.startInAct + k] = refined[k];
    }
    acts[batch.actIndex] = _Act(name: old.name, events: newEvents);
    _step2Json = _Step2Result(acts: acts);
  }

  /// 解析批次精写 JSON，校验数量与字段
  List<_Event>? _parseRefinedBatch(
    Map<String, dynamic> map, {
    required int expected,
  }) {
    final raw = map['events'];
    if (raw is! List || raw.length != expected) return null;
    final events = <_Event>[];
    for (final er in raw) {
      if (er is! Map) return null;
      final t = er['title'];
      final s = er['summary'];
      if (t is! String || t.trim().isEmpty) return null;
      if (s is! String || s.trim().isEmpty) return null;
      events.add(_Event(title: t.trim(), summary: s.trim()));
    }
    return events;
  }

  /// 解析伏笔账本 JSON
  _LedgerResult? _parseLedger(Map<String, dynamic> map) {
    final fs = map['foreshadows'];
    if (fs is! List) return null;
    final items = <Map<String, dynamic>>[];
    for (final f in fs) {
      if (f is Map<String, dynamic>) items.add(f);
    }
    final chars =
        (map['character_states'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final unres =
        (map['unresolved'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return _LedgerResult(
      foreshadows: items,
      characterStates: chars,
      unresolved: unres,
    );
  }

  /// 渲染某批的粗骨架内容（标题+定位），供精写提示词使用
  String _renderBatchContent(_Step2Batch batch) {
    final buf = StringBuffer();
    for (int k = 0; k < batch.coarseEvents.length; k++) {
      final e = batch.coarseEvents[k];
      buf.writeln('大事件${batch.globalStartIndex + k}：${e.title}');
      buf.writeln(e.summary);
      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// 渲染某批精写后的完整内容（标题+概述），供账本抽取提示词使用
  String _renderRefinedBatchContent(_Step2Batch batch) {
    final events = _step2Json!.acts[batch.actIndex].events;
    final buf = StringBuffer();
    for (int k = 0; k < batch.coarseEvents.length; k++) {
      final e = events[batch.startInAct + k];
      buf.writeln('大事件${batch.globalStartIndex + k}：${e.title}');
      buf.writeln(e.summary);
      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// 渲染已积累的伏笔账本文本，供后续批次提示词注入
  String _renderLedgerText() {
    if (_ledgerForeshadows.isEmpty &&
        _ledgerCharacters.isEmpty &&
        _ledgerUnresolved.isEmpty) {
      return '（暂无）';
    }
    final buf = StringBuffer();
    if (_ledgerForeshadows.isNotEmpty) {
      buf.writeln('伏笔：');
      for (final f in _ledgerForeshadows) {
        buf.writeln(
          '- ${f['content']}（状态：${f['status'] ?? '已埋'} / 计划：${f['plan'] ?? '未定'}）',
        );
      }
    }
    if (_ledgerCharacters.isNotEmpty) {
      buf.writeln('角色状态：');
      for (final c in _ledgerCharacters) {
        buf.writeln('- $c');
      }
    }
    if (_ledgerUnresolved.isNotEmpty) {
      buf.writeln('未解决悬念：');
      for (final u in _ledgerUnresolved) {
        buf.writeln('- $u');
      }
    }
    return buf.toString().trim();
  }

  /// 生成批次进度标签（每批一格精写，需抽账本的批额外一格抽取）
  List<String> _buildBatchLabels(int totalBatches) => [
    for (int i = 0; i < totalBatches; i++) ...[
      '精写大事件 (${i + 1}/$totalBatches)',
      if (_needsLedger(i, totalBatches)) '抽取伏笔账本 (${i + 1}/$totalBatches)',
    ],
  ];

  // ─── 步骤 3：构建块 + 并行展开 ───────────────────────────────

  void _buildChunks() {
    const actHeaders = ['══ 第一幕：开端 ══', '══ 第二幕：发展 ══', '══ 第三幕：高潮&结局 ══'];
    const actNames = ['第一幕', '第二幕', '第三幕'];
    final acts = _step2Json!.acts;
    _chunks = [];
    var globalIndex = 0;
    for (int i = 0; i < acts.length; i++) {
      final events = acts[i].events;
      final groups = _groupList(events, _maxEventsPerChunk);
      for (int j = 0; j < groups.length; j++) {
        final chunkStartIndex = globalIndex + 1; // 本块首个大事件的全局序号
        final content = groups[j]
            .map((e) {
              globalIndex++;
              return '大事件$globalIndex：${e.title}\n${e.summary}';
            })
            .join('\n\n');
        _chunks.add(
          _ExpandChunk(
            actIndex: i,
            header: i < actHeaders.length ? actHeaders[i] : '══ 第${i + 1}幕 ══',
            actName: i < actNames.length ? actNames[i] : '第${i + 1}幕',
            content: content,
            chunkIndex: j,
            totalChunks: groups.length,
            isActStart: j == 0,
            globalStartIndex: chunkStartIndex,
            globalEndIndex: globalIndex, // 本块最后一个大事件的全局序号
          ),
        );
      }
    }
    totalSteps = 2 + _step2SubStepCount + _chunks.length;
    stepLabels = [
      '生成书名和核心概念',
      '规划三幕粗骨架',
      ..._buildBatchLabels(_step2BatchCount),
      ..._chunks.map(
        (c) => c.totalChunks > 1
            ? '展开${c.actName}细节 (${c.chunkIndex + 1}/${c.totalChunks})'
            : '展开${c.actName}细节',
      ),
    ];
    final doneCount = _completedChunkCount > _chunks.length
        ? _chunks.length
        : _completedChunkCount;
    for (int i = 0; i < doneCount; i++) {
      _chunks[i].done = true;
    }
    _flushIndex = doneCount;
    _completedChunkCount = doneCount;
    currentStep = 2 + _step2SubStepCount + doneCount;
    _liveText = '';
    notifyListeners();
  }

  Future<void> _runChunksParallel({required String systemPrompt}) async {
    final total = _chunks.length;
    if (total == 0) return;
    var next = _completedChunkCount;
    var running = 0;
    final completer = Completer<void>();
    void pump() {
      while (running < _maxConcurrentChunks && next < total) {
        if (_cancelled || error != null) break;
        final idx = next++;
        running++;
        _expandChunk(idx, systemPrompt).whenComplete(() {
          running--;
          pump();
        });
      }
      if (running == 0 && !completer.isCompleted) {
        completer.complete();
      }
    }

    pump();
    await completer.future;
  }

  /// 重新展开步骤 3：清空已生成的小事件内容，按当前（可能已编辑的）骨架重新生成全部小事件。
  /// 供小事件检查点返回上一步改动大事件/骨架/书名后重建全文。
  Future<void> _rerunChunks() async {
    _chunks = [];
    _flushIndex = 0;
    _completedChunkCount = 0;
    rawText = '';
    _liveText = '';
    _buildChunks();
    await _runChunksParallel(systemPrompt: _systemPrompt);
  }

  Future<void> _expandChunk(int index, String systemPrompt) async {
    final chunk = _chunks[index];
    final token = CancelToken();
    _activeTokens.add(token);
    final t0 = DateTime.now();
    final labelIndex = index + _step2SubStepCount + 1;
    final label = stepLabels.length > labelIndex
        ? stepLabels[labelIndex]
        : '展开细节';
    try {
      // 前文已展开的详细内容：只注入紧邻的前一块完整文本，
      // 保证本块开头承接其结尾状态、不重复不矛盾；更早的内容由全局骨架兜底。
      // 断点续跑恢复时前一块 buffer 为空，回退到 rawText 中已刷入的文本。
      String previousContent = '';
      if (index > 0) {
        final prev = _chunks[index - 1];
        previousContent = prev.buffer.trim().isNotEmpty
            ? (prev.isActStart
                  ? '${prev.header}\n${prev.buffer.trim()}'
                  : prev.buffer.trim())
            : _rawTextWithoutTitle().trim();
      }
      // 紧接着的后一块大事件（若有）：只注入下一块，聚焦最近的过渡目标
      final nextChunk = index + 1 < _chunks.length ? _chunks[index + 1] : null;
      final truncated = await _streamChunk(
        systemPrompt: systemPrompt,
        userPrompt: OutlinePromptTemplate.buildStep3Prompt(
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
          majorEventCount: majorEventCount,
          minorEventCount: minorEventCount,
          title: title,
          actContent: chunk.content,
          actIndex: chunk.actIndex + 1,
          globalSummary: _buildGlobalSummary(),
          previousContent: previousContent,
          laterContent: nextChunk == null
              ? ''
              : _renderLaterSkeleton(
                  nextChunk.globalStartIndex,
                  nextChunk.globalEndIndex,
                ),
        ),
        maxTokens: _outlineSetting.maxTokens,
        temperature: _outlineSetting.temperature,
        token: token,
        chunk: chunk,
      );
      if (_cancelled) return;
      chunk.done = true;
      if (truncated) {
        chunk.truncated = true;
        warning =
            '部分展开已自动续写 $chunk.continuations 次仍被 max_tokens 截断，建议在设置中调大最大生成长度';
      }
      _completedChunkCount++;
      currentStep = 2 + _step2SubStepCount + _completedChunkCount;
      _stepStats.add(
        _StepStat(
          label,
          DateTime.now().difference(t0).inSeconds,
          chunk.buffer.length,
        ),
      );
      _flushCompletedChunks();
      await _persistProgress(phase: 3);
      notifyListeners();
      scrollToBottom();
    } catch (e) {
      if (!_cancelled && error == null) {
        error = e.toString().replaceFirst('Exception: ', '');
      }
      notifyListeners();
    } finally {
      _activeTokens.remove(token);
    }
  }

  /// 流式展开一块内容。
  ///
  /// 当检测到 `finish_reason == 'length'`（输出被 max_tokens 截断）时，
  /// 自动携带已生成内容发起续写请求，循环直到输出完整或达到 [_maxContinuations]。
  /// 返回最终是否仍处于截断状态（续写次数用尽仍未写完）。
  Future<bool> _streamChunk({
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    required double temperature,
    required CancelToken token,
    required _ExpandChunk chunk,
  }) async {
    var continuation = 0;
    var finalFinish = '';
    while (true) {
      if (_cancelled) return false;
      chunk.continuing = continuation > 0;
      if (chunk.continuing) {
        _liveText = _mergeChunkLiveText();
        notifyListeners();
      }
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ];
      if (continuation > 0) {
        // 续写时重发完整已生成内容，保证模型掌握完整上下文、衔接不断裂
        messages.addAll([
          {
            'role': 'assistant',
            'content': chunk.buffer.isEmpty ? '（尚无内容）' : chunk.buffer,
          },
          {
            'role': 'user',
            'content':
                '请直接从刚才中断的位置继续输出后面的内容，'
                '不要重复已经生成的部分，不要添加解释性文字。',
          },
        ]);
      }
      String roundFinish = '';
      var attempt = 0;
      while (true) {
        if (_cancelled) return false;
        final roundStartLen = chunk.buffer.length;
        final completer = Completer<void>();
        try {
          await _outlineService.streamGenerate(
            apiKey: _apiKey,
            apiParams: {
              ..._baseParams,
              'temperature': temperature,
              'max_tokens': maxTokens,
              'stream': true,
              if (!_outlineSetting.enableThinking)
                'thinking': {'type': 'disabled'},
            },
            messages: messages,
            cancelToken: token,
            onChunk: (chunkData) {
              final choices = chunkData['choices'] as List?;
              if (choices == null || choices.isEmpty) return;
              final delta = choices[0]['delta'] as Map<String, dynamic>?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                chunk.buffer += content;
                _liveText = _mergeChunkLiveText();
                _throttledNotify();
                _throttledScroll();
              }
              // 思考过程也实时合并进展示文本：推理模型在输出正文前会先流式
              // 输出 reasoning_content，不展示会被误认为卡死
              final reasoning = delta?['reasoning_content'] as String?;
              if (reasoning != null && reasoning.isNotEmpty) {
                chunk.reasoning += reasoning;
                _liveText = _mergeChunkLiveText();
                _throttledNotify();
                _throttledScroll();
              }
              final fr = choices[0]['finish_reason'] as String?;
              if (fr != null && fr.isNotEmpty) roundFinish = fr;
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (msg) {
              if (!completer.isCompleted) completer.completeError(msg);
            },
          );
          await completer.future;
        } catch (_) {
          if (_cancelled) return false;
          // 已收到部分内容时重试会造成重复输出，不再重试；
          // 仅对「未收到任何内容」的瞬时网络失败做退避重试
          final receivedContent = chunk.buffer.length > roundStartLen;
          if (!receivedContent && attempt < _maxChunkRetries) {
            attempt++;
            await _retryWait(attempt);
            _liveText = _mergeChunkLiveText();
            notifyListeners();
            continue;
          }
          rethrow;
        }
        break;
      }
      if (_cancelled) return false;

      finalFinish = roundFinish;
      if (roundFinish != 'length') break;
      if (continuation >= _maxContinuations) break;
      continuation++;
    }
    chunk.continuations = continuation;
    chunk.continuing = false;
    _liveText = _mergeChunkLiveText();
    notifyListeners();
    return finalFinish == 'length';
  }

  /// 结构化步骤（步骤1/2）的实时展示：思考过程 + 生成内容
  ///
  /// [reasoning] 为推理模型输出的 reasoning_content；无思考过程时仅展示生成内容。
  String _mergeStructuredLiveText(String content, String reasoning) {
    if (reasoning.trim().isEmpty) return content;
    return '【思考过程】\n$reasoning\n\n【生成内容】\n$content';
  }

  /// 按块顺序合并尚未刷入 rawText 的各块缓冲（含乱序完成但未刷入的块）。
  /// 有思考过程时以「【思考过程】+【生成内容】」结构展示，避免推理阶段看起来卡死。
  String _mergeChunkLiveText() {
    if (_flushIndex >= _chunks.length) return '';
    final parts = <String>[];
    for (int i = _flushIndex; i < _chunks.length; i++) {
      final c = _chunks[i];
      if (c.buffer.isEmpty && c.reasoning.isEmpty) continue;
      final String body;
      if (c.reasoning.trim().isEmpty) {
        body = c.buffer;
      } else if (c.buffer.trim().isEmpty) {
        body = '【思考过程】\n${c.reasoning}';
      } else {
        body = '【思考过程】\n${c.reasoning}\n\n【生成内容】\n${c.buffer}';
      }
      parts.add(c.isActStart ? '${c.header}\n$body' : body);
    }
    return parts.join('\n\n');
  }

  /// 将连续完成的块按序刷入 rawText，并为每块提交一个展示气泡
  void _flushCompletedChunks() {
    while (_flushIndex < _chunks.length && _chunks[_flushIndex].done) {
      final c = _chunks[_flushIndex];
      final segment = c.isActStart
          ? '${c.header}\n${c.buffer.trim()}'
          : c.buffer.trim();
      if (rawText.isEmpty) {
        rawText = '${_step1Text ?? ''}\n\n$segment';
      } else {
        rawText = '$rawText\n\n$segment';
      }
      _bubbles.add(
        OutlineStepBubble(
          label: c.totalChunks > 1
              ? '${c.actName} · ${c.chunkIndex + 1}/${c.totalChunks}'
              : c.actName,
          content: segment,
        ),
      );
      _flushIndex++;
    }
    _liveText = _mergeChunkLiveText();
    notifyListeners();
  }

  /// 全局摘要：书名+概念+完整三幕骨架+伏笔账本，注入每个展开块提示词
  String _buildGlobalSummary() {
    final ledgerPart = _ledgerForeshadows.isEmpty
        ? ''
        : '\n\n伏笔账本：\n${_renderLedgerText()}';
    return '${_step1Text ?? ''}\n\n完整三幕骨架：\n${_renderSkeleton()}$ledgerPart';
  }

  String _renderSkeleton() {
    final acts = _step2Json?.acts ?? const <_Act>[];
    const headers = ['══ 第一幕：开端 ══', '══ 第二幕：发展 ══', '══ 第三幕：高潮&结局 ══'];
    final buf = StringBuffer();
    var idx = 0;
    for (int i = 0; i < acts.length; i++) {
      buf.writeln(i < headers.length ? headers[i] : '══ 第${i + 1}幕 ══');
      for (final e in acts[i].events) {
        idx++;
        buf.writeln('大事件$idx：${e.title}');
        buf.writeln(e.summary);
        buf.writeln();
      }
    }
    return buf.toString().trim();
  }

  /// 渲染指定全局序号范围内的大事件粗骨架（标题+定位），
  /// 当前只渲染「紧接着的下一块」，供展开提示词做「向后铺垫、平滑过渡」。
  String _renderLaterSkeleton(int fromGlobalIndex, int toGlobalIndex) {
    final acts = _step2Json?.acts ?? const <_Act>[];
    final buf = StringBuffer();
    var idx = 0;
    for (final act in acts) {
      for (final e in act.events) {
        idx++;
        if (idx < fromGlobalIndex || idx > toGlobalIndex) continue;
        buf.writeln('大事件$idx：${e.title}');
        buf.writeln(e.summary);
        buf.writeln();
      }
    }
    return buf.toString().trim();
  }

  /// 去掉 rawText 开头的书名+概念前缀，返回已刷入的展开块文本。
  /// 断点续跑时前序块 buffer 为空，用此方法从落盘内容重建「前文上下文」。
  String _rawTextWithoutTitle() {
    var s = rawText;
    final prefix = _step1Text ?? '';
    if (prefix.isNotEmpty && s.startsWith(prefix)) {
      s = s.substring(prefix.length);
      if (s.startsWith('\n\n')) s = s.substring(2);
    }
    return s;
  }

  // ─── 流式节流 ────────────────────────────────────────────────

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotifyTime) >= _throttleInterval) {
      _lastNotifyTime = now;
      notifyListeners();
    }
  }

  void _throttledScroll() {
    final now = DateTime.now();
    if (now.difference(_lastScrollTime) < _throttleInterval) return;
    _lastScrollTime = now;
    scrollToBottom();
  }

  // ─── 内部工具 ────────────────────────────────────────────────

  OutlineRecord _buildRecord() {
    final ledger = _renderLedgerText();
    return OutlineRecord(
      title: title,
      genre: genreController.text,
      theme: themeController.text,
      protagonist: protagonistController.text,
      worldview: worldViewController.text,
      content: rawText,
      // 持久化伏笔账本，供「大纲转章节」写正文时注入【伏笔清单】；
      // 局部重新生成未产出新账本时，沿用原记录的伏笔清单
      foreshadows: ledger == '（暂无）' && _fallbackForeshadows.isNotEmpty
          ? _fallbackForeshadows
          : ledger,
      // 持久化三幕骨架（书名/概念 + 精写后大事件 + 续写所需进度信息），
      // 供小事件未生成完就保存的历史大纲也能重新编辑粗骨/大事件，或继续生成
      skeleton: _step1Json != null && _step2Json != null
          ? jsonEncode({
              'step1': _step1Json!.toJson(),
              'step2': _step2Json!.toJson(),
              'minorEventCount': minorEventCount,
              'majorEventCount': majorEventCount,
              'completedChunks': _completedChunkCount,
              'totalChunks': _chunks.length,
              'ledger': {
                'foreshadows': _ledgerForeshadows,
                'characters': _ledgerCharacters,
                'unresolved': _ledgerUnresolved,
              },
            })
          : '',
    );
  }

  /// 将列表按每 [chunkSize] 个分组
  List<List<T>> _groupList<T>(List<T> list, int chunkSize) {
    final groups = <List<T>>[];
    for (int i = 0; i < list.length; i += chunkSize) {
      groups.add(
        list.sublist(
          i,
          i + chunkSize > list.length ? list.length : i + chunkSize,
        ),
      );
    }
    return groups;
  }

  void _resetState() {
    _checkpointSyncTimer?.cancel();
    _checkpointSyncTimer = null;
    loading = true;
    error = null;
    warning = null;
    message = null;
    rawText = '';
    title = '';
    _liveText = '';
    _bubbles.clear();
    _cancelled = false;
    currentStep = 0;
    totalSteps = 0;
    stepLabels = [];
    _stepStats.clear();
    _step1Text = null;
    _step1Json = null;
    _step2Json = null;
    _coarseSkeletonSnapshot = null;
    _systemPrompt = '';
    _stepPreview = '';
    _step2Batches = [];
    _step2BatchCount = 0;
    _ledgerBatchCount = 0;
    _step2SubStepCount = 1;
    _refinedBatchCount = 0;
    _step2RefinedThisRun = false;
    _ledgerForeshadows.clear();
    _ledgerCharacters.clear();
    _ledgerUnresolved.clear();
    _chunks = [];
    _flushIndex = 0;
    _completedChunkCount = 0;
    paused = false;
    checkpointKind = null;
    checkpointText = '';
    checkpointBackSource = null;
    _checkpointOriginalText = '';
    _checkpointEdited = false;
    _checkpointResumer = null;
    _checkpointAction = _CheckpointAction.none;
    _restoreCheckpointKind = null;
    _restoreCheckpointText = null;
    _restoreCheckpointFromMinor = false;
    _lastSavedCheckpoint = null;
    _fallbackForeshadows = '';
    notifyListeners();
  }

  // ─── 断点续跑：本地落盘 ──────────────────────────────────────

  Future<File> _ensureProgressFile() async {
    if (_progressFile != null) return _progressFile!;
    final dir = await getApplicationDocumentsDirectory();
    _progressFile = File('${dir.path}/$_progressFileName');
    return _progressFile!;
  }

  Future<void> _deleteProgress() async {
    _lastSavedCheckpoint = null;
    // 等待在途/排队中的写入全部完成后删除，避免已入队的写入把草稿又写回来
    await _writeQueue;
    try {
      final file = await _ensureProgressFile();
      if (file.existsSync()) await file.delete();
      final tmp = File('${file.path}.tmp');
      if (tmp.existsSync()) await tmp.delete();
    } catch (_) {}
  }

  Future<void> _persistProgress({int? phase}) async {
    try {
      // 暂停态保存当前检查点；非暂停态（取消后流程收尾）沿用最近一次暂停保存的检查点，
      // 避免取消时 checkpointKind 被清空后覆盖丢失，导致续跑无法回到检查点。
      // 一旦进入步骤 3（小事件展开，_chunks 已构建），旧骨架/大事件检查点已通过，
      // 不再落盘旧检查点，否则小事件中断续跑会被旧检查点拦回、无法从中断处继续。
      Map<String, dynamic>? checkpointData;
      if (paused && checkpointKind != null) {
        checkpointData = {
          'kind': checkpointKind,
          'text': checkpointText,
          'originalText': _checkpointOriginalText,
          'edited': _checkpointEdited,
          'fromMinor': checkpointBackSource == 'minor',
        };
        _lastSavedCheckpoint = checkpointData;
      } else if (_chunks.isEmpty) {
        checkpointData = _lastSavedCheckpoint;
      }
      final data = {
        'genre': genreController.text,
        'theme': themeController.text,
        'protagonist': protagonistController.text,
        'worldview': worldViewController.text,
        'majorEventCount': majorEventCount,
        'minorEventCount': minorEventCount,
        'phase': phase ?? _currentPhase(),
        'step2Format': 'batch',
        'title': title,
        'step1Text': _step1Text ?? '',
        'step1Json': _step1Json?.toJson(),
        'step2Json': _step2Json?.toJson(),
        'coarseSkeletonSnapshot': _coarseSkeletonSnapshot ?? '',
        'refinedBatchCount': _refinedBatchCount,
        'ledger': {
          'foreshadows': _ledgerForeshadows,
          'characters': _ledgerCharacters,
          'unresolved': _ledgerUnresolved,
        },
        'completedChunks': _completedChunkCount,
        'rawText': rawText,
        if (checkpointData != null) 'checkpoint': checkpointData,
      };
      // 串行化落盘：同一时刻仅一个写操作在途，后续写入排队依次执行，
      // 避免并发 writeAsString 覆盖竞态
      _writeQueue = _writeQueue
          .then((_) => _atomicWrite(data))
          .catchError((_) {});
      return _writeQueue;
    } catch (_) {
      return Future<void>.value();
    }
  }

  /// 原子写入进度草稿：先写临时文件再 rename 覆盖，
  /// 避免写入中途进程被杀/崩溃留下半截 JSON 损坏整份草稿。
  Future<void> _atomicWrite(Map<String, dynamic> data) async {
    try {
      final file = await _ensureProgressFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  int _currentPhase() {
    if (_step1Json == null) return 1;
    if (_step2Json == null) return 2;
    return 3;
  }

  Future<Map<String, dynamic>?> _loadProgress() async {
    try {
      final file = await _ensureProgressFile();
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void _applyProgress(Map<String, dynamic> data) {
    genreController.text = data['genre'] as String? ?? genreController.text;
    themeController.text = data['theme'] as String? ?? themeController.text;
    protagonistController.text =
        data['protagonist'] as String? ?? protagonistController.text;
    worldViewController.text =
        data['worldview'] as String? ?? worldViewController.text;
    majorEventCount = data['majorEventCount'] as int? ?? majorEventCount;
    minorEventCount = data['minorEventCount'] as int? ?? minorEventCount;
    title = data['title'] as String? ?? '';
    _step1Text = data['step1Text'] as String?;
    final s1 = data['step1Json'];
    if (s1 is Map<String, dynamic>) _step1Json = _Step1Result.fromMap(s1);
    // 旧版 step2Json 是「一次生成整份骨架」，与分批精写格式不兼容，强制重新生成
    if (data['step2Format'] != 'batch') {
      _step2Json = null;
      _refinedBatchCount = 0;
    } else {
      final s2 = data['step2Json'];
      if (s2 is Map<String, dynamic>) _step2Json = _Step2Result.fromMap(s2);
      _coarseSkeletonSnapshot =
          (data['coarseSkeletonSnapshot'] as String?)?.trim().isNotEmpty == true
          ? data['coarseSkeletonSnapshot'] as String
          : null;
      _refinedBatchCount = data['refinedBatchCount'] as int? ?? 0;
      final ledger = data['ledger'];
      if (ledger is Map<String, dynamic>) {
        _ledgerForeshadows
          ..clear()
          ..addAll(
            (ledger['foreshadows'] as List?)
                    ?.whereType<Map<String, dynamic>>() ??
                const [],
          );
        _ledgerCharacters
          ..clear()
          ..addAll(
            (ledger['characters'] as List?)?.whereType<String>() ?? const [],
          );
        _ledgerUnresolved
          ..clear()
          ..addAll(
            (ledger['unresolved'] as List?)?.whereType<String>() ?? const [],
          );
      }
    }
    _stepPreview = _step1Text ?? '';
    if (_step2Json != null) {
      _stepPreview = '${_step1Text ?? ''}\n\n${_renderSkeleton()}';
    }
    _completedChunkCount = data['completedChunks'] as int? ?? 0;
    rawText = data['rawText'] as String? ?? '';
    // 续跑恢复：把已有内容提交为一个历史气泡，后续新内容会追加为独立气泡
    if (displayText.isNotEmpty) {
      _bubbles.add(OutlineStepBubble(label: '已生成内容', content: displayText));
    }
    // 检查点恢复：若上次暂停在粗骨架/大事件检查点，恢复暂停态供用户继续
    final cp = data['checkpoint'];
    if (cp is Map<String, dynamic>) {
      final kind = cp['kind'] as String?;
      final text = cp['text'] as String? ?? '';
      if (kind != null && text.trim().isNotEmpty) {
        _restoreCheckpointKind = kind;
        _restoreCheckpointText = text;
        _restoreCheckpointFromMinor = cp['fromMinor'] == true;
        checkpointKind = kind;
        checkpointText = text;
        _checkpointOriginalText = cp['originalText'] as String? ?? text;
        _checkpointEdited = cp['edited'] == true;
        paused = true;
        loading = false;
      }
    }
  }
}

/// 结构化步骤解析失败异常
class _StepParseException implements Exception {
  final String message;
  _StepParseException(this.message);

  @override
  String toString() => message;
}

/// 检查点用户操作意图：none 表示继续（沿用当前内容）
enum _CheckpointAction { none, regenerate, cancel, back, forward }

/// 「书名与核心概念」检查点循环结果：
/// [forward] 用户点了「下一步」（反悔返回骨架检查点）；
/// [changed] 书名/概念有变更（编辑或重新生成）；[unchanged] 未变更直接继续。
enum _TitleBackResult { forward, changed, unchanged }

/// 单步统计（耗时 + 输出字符估算）
class _StepStat {
  final String label;
  final int seconds;
  final int chars;
  _StepStat(this.label, this.seconds, this.chars);

  String get summary => '$label · ${seconds}s · 约${(chars / 2).round()} tokens';
}

/// 步骤 1 结果：书名 + 核心概念
class _Step1Result {
  final String title;
  final String concept;
  _Step1Result({required this.title, required this.concept});

  Map<String, dynamic> toJson() => {'title': title, 'concept': concept};

  factory _Step1Result.fromMap(Map<String, dynamic> m) => _Step1Result(
    title: m['title'] as String? ?? '',
    concept: m['concept'] as String? ?? '',
  );
}

/// 步骤 2 结果：三幕结构
class _Step2Result {
  final List<_Act> acts;
  _Step2Result({required this.acts});

  Map<String, dynamic> toJson() => {
    'acts': acts.map((a) => a.toJson()).toList(),
  };

  factory _Step2Result.fromMap(Map<String, dynamic> m) => _Step2Result(
    acts: ((m['acts'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_Act.fromMap)
        .toList(),
  );
}

class _Act {
  final String name;
  final List<_Event> events;
  _Act({required this.name, required this.events});

  Map<String, dynamic> toJson() => {
    'act': name,
    'events': events.map((e) => e.toJson()).toList(),
  };

  factory _Act.fromMap(Map<String, dynamic> m) => _Act(
    name: m['act'] as String? ?? '',
    events: ((m['events'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_Event.fromMap)
        .toList(),
  );
}

class _Event {
  final String title;
  final String summary;
  _Event({required this.title, required this.summary});

  Map<String, dynamic> toJson() => {'title': title, 'summary': summary};

  factory _Event.fromMap(Map<String, dynamic> m) => _Event(
    title: m['title'] as String? ?? '',
    summary: m['summary'] as String? ?? '',
  );
}

/// 展开块元信息（含流式缓冲）
class _ExpandChunk {
  final int actIndex;
  final String header;
  final String actName;
  final String content;
  final int chunkIndex;
  final int totalChunks;
  final bool isActStart;
  final int globalStartIndex; // 本块首个大事件的全局序号（1-based）
  final int globalEndIndex; // 本块最后一个大事件的全局序号（1-based，含）
  String buffer = '';
  String reasoning = ''; // 本块流式思考过程（reasoning_content，供实时展示）
  bool done = false;
  bool truncated = false;
  bool continuing = false; // 是否正处于自动续写状态
  int continuations = 0; // 自动续写次数

  _ExpandChunk({
    required this.actIndex,
    required this.header,
    required this.actName,
    required this.content,
    required this.chunkIndex,
    required this.totalChunks,
    required this.isActStart,
    required this.globalStartIndex,
    required this.globalEndIndex,
  });
}

/// 步骤 2 的一个精写批次：某幕内连续的一段大事件（粗骨架定位）
class _Step2Batch {
  final int actIndex; // 所在幕下标
  final int startInAct; // 本批在幕内的起始下标
  final List<_Event> coarseEvents; // 粗骨架事件（summary 字段存一句话定位）
  final int globalStartIndex; // 本批首个事件的全局序号（1-based，用于展示"大事件N"）

  _Step2Batch({
    required this.actIndex,
    required this.startInAct,
    required this.coarseEvents,
    required this.globalStartIndex,
  });
}

/// 伏笔账本解析结果：伏笔 / 角色状态 / 未解决悬念
class _LedgerResult {
  final List<Map<String, dynamic>> foreshadows;
  final List<String> characterStates;
  final List<String> unresolved;

  _LedgerResult({
    required this.foreshadows,
    required this.characterStates,
    required this.unresolved,
  });
}

/// 生成过程展示气泡：步骤/尝试级内容快照（思考 + 生成内容）
/// [content] 可变：检查点编辑/重新生成后由控制器原位刷新，保证展示与最新内容一致
class OutlineStepBubble {
  final String label;
  String content;
  final bool isError;

  OutlineStepBubble({
    required this.label,
    required this.content,
    this.isError = false,
  });
}
