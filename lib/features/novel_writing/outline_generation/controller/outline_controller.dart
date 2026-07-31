import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/outline_service.dart';
import '../../shared/models/outline_setting.dart';
import '../../shared/models/outline_record.dart';

/// 大纲生成控制器，管理业务逻辑与状态
///
/// 采用多步生成策略（Chain-of-Thought）：
/// 1. 定调：生成书名 + 核心概念
/// 2. 骨架：生成三幕结构 + 大事件列表
/// 3. 展开：逐幕展开大/小事件细节，每幕每超过 5 个大事件自动拆分调用
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
  String rawText = '';          // 已完成步骤的最终文本
  String title = '';
  CancelToken? _cancelToken;

  // ─── 多步生成状态 ────────────────────────────────────────────
  static const int _maxEventsPerChunk = 5;

  int currentStep = 0;
  int totalSteps = 0;
  List<String> stepLabels = [];

  String _liveText = '';        // 当前步骤正在流式输出的文本
  bool _cancelled = false;
  String? _step1Result;         // 步骤 1 完整输出（书名+核心概念）
  String? _step2Result;         // 步骤 2 完整输出（三幕骨架）
  late String _apiKey;
  late OutlineSetting _outlineSetting;
  late Map<String, dynamic> _apiParams;

  /// 当前步骤的显示标签
  String get stepLabel =>
      currentStep < stepLabels.length ? stepLabels[currentStep] : '';

  /// 当前展示文本 = 已完成文本 + 正在流式的文本
  String get displayText {
    if (rawText.isNotEmpty && _liveText.isNotEmpty) {
      return '$rawText\n\n$_liveText';
    }
    if (_liveText.isNotEmpty) return _liveText;
    return rawText;
  }

  OutlineController({OutlineService? outlineService})
      : _outlineService = outlineService ?? OutlineService();

  // ─── 取消 ────────────────────────────────────────────────────
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _cancelled = true;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    genreController.dispose();
    themeController.dispose();
    protagonistController.dispose();
    worldViewController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 50),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── 主入口：多步生成 ──────────────────────────────────────
  Future<void> generate() async {
    if (themeController.text.trim().isEmpty ||
        protagonistController.text.trim().isEmpty) {
      error = '请填写主题和主角设定';
      notifyListeners();
      return;
    }

    _resetState();

    try {
      // ── 加载设置 ──────────────────────────────────────────
      final settings = await _outlineService.loadSettings();
      if (settings.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }
      _apiKey = settings.apiKey;
      _outlineSetting = settings.outlineSetting;
      _apiParams = {
        'model': settings.outlineSetting.model,
        'temperature': settings.outlineSetting.temperature,
        'max_tokens': settings.outlineSetting.maxTokens,
        'stream': true,
      };

      final systemPrompt = OutlinePromptTemplate.buildSystemPrompt(
        settings.outlineSetting.systemPrompt,
      );

      // ── 步骤 1：定调 — 书名 + 核心概念 ──────────────────
      currentStep = 0;
      _liveText = '';
      notifyListeners();

      await _runStep(
        systemPrompt: systemPrompt,
        userPrompt: OutlinePromptTemplate.buildStep1Prompt(
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
        ),
        onStepDone: (text) {
          _step1Result = text;
          _extractTitle(text);
        },
      );
      if (_cancelled || error != null) return;

      // ── 步骤 2：骨架 — 三幕结构 + 大事件列表 ──────────────
      currentStep = 1;
      _liveText = '';
      notifyListeners();

      await _runStep(
        systemPrompt: systemPrompt,
        userPrompt: OutlinePromptTemplate.buildStep2Prompt(
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
          majorEventCount: majorEventCount,
          minorEventCount: minorEventCount,
          titleAndConcept: _step1Result!,
          outlineSetting: _outlineSetting,
        ),
        onStepDone: (text) => _step2Result = text,
      );
      if (_cancelled || error != null) return;

      // ── 准备步骤 3：将每幕的大事件按每 5 个拆分为块 ─────
      final acts = _extractActsFromSkeleton(_step2Result!);
      const actHeaders = [
        '══ 第一幕：开端 ══',
        '══ 第二幕：发展 ══',
        '══ 第三幕：高潮&结局 ══',
      ];
      const actNames = ['第一幕', '第二幕', '第三幕'];

      // 构建所有展开块的元信息
      final chunks = <_ExpandChunk>[];
      for (int i = 0; i < acts.length; i++) {
        final events = _splitMajorEvents(acts[i]);
        final groups = _groupList(events, _maxEventsPerChunk);
        for (int j = 0; j < groups.length; j++) {
          chunks.add(_ExpandChunk(
            actIndex: i,
            header: actHeaders[i],
            actName: actNames[i],
            content: groups[j].join('\n\n'),
            chunkIndex: j,
            totalChunks: groups.length,
          ));
        }
      }

      // 根据实际块数设定动态步骤数和标签
      totalSteps = 2 + chunks.length;
      stepLabels = [
        '生成书名和核心概念',
        '生成三幕结构',
        ...chunks.map((c) => c.totalChunks > 1
            ? '展开${c.actName}细节 (${c.chunkIndex + 1}/${c.totalChunks})'
            : '展开${c.actName}细节'),
      ];

      // ── 步骤 3a/b/c...：逐块展开 ──────────────────────────
      for (int i = 0; i < chunks.length; i++) {
        if (_cancelled || error != null) break;

        currentStep = 2 + i;
        _liveText = '';
        notifyListeners();

        final chunk = chunks[i];
        await _runStep(
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
            outlineSetting: _outlineSetting,
          ),
          onStepDone: (text) {
            if (rawText.isEmpty) {
              rawText = '$_step1Result\n\n${chunk.header}\n$text';
            } else {
              rawText = '$rawText\n\n$text';
            }
          },
        );
      }

      // ── 保存到历史记录 ──────────────────────────────────────
      if (rawText.isNotEmpty && !_cancelled) {
        final record = OutlineRecord(
          title: title,
          genre: genreController.text,
          theme: themeController.text,
          protagonist: protagonistController.text,
          worldview: worldViewController.text,
          content: rawText,
        );
        _outlineService.saveRecord(record);
      }

      loading = false;
      notifyListeners();
    } catch (e) {
      if (!_cancelled) {
        error = e.toString().replaceFirst('Exception: ', '');
      }
      loading = false;
      notifyListeners();
    }
  }

  // ─── 内部方法 ────────────────────────────────────────────────

  /// 执行单步流式请求
  Future<void> _runStep({
    required String systemPrompt,
    required String userPrompt,
    required void Function(String text) onStepDone,
  }) async {
    _cancelToken = CancelToken();
    String accumulated = '';

    await _outlineService.streamGenerate(
      apiKey: _apiKey,
      apiParams: _apiParams,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      cancelToken: _cancelToken,
      onChunk: (chunk) {
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) return;

        final delta = choices[0]['delta'] as Map<String, dynamic>?;
        if (delta == null) return;

        final content = delta['content'] as String?;
        if (content == null || content.isEmpty) return;

        accumulated += content;
        _liveText = accumulated;
        notifyListeners();
        scrollToBottom();
      },
      onDone: () {
        _cancelToken = null;
        if (_cancelled) return;
        final trimmed = accumulated.trim();
        if (trimmed.isNotEmpty) {
          onStepDone(trimmed);
        }
      },
      onError: (errorMsg) {
        _cancelToken = null;
        if (_cancelled) return;
        error = errorMsg;
        notifyListeners();
      },
    );
  }

  /// 从步骤 1 的输出中提取书名
  void _extractTitle(String text) {
    final firstLine = text.split('\n').firstWhere(
      (l) => l.contains('书名：'),
      orElse: () => '',
    );
    if (firstLine.isNotEmpty) {
      title = firstLine
          .replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '')
          .trim();
    }
    if (title.isEmpty) {
      final match = RegExp(r'《([^》]+)》').firstMatch(text);
      if (match != null) title = match.group(1) ?? '';
    }
  }

  /// 从步骤 2 的骨架中解析出每一幕的原始内容（不含幕标题行）
  List<String> _extractActsFromSkeleton(String skeleton) {
    final actRegex = RegExp(
      r'══ 第[一二三]幕：([^═]+) ══\n([\s\S]*?)(?=\n══ 第|$)',
    );
    final matches = actRegex.allMatches(skeleton);
    return matches
        .map((m) => m.group(2)?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 将一幕的文本内容拆分为单个大事件条目列表
  ///
  /// 步骤 2 的输出格式：
  ///   大事件1：标题
  ///   大事件概述（xxx）
  ///
  ///   大事件2：标题
  ///   ...
  List<String> _splitMajorEvents(String actContent) {
    final lines = actContent.split('\n');
    final events = <String>[];
    String current = '';

    for (final line in lines) {
      if (line.trim().startsWith('大事件')) {
        if (current.isNotEmpty) {
          events.add(current.trim());
        }
        current = line;
      } else {
        current = '$current\n$line';
      }
    }
    if (current.isNotEmpty) {
      events.add(current.trim());
    }
    return events;
  }

  /// 将列表按每 [chunkSize] 个分组
  List<List<T>> _groupList<T>(List<T> list, int chunkSize) {
    final groups = <List<T>>[];
    for (int i = 0; i < list.length; i += chunkSize) {
      groups.add(list.sublist(i, i + chunkSize > list.length ? list.length : i + chunkSize));
    }
    return groups;
  }

  /// 重置所有生成状态
  void _resetState() {
    loading = true;
    error = null;
    rawText = '';
    title = '';
    _liveText = '';
    _cancelled = false;
    currentStep = 0;
    totalSteps = 0;
    stepLabels = [];
    _step1Result = null;
    _step2Result = null;
    notifyListeners();
  }
}

/// 展开块元信息
class _ExpandChunk {
  final int actIndex;
  final String header;
  final String actName;
  final String content;
  final int chunkIndex;
  final int totalChunks;

  const _ExpandChunk({
    required this.actIndex,
    required this.header,
    required this.actName,
    required this.content,
    required this.chunkIndex,
    required this.totalChunks,
  });
}
