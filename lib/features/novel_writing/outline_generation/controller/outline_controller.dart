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
/// 3. 展开：并行逐块展开大/小事件细节（每块最多 5 个大事件，限流并发）
///
/// 可靠性特性：
/// - 步骤 1/2 解析失败自动重试（最多 2 次、指数退避）；步骤 3 块级请求网络失败自动重试
/// - 每步结果本地落盘，支持从失败步骤断点续跑
/// - 步骤 3 各块并行请求，UI 按序合并展示
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
  static const int _maxEventsPerChunk = 5;
  static const int _maxConcurrentChunks = 3;
  static const int _maxRetries = 2;
  static const int _maxChunkRetries = 2; // 展开块未收到内容时的网络失败自动重试次数
  static const int _maxContinuations = 5; // 展开块因 max_tokens 截断时的最大自动续写次数
  static const int _maxJsonTokens = 16000; // 结构化步骤截断重试时的 max_tokens 上限
  static const int _ledgerInterval = 2; // 每 N 批抽取一次伏笔账本（末批必定抽取）
  static const int _continuationTailChars = 1500; // 续写时携带的缓冲尾部长度上限
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

  // ─── 步骤 2 分批精写状态 ─────────────────────────────────────
  List<_Step2Batch> _step2Batches = []; // 本轮按幕顺序切好的批次
  int _step2BatchCount = 0; // 批次数（用于进度标签）
  int _ledgerBatchCount = 0; // 需抽取账本的批次数
  int _step2SubStepCount = 1; // 步骤 2 子调用数 = 1（粗骨架）+ 精写批次 + 账本批次
  int _refinedBatchCount = 0; // 已完成（精写+账本）的批次数，断点续跑从此继续
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

  // 并行展开状态
  List<_ExpandChunk> _chunks = [];
  int _flushIndex = 0; // 已按序刷入 rawText 的块数
  int _completedChunkCount = 0; // 已完成的块数（含乱序完成）

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
    _resetState();
    await _deleteProgress();
    await _runAll();
  }

  Future<void> resume() async {
    final data = await _loadProgress();
    if (data == null) return;
    _resetState();
    _applyProgress(data);
    await _runAll();
  }

  Future<void> _runAll() async {
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

      // ── 步骤 1：定调 — 书名 + 核心概念（JSON） ──────────
      if (_step1Json == null) {
        currentStep = 0;
        _liveText = '正在生成书名和核心概念...';
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
          maxTokens: 512,
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
        if (_cancelled || error != null) {
          await _persistProgress(phase: 1);
          loading = false;
          notifyListeners();
          return;
        }
        _step1Json = r;
        _step1Text = '书名：《${r!.title}》\n\n${r.concept}';
        _stepPreview = _step1Text!;
        _liveText = '';
        _bubbles.add(OutlineStepBubble(label: '书名与核心概念', content: _step1Text!));
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
      }

      if (_cancelled || error != null) return;

      // ── 步骤 2：骨架 — 粗骨架规划 + 分批精写 + 伏笔账本 ──
      final ok2 = await _runStep2();
      if (!ok2 || _cancelled || error != null) return;

      // ── 准备步骤 3：构建展开块（按每 5 个大事件拆分） ────
      _buildChunks();
      if (_cancelled || error != null) return;

      // ── 步骤 3a/b/c...：限流并行展开，按序合并 ──────────
      await _runChunksParallel(systemPrompt: systemPrompt);

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
    var currentMaxTokens = maxTokens;
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
            'max_tokens': currentMaxTokens,
            'stream': true,
            'response_format': {'type': 'json_object'},
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
          // 输出被 max_tokens 截断导致 JSON 不完整：自动翻倍上限重试
          if (finishReason == 'length' && currentMaxTokens < _maxJsonTokens) {
            currentMaxTokens = (currentMaxTokens * 2) > _maxJsonTokens
                ? _maxJsonTokens
                : currentMaxTokens * 2;
          }
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
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
        error = '请求失败：${e.message}';
        return null;
      } on _StepParseException catch (e) {
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }
        if (attempt < _maxRetries) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
        error = e.message;
        return null;
      } catch (e) {
        if (_cancelled) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          return null;
        }
        if (attempt < _maxRetries) {
          _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
          attempt++;
          await _retryWait(attempt);
          continue;
        }
        _preserveFailedOutput(accumulated, reasoningAccum, attempt: attempt);
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
  /// 多次重试的每次思考都会被保留，不再被清除。
  void _preserveFailedOutput(
    String content,
    String reasoning, {
    required int attempt,
  }) {
    if (content.trim().isEmpty && reasoning.trim().isEmpty) return;
    _bubbles.add(
      OutlineStepBubble(
        label: '${_currentStepLabel()} · 第${attempt + 1}次',
        content: _mergeStructuredLiveText(content, reasoning),
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

  /// 执行步骤 2 全部子步骤：粗骨架 → 分批精写 → 批次间抽取伏笔账本。
  ///
  /// 支持断点续跑：粗骨架已存在则跳过；已完成的批次（[_refinedBatchCount]）跳过，
  /// 从未完成批次继续。返回 false 表示取消或出错，调用方应终止流程。
  Future<bool> _runStep2() async {
    // ── 2a：粗骨架规划（全部大事件仅标题+定位，锁定全局轨迹） ──
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
        maxTokens: _estimateCoarseTokens(),
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
      _bubbles.add(
        OutlineStepBubble(label: '三幕粗骨架', content: _renderSkeleton()),
      );
      await _persistProgress(phase: 2);
      notifyListeners();
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
    for (int b = _refinedBatchCount; b < totalBatches; b++) {
      if (_cancelled || error != null) break;
      final batch = _step2Batches[b];

      // 精写本批大事件（粒度由「大事件粒度定义」约束，保证不退化）
      currentStep = subStepIndex++;
      _liveText = '正在精写第 ${b + 1}/$totalBatches 批大事件...';
      notifyListeners();
      final t0 = DateTime.now();
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
        ),
        maxTokens: _estimateBatchTokens(batch.coarseEvents.length),
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
          maxTokens: 2048,
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
        ),
        maxTokens: _estimateStep3Tokens(),
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
        // 续写时仅携带缓冲尾部 + 明确续写起点，避免全量重发导致上下文膨胀
        messages.addAll([
          {'role': 'assistant', 'content': _continuationTail(chunk.buffer)},
          {
            'role': 'user',
            'content':
                '……（省略号之前为已生成内容的结尾片段，其余已生成内容已省略，'
                '请勿重复任何已生成的内容）请从这里继续往后写，'
                '保持输出格式与结尾片段一致，不要添加解释性文字。',
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

  /// 续写提示词只携带缓冲尾部：省略标记 + 最近 [_continuationTailChars] 个字符，
  /// 并明确告知模型省略号之前的内容已生成、请勿重复
  String _continuationTail(String buffer) {
    if (buffer.isEmpty) return '（尚无内容）';
    if (buffer.length <= _continuationTailChars) return buffer;
    final omitted = buffer.length - _continuationTailChars;
    return '……[此处省略已生成的 $omitted 个字符，请勿重复省略号之前的内容]……\n'
        '${buffer.substring(buffer.length - _continuationTailChars)}';
  }

  /// 结构化步骤（步骤1/2）的实时展示：思考过程 + 生成内容
  ///
  /// [reasoning] 为推理模型输出的 reasoning_content；无思考过程时仅展示生成内容。
  String _mergeStructuredLiveText(String content, String reasoning) {
    if (reasoning.trim().isEmpty) return content;
    return '【思考过程】\n$reasoning\n\n【生成内容】\n$content';
  }

  /// 按块顺序合并尚未刷入 rawText 的各块缓冲（含乱序完成但未刷入的块）
  String _mergeChunkLiveText() {
    if (_flushIndex >= _chunks.length) return '';
    final parts = <String>[];
    for (int i = _flushIndex; i < _chunks.length; i++) {
      final c = _chunks[i];
      if (c.buffer.isEmpty) continue;
      parts.add(c.isActStart ? '${c.header}\n${c.buffer}' : c.buffer);
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

  // ─── 分步参数估算 ────────────────────────────────────────────

  /// 粗骨架 max_tokens：标题 + 一句话定位
  int _estimateCoarseTokens() {
    final raw = majorEventCount * 40 * 2;
    return _clampTok(raw, 1024, 4096);
  }

  /// 单批精写 max_tokens：按本批大事件字数估算
  int _estimateBatchTokens(int batchLen) {
    final perEvent = _outlineSetting.majorEventMaxWords + 20;
    return _clampTok(perEvent * batchLen * 2, 2048, 6000);
  }

  int _estimateStep3Tokens() {
    final perEvent =
        _outlineSetting.majorEventMaxWords +
        minorEventCount * _outlineSetting.minorEventMaxWords;
    return _clampTok(perEvent * _maxEventsPerChunk * 2, 4096, 8000);
  }

  int _clampTok(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  // ─── 内部工具 ────────────────────────────────────────────────

  OutlineRecord _buildRecord() {
    return OutlineRecord(
      title: title,
      genre: genreController.text,
      theme: themeController.text,
      protagonist: protagonistController.text,
      worldview: worldViewController.text,
      content: rawText,
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
    _stepPreview = '';
    _step2Batches = [];
    _step2BatchCount = 0;
    _ledgerBatchCount = 0;
    _step2SubStepCount = 1;
    _refinedBatchCount = 0;
    _ledgerForeshadows.clear();
    _ledgerCharacters.clear();
    _ledgerUnresolved.clear();
    _chunks = [];
    _flushIndex = 0;
    _completedChunkCount = 0;
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
    try {
      final file = await _ensureProgressFile();
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  Future<void> _persistProgress({int? phase}) async {
    try {
      final file = await _ensureProgressFile();
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
        'refinedBatchCount': _refinedBatchCount,
        'ledger': {
          'foreshadows': _ledgerForeshadows,
          'characters': _ledgerCharacters,
          'unresolved': _ledgerUnresolved,
        },
        'completedChunks': _completedChunkCount,
        'rawText': rawText,
      };
      await file.writeAsString(jsonEncode(data));
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
  }
}

/// 结构化步骤解析失败异常
class _StepParseException implements Exception {
  final String message;
  _StepParseException(this.message);

  @override
  String toString() => message;
}

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
  String buffer = '';
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
class OutlineStepBubble {
  final String label;
  final String content;
  final bool isError;

  const OutlineStepBubble({
    required this.label,
    required this.content,
    this.isError = false,
  });
}
