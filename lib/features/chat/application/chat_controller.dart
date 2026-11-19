// lib/controllers/chat_controller.dart
// 对话控制器 — 负责消息发送、流式接收、上下文裁剪、会话持久化、消息入库
// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/chat_message.dart';
import '../domain/chat_session.dart';
import '../../../core/config/user_setting.dart';
import '../../../core/config/deepseek_models.dart';
import '../../../core/network/api_service.dart';
import '../../../core/config/user_setting_service.dart';
import '../data/chat_session_service.dart';
import '../data/chat_message_service.dart';
import '../../../core/network/baidu_search_service.dart';
import '../../../core/network/deepseek_search_service.dart';
import 'chat_prompt.dart';
import 'chat_context_budget.dart';
import 'package:dio/dio.dart';

class ChatController extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final BaiduSearchService _baiduSearchService = BaiduSearchService();
  final DeepSeekSearchService _deepSeekSearchService = DeepSeekSearchService();

  /// 注入搜索结果时，单条结果的截断上限（字符）。
  ///
  /// 为什么要截：DeepSeek 搜索开 `need_content` 后返回的是**整页正文**，
  /// 单条上万字很常见；5 条不截就是几万字符灌进上下文，既费 token 也容易
  /// 把真正相关的段落淹没。摘要字段同理限长，只是上限更小。
  static const int _maxContentCharsPerResult = 3000;
  static const int _maxSummaryCharsPerResult = 1200;

  /// 一次回答里最多执行几路搜索查询（模型一次可能并发多路，实测常见 2 路）。
  /// 每路都是一次计费请求，这里封顶防失控。
  static const int _maxQueriesPerTurn = 3;

  /// 合并后最多注入多少条结果（多路 × 每路条数的总上限）
  static const int _maxMergedResults = 20;

  /// 搜索结果注入模型的总字符预算；超出的结果不再注入（只在末尾报个数）。
  /// 20 条 × 3000 字的上限是 6 万字符，对上下文和钱包都太重了。
  static const int _searchContextBudget = 24000;

  // ── 内存状态 ──
  List<ChatMessage> _messages = []; // 当前会话完整历史消息
  UserSetting? _settingCache; // 全局配置内存缓存
  ChatSession? _currentSession = ChatSession(
    title: '新对话',
    createTime: DateTime.now().toIso8601String(),
  ); // 当前会话元数据（默认创建一个，避免空指针）
  bool _isLoading = false; // 是否正在等待回复
  String _streamingText = '';
  String _streamingThinking = '';
  List<Map<String, dynamic>>? _streamingSearchResults; // 流式搜索结果
  CancelToken? _cancelToken; // 用于中断当前输出

  // ── Tool Calling 跟踪（联网搜索 AI 决策） ──
  final Map<int, Map<String, dynamic>> _pendingToolCalls =
      {}; // 累积 tool_calls 分片
  String? _lastFinishReason; // 上一条流式块的 finish_reason
  String _phase1Text = ''; // Phase 1 保留文本（搜索前 AI 的预回答）
  String _phase1Thinking = ''; // Phase 1 保留思考内容
  // ── 两阶段搜索的请求快照 ──
  // 第二阶段直接复用第一阶段已发送的消息与 tools（只在末尾追加搜索结果），
  // 保证前缀逐字节一致，DeepSeek 才能命中第一阶段写好的缓存。
  List<Map<String, dynamic>>? _phaseOneMessages;
  List<Map<String, dynamic>>? _phaseOneTools;
  String _summary = ''; // 当前会话的对话历史检查点（持久化到 DB）
  int _summaryCount = 0; // 已被检查点覆盖的消息条数（从会话开头算）

  // ── 上下文用量与缓存（来自 API usage，用于面板展示） ──
  int _contextTokens = 0; // 上次请求的真实 prompt_tokens
  int _cachedTokens = 0; // 上次请求命中的缓存 token 数
  int _completionTokens = 0; // 上次请求的 completion_tokens
  int _contextWindow = 0; // 上次请求使用的窗口
  int _totalPromptTokens = 0; // 本会话累计输入 token（Σ 所有请求）
  int _totalCachedTokens = 0; // 本会话累计缓存命中 token
  int _estimatedTokens = 0; // 发送前的估算值（还没拿到 usage 时展示）
  bool _isCompacting = false; // 正在压缩历史
  int _lastCompactedCount = 0; // 最近一次压缩掉的消息条数

  // ── getter ──
  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  String get streamingText => _streamingText;
  String get streamingThinking => _streamingThinking;
  List<Map<String, dynamic>>? get streamingSearchResults =>
      _streamingSearchResults;
  ChatSession? get currentSession => _currentSession;
  bool get isStreamingEmpty =>
      !_isLoading && _streamingText.isEmpty && _streamingThinking.isEmpty;
  String get phase1Text => _phase1Text;
  String get phase1Thinking => _phase1Thinking;

  /// ── 上下文占用 / 缓存命中（面板展示用） ──
  int get contextTokens => _contextTokens;
  int get cachedTokens => _cachedTokens;
  int get completionTokens => _completionTokens;
  int get contextWindow => _contextWindow;
  int get totalPromptTokens => _totalPromptTokens;
  int get totalCachedTokens => _totalCachedTokens;
  int get estimatedTokens => _estimatedTokens;
  bool get isCompacting => _isCompacting;
  int get lastCompactedCount => _lastCompactedCount;

  /// 优先用真实 usage，拿不到时退回估算值
  int get displayContextTokens =>
      _contextTokens > 0 ? _contextTokens : _estimatedTokens;

  /// 上下文占用百分比（0-100）
  int get contextPercent {
    final window = _contextWindow > 0
        ? _contextWindow
        : ChatContextBudget.defaultWindow;
    final tokens = displayContextTokens;
    if (tokens <= 0) return 0;
    final value = (tokens * 100 / window).round();
    return value > 100 ? 100 : value;
  }

  /// 整体缓存命中率（本会话 Σ命中 / Σ输入）；还没有任何用量时返回 null。
  ///
  /// 注意：不是最近一次请求的命中率——切换会话会显示各会话自己的累计值，
  /// 旧版本会话没有累计数据时显示「缓存 —」。
  int? get cachePercent {
    if (_totalPromptTokens <= 0) return null;
    final value = (_totalCachedTokens * 100 / _totalPromptTokens).round();
    return value > 100 ? 100 : value;
  }

  /// 最近一次请求的命中率（用于「缓存」详情弹窗里的对比）
  int? get lastCachePercent {
    if (_contextTokens <= 0) return null;
    final value = (_cachedTokens * 100 / _contextTokens).round();
    return value > 100 ? 100 : value;
  }

  /// 配置缓存为空时重新加载
  bool get _hasSettingCache => _settingCache != null;

  // ============================================================
  //  ── 联网搜索来源裁决 ──
  // ============================================================

  /// 归一化搜索来源：兼容历史数据（旧库只有 web_search 布尔量，无 search_engine）。
  /// 只认三个已知值；认不出来时按历史布尔量判断——这正是老代码注释里写的
  /// "兼容历史数据"，但原先只是回落成百度，等于替没开搜索的用户把搜索打开了。
  static String _normalizeEngine(UserSetting s) {
    const valid = <String>[
      UserSetting.searchEngineBaidu,
      UserSetting.searchEngineDeepseek,
      UserSetting.searchEngineOff,
    ];
    if (valid.contains(s.searchEngine)) return s.searchEngine;
    return s.webSearch
        ? UserSetting.searchEngineBaidu
        : UserSetting.searchEngineOff;
  }

  /// 实际使用的搜索来源（对外可见，便于 UI / 测试断言）。
  ///
  /// 两个来源都是"App 自己发搜索请求、再把结果喂给模型"的同一条链路，区别只在
  /// 调哪个接口、用哪个 Key：
  ///   * [UserSetting.searchEngineBaidu]    百度千帆 `/v2/ai_search/web_search`；
  ///   * [UserSetting.searchEngineDeepseek] DeepSeek 官方 `/v1/tools/search`
  ///     （2026-10 上线，与对话接口共用同一个 API Key，无需第三方 Key）。
  ///
  /// 历史：`deepseek` 曾经在这里被**强制降级成百度**——因为当时官方 API 只能靠
  /// /chat/completions 的 tools 参数让模型自己搜，而实测那条路走不通（422 /
  /// 静默忽略 / 不执行检索）。现在官方把搜索做成了独立工具接口，由 App 自己调，
  /// 不再依赖模型的服务端工具能力，所以降级逻辑删除。
  static String effectiveSearchEngine(UserSetting s) => _normalizeEngine(s);

  /// 当前搜索来源缺少鉴权时返回给用户的提示，可用时返回 null。
  static String? searchKeyWarning(UserSetting s) {
    switch (effectiveSearchEngine(s)) {
      case UserSetting.searchEngineBaidu:
        return s.baiduApiKey.trim().isEmpty
            ? '联网搜索已开启（百度千帆搜索），但未填写百度 API Key，请在设置页面填写后再发送。'
            : null;
      case UserSetting.searchEngineDeepseek:
        return s.apiKey.trim().isEmpty
            ? '联网搜索已开启（DeepSeek 官方搜索），但未填写 DeepSeek API Key。'
            : null;
      default:
        return null;
    }
  }

  /// 组装注入给模型的 web_search 工具定义。
  ///
  /// 两个来源共用同一个工具名（两段式流程、历史消息里的工具名都不用改），
  /// 只有描述随来源变化：DeepSeek 官方搜索支持 site: / lang: / after: 等查询
  /// 语法、query 上限 128 字符；百度链路的建议是 72 字符。
  ///
  /// 描述里带「当前日期」是实测结论：不带日期时，模型问"最近有什么新模型"
  /// 会自己臆断年份（实测写成 `DeepSeek 新模型发布 2025`，而当时已是 2026-10），
  /// 检索自然落到旧闻上；补上日期后同样的问题变成 `… 2026`，并会在英文那一路
  /// 自动用上 `after:2026-01-01`。
  @visibleForTesting
  static Map<String, dynamic> buildWebSearchTool(
    UserSetting setting,
    String engine,
  ) {
    final isDeepSeek = engine == UserSetting.searchEngineDeepseek;
    final maxTopK = isDeepSeek
        ? setting.searchCount.clamp(
            DeepSeekSearchService.minCount,
            DeepSeekSearchService.maxCount,
          )
        : setting.searchCount;
    // 日期不能写进工具描述：工具定义属于提示词前缀，日期每天变化会让整段
    // 工具块和历史缓存全部失配。当前日期统一由本轮用户消息末尾的运行环境注记提供。
    final baseDescription =
        '搜索互联网获取实时信息。当用户询问新闻、实时数据或需要最新信息时使用。'
        '当前日期见本轮运行环境注记，检索最新信息时请使用正确的年份。';
    return {
      'type': 'function',
      'function': {
        'name': 'web_search',
        'description': isDeepSeek
            ? '$baseDescription'
                  'query 支持搜索语法：site:example.com 限定站点、-site: 排除站点、'
                  '"精确短语"、lang:zh,en 限定语言、after:2025-01-01 / before:2025-06-01 限定时间。'
                  '需要覆盖更全时可以一次发起多路查询（如中文一路、英文一路）。'
            : baseDescription,
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': isDeepSeek
                  ? '搜索关键词，使用简洁明确的关键词组合，长度不超过128个字符。'
                  : '搜索关键词，使用简洁明确的关键词组合，长度不超过72个字符。',
            },
            'top_k': {
              'type': 'integer',
              'description': '返回搜索结果数量，不传则使用默认值。请根据用户需求合理调整，范围1-$maxTopK。',
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  // ============================================================
  //  ── 中断输出 ──
  // ============================================================

  /// 中断当前输出：取消网络请求，保留已收到的部分内容
  void cancelRequest() {
    if (!_isLoading || _cancelToken == null) return;
    _cancelToken!.cancel();
    _cancelToken = null;
  }

  // ============================================================
  //  ── 核心流程：发送消息 ──
  // ============================================================

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isLoading) return;

    // ① 添加用户消息到列表
    final userMsg = ChatMessage(
      role: MessageRole.user,
      content: trimmed,
      timestamp: DateTime.now().toIso8601String(),
    );
    _messages.add(userMsg);
    _streamingText = '';
    _streamingThinking = '';
    _phase1Text = '';
    _phase1Thinking = '';
    _streamingSearchResults = null;
    _phaseOneMessages = null; // 新一轮：清掉上一轮的请求快照
    _phaseOneTools = null;
    _isLoading = true;
    notifyListeners();

    // ①b 消息入库（当前会话已持久化时才单独入库，新会话等 _persistSession 批量写）
    if (_currentSession?.id != null) {
      final savedMsg = await ChatMessageService.insertMessage(
        userMsg,
        _currentSession!.id!,
      );
      _messages[_messages.length - 1] = savedMsg;
    }

    // ② 确保配置缓存有效（首次发送查库，非首次复用）
    if (!_hasSettingCache) {
      try {
        _settingCache = await UserSettingService.getSettings();
      } catch (_) {
        _settingCache = const UserSetting();
      }
    }

    final setting = _settingCache!;

    // ③ 校验 apiKey
    if (setting.apiKey.isEmpty) {
      final errMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '请先在设置页面填写 API Key 后再发送消息。',
        timestamp: DateTime.now().toIso8601String(),
      );
      _messages.add(errMsg);
      if (_currentSession?.id != null) {
        final saved = await ChatMessageService.insertMessage(
          errMsg,
          _currentSession!.id!,
        );
        _messages[_messages.length - 1] = saved;
      }
      _isLoading = false;
      notifyListeners();
      await _persistSession();
      return;
    }

    // ④ 上下文接近窗口上限时先压缩（DSH 式检查点），再组装消息
    await _maybeCompact(setting);
    _estimatedTokens = _estimateContext(setting);
    final apiMessages = _buildApiMessages();

    // ⑤ 组装 API 参数
    final apiParams = setting.toApiParams();

    // ⑤b 注入系统提示词：稳定基础提示 + 会话自定义提示（跨请求不变），
    // 模型输出的 Markdown 交给展示层清洗（presentation/markdown_cleaner.dart）。
    final sessionPrompt = _currentSession?.systemPrompt ?? '';
    final searchEngine = effectiveSearchEngine(setting);
    final searchEnabled = searchEngine != UserSetting.searchEngineOff;
    final systemContent = buildChatSystemPrompt(sessionPrompt: sessionPrompt);
    if (systemContent.isNotEmpty) {
      apiMessages.insert(0, {'role': 'system', 'content': systemContent});
    }

    // ⑤c 工具注入（AI 可决策的工具列表）
    final tools = <Map<String, dynamic>>[];

    // 联网搜索工具
    if (searchEnabled) {
      final warning = searchKeyWarning(setting);
      if (warning != null) {
        final errMsg = ChatMessage(
          role: MessageRole.assistant,
          content: warning,
          timestamp: DateTime.now().toIso8601String(),
        );
        _messages.add(errMsg);
        if (_currentSession?.id != null) {
          final saved = await ChatMessageService.insertMessage(
            errMsg,
            _currentSession!.id!,
          );
          _messages[_messages.length - 1] = saved;
        }
        _isLoading = false;
        notifyListeners();
        await _persistSession();
        return;
      }
      tools.add(buildWebSearchTool(setting, searchEngine));
    }

    if (tools.isNotEmpty) {
      apiParams['tools'] = tools;
      // 官方 tool_choice：auto / none / required。
      // 思考模式下官方不支持 required，这里自动降级为 auto，避免 400。
      final thinkingActive =
          setting.thinking && setting.reasoningEffort != 'none';
      var choice = setting.toolChoice;
      if (thinkingActive && choice == 'required') choice = 'auto';
      if (choice != 'auto') {
        apiParams['tool_choice'] = choice;
      }
    }

    // 缓存关键：快照第一阶段最终发送的消息与 tools 定义，第二阶段原样复用。
    // 不能到第二阶段再从数据库重建历史——那样会丢掉末尾的时间注记，前缀失配。
    _phaseOneMessages = apiMessages
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    _phaseOneTools = tools.map((t) => Map<String, dynamic>.from(t)).toList();

    // ⑥ 发起流式请求
    _pendingToolCalls.clear();
    _lastFinishReason = null;
    _cancelToken = CancelToken();
    await _apiService.streamChat(
      apiKey: setting.apiKey,
      apiParams: apiParams,
      messages: apiMessages,
      onChunk: (chunk) => _handleStreamChunk(chunk, setting),
      onDone: () => _handleStreamDone(),
      onError: (error) => _handleStreamError(error),
      cancelToken: _cancelToken,
    );
  }

  // ============================================================
  //  ── 上下文组装与压缩（DSH 式：按窗口压力触发，不按轮数） ──
  // ============================================================

  ChatContextBudget _budgetFor(UserSetting setting) {
    final window = contextWindowForModel(DeepSeekModels.toApiId(setting.model));
    return ChatContextBudget.of(
      maxTokens: setting.maxTokens,
      window: window > 0 ? window : null,
    );
  }

  /// 检查点之后保留的原始消息（压缩时只压缩这段之前的部分）。
  List<ChatMessage> _historyAfterSummary() {
    final start = _summaryCount.clamp(0, _messages.length);
    return _messages.sublist(start);
  }

  /// 估算这次请求的上下文大小（system + 检查点 + 历史）。
  int _estimateContext(UserSetting setting, {String pendingUser = ''}) {
    final systemPrompt = buildChatSystemPrompt(
      sessionPrompt: _currentSession?.systemPrompt ?? '',
    );
    var total = estimateMessageTokens(systemPrompt);
    if (_summary.isNotEmpty) {
      total += estimateMessageTokens(_summary);
    }
    for (final message in _historyAfterSummary()) {
      total += estimateMessageTokens(_apiContentForMessage(message));
    }
    if (pendingUser.isNotEmpty) {
      total += estimateMessageTokens(pendingUser);
    }
    return total;
  }

  /// 组装发送给 API 的消息列表：主 system + 检查点(system) + 检查点之后的原文。
  ///
  /// 顺序固定为「不变的在前」：基础 system + 会话自定义提示 → 检查点 → 历史；
  /// 每条用户消息末尾都按自己的发送时间追加运行环境注记，且重建历史时逐字节一致，
  /// 所以上一轮请求的 prompt 是下一轮的前缀，时间不会破坏缓存。
  List<Map<String, dynamic>> _buildApiMessages() {
    final apiMessages = <Map<String, dynamic>>[];
    if (_summary.isNotEmpty) {
      apiMessages.add({
        'role': 'system',
        'content':
            '【更早对话的检查点（系统自动生成，可直接采信）】\n'
            '这段检查点替换了更早的历史消息，把它当作已确认的背景，不要向用户复述。\n'
            '<compacted-summary>\n$_summary\n</compacted-summary>',
      });
    }
    for (final message in _historyAfterSummary()) {
      apiMessages.add({
        'role': message.isUser ? 'user' : 'assistant',
        'content': _apiContentForMessage(message),
      });
    }
    return apiMessages;
  }

  /// 实际发给模型的消息内容：用户消息按发送时间追加运行环境注记。
  ///
  /// 时间来自 message.timestamp 而不是 now：第一次发送和后续重建历史得到完全
  /// 相同的字符串，上一轮 prompt 才能成为下一轮的前缀。
  String _apiContentForMessage(ChatMessage message) {
    if (!message.isUser) return message.content;
    final sentAt = DateTime.tryParse(message.timestamp);
    if (sentAt == null) return message.content;
    return runtimeHintedContent(message.content, sentAt);
  }

  /// 接近窗口上限时，把最旧的一段历史压缩成检查点。
  ///
  /// 与网页端 / DSH 一致：阈值 `min(W×0.8, W−输出预留−65536)`，保留最近
  /// `(W−输出预留)×16%` 的原文。只压缩检查点之后、保留段之前的消息。
  Future<void> _maybeCompact(UserSetting setting) async {
    if (_isCompacting || _messages.isEmpty) return;
    final budget = _budgetFor(setting);
    final estimated = _estimateContext(setting);
    final pressure = _contextTokens > estimated ? _contextTokens : estimated;
    _contextWindow = budget.window;
    if (!budget.needsCompaction(pressure)) {
      return;
    }

    final history = _historyAfterSummary();
    final tokens = history
        .map((m) => estimateMessageTokens(_apiContentForMessage(m)))
        .toList();
    final keepFrom = ChatContextBudget.keepFrom(tokens, budget.retain);
    if (keepFrom <= 0) return; // 全部都在保留预算内，没有可压缩的

    final toCompact = history.sublist(0, keepFrom);
    if (toCompact.isEmpty) return;

    _isCompacting = true;
    notifyListeners();
    try {
      final summaryMessages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content':
              '你是一个会话压缩引擎。把上面的对话压缩成一份结构化检查点，'
              '让另一个模型在没有原始历史的情况下也能继续工作。'
              '只输出下面的 Markdown 结构，每个小节都要保留；没有内容写「无」。\n\n'
              '## 用户目标与要求\n- [用户最初和变化后的目标]\n'
              '## 已确认的设定与事实\n- [关键结论、人物、偏好]\n'
              '## 已完成与进行中的事\n- [做到哪一步、下一步做什么]\n'
              '## 关键约束\n- [用户明确要求或禁止的事项]\n\n'
              '规则：保留准确的时间、数字与专有名词，不要编造；不要提到「压缩」这件事；'
              '如果对话里已有 <compacted-summary>，把它当作更早的检查点合并进来。',
        },
        {'role': 'user', 'content': _buildCompactInput(toCompact)},
      ];

      final result = await _apiService.chat(
        apiKey: setting.apiKey,
        apiParams: {
          'model': setting.model,
          'temperature': 0.3,
          'max_tokens': 2048,
          'thinking': {'type': 'disabled'},
        },
        messages: summaryMessages,
      );
      final choices = result['choices'] as List?;
      if (choices == null || choices.isEmpty) return;
      final content = choices[0]['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) return;

      _summary = content.trim();
      _summaryCount += toCompact.length;
      _lastCompactedCount = toCompact.length;
      _contextTokens = 0; // 压缩后重新按估算值计算
      _contextWindow = budget.window;
      await _saveSessionMeta();
    } catch (_) {
      // 压缩失败按原样发送，不阻断对话
    } finally {
      _isCompacting = false;
      notifyListeners();
    }
  }

  String _buildCompactInput(List<ChatMessage> messages) {
    final buffer = StringBuffer();
    if (_summary.isNotEmpty) {
      buffer.writeln('【更早的检查点】\n$_summary\n');
    }
    buffer.writeln('【需要并入检查点的对话】');
    for (final message in messages) {
      final role = message.isUser ? '用户' : '助手';
      final content = message.content.length > 4000
          ? '${message.content.substring(0, 4000)}…'
          : message.content;
      buffer.writeln('$role：$content');
    }
    buffer.writeln('\n请输出合并后的完整检查点。');
    return buffer.toString();
  }

  // ============================================================
  //  ── 流式数据分片处理 ──
  // ============================================================

  /// 读取 API 返回的 usage：真实上下文占用与缓存命中率。
  ///
  /// 兼容两种字段形态：官方 `prompt_cache_hit_tokens` 与
  /// OpenAI 风格的 `prompt_tokens_details.cached_tokens`。
  void _captureUsage(Map<String, dynamic> chunk) {
    final usage = chunk['usage'];
    if (usage is! Map) return;
    final prompt = usage['prompt_tokens'];
    final completion = usage['completion_tokens'];
    var cached = usage['prompt_cache_hit_tokens'];
    if (cached == null) {
      final details = usage['prompt_tokens_details'];
      if (details is Map) cached = details['cached_tokens'];
    }
    final promptTokens = prompt is num ? prompt.toInt() : null;
    final cachedTokenCount = cached is num ? cached.toInt() : null;
    // usage 只应在最后一个分片出现一次；网关若重复携带，用「数值有变化」去重，
    // 避免把同一次请求累计两遍。
    final isNewRequest =
        (promptTokens != null && promptTokens != _contextTokens) ||
        (cachedTokenCount != null && cachedTokenCount != _cachedTokens);
    var changed = false;
    if (isNewRequest) {
      if (promptTokens != null) {
        _contextTokens = promptTokens;
        _estimatedTokens = promptTokens;
        _totalPromptTokens += promptTokens;
        changed = true;
      }
      if (cachedTokenCount != null) {
        _cachedTokens = cachedTokenCount;
        _totalCachedTokens += cachedTokenCount;
        changed = true;
      }
    }
    if (completion is num) {
      _completionTokens = completion.toInt();
    }
    if (_contextWindow <= 0) {
      final setting = _settingCache;
      _contextWindow = setting == null
          ? ChatContextBudget.defaultWindow
          : _budgetFor(setting).window;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _handleStreamChunk(Map<String, dynamic> chunk, UserSetting setting) {
    // usage 只在最后一个分片出现（include_usage），先于 choices 读取
    _captureUsage(chunk);
    final choices = chunk['choices'] as List?;
    if (choices == null || choices.isEmpty) return;

    final delta = choices[0]['delta'] as Map<String, dynamic>?;
    if (delta == null) return;

    // 思考内容（reasoning_content）
    final reasoning = delta['reasoning_content'];
    if (reasoning != null && reasoning is String && reasoning.isNotEmpty) {
      _streamingThinking += reasoning;
    }

    // 正文内容
    final content = delta['content'];
    if (content != null && content is String && content.isNotEmpty) {
      _streamingText += content;
    }

    // 联网搜索结果
    final searchResults = delta['search_results'];
    if (searchResults != null &&
        searchResults is List &&
        searchResults.isNotEmpty) {
      _streamingSearchResults ??= [];
      for (final r in searchResults) {
        if (r is Map<String, dynamic>) {
          _streamingSearchResults!.add(r);
        }
      }
    }

    // Tool calling：累积 tool_calls 分片
    final toolCallsDelta = delta['tool_calls'] as List?;
    if (toolCallsDelta != null) {
      for (final tc in toolCallsDelta) {
        if (tc is! Map) continue;
        final index = tc['index'] as int? ?? 0;
        _pendingToolCalls.putIfAbsent(
          index,
          () => <String, dynamic>{
            'id': null,
            'type': null,
            'function': <String, dynamic>{'name': null, 'arguments': ''},
          },
        );
        final existing = _pendingToolCalls[index]!;
        if (tc['id'] != null) existing['id'] = tc['id'];
        if (tc['type'] != null) existing['type'] = tc['type'];
        final fn = tc['function'] as Map?;
        if (fn != null) {
          if (fn['name'] != null) existing['function']['name'] = fn['name'];
          if (fn['arguments'] != null) {
            existing['function']['arguments'] += fn['arguments'].toString();
          }
        }
      }
    }

    // 跟踪 finish_reason
    final finishReason = choices[0]['finish_reason'] as String?;
    if (finishReason != null) _lastFinishReason = finishReason;

    notifyListeners();
  }

  void _handleStreamDone() async {
    if (_lastFinishReason != 'tool_calls' || _pendingToolCalls.isEmpty) {
      await _handleStreamDoneNormal();
      return;
    }

    // 模型可能**一次并发请求多路搜索**——实测问"最近有什么新模型"时它同时发
    // 中文一路 + 英文一路（两路覆盖的站点不一样）。旧实现只取 index 0 并把其余
    // 分片直接清空，等于静默丢掉一半检索，回答自然缺信息。这里全部收集。
    final indices = _pendingToolCalls.keys.toList()..sort();
    final queries = <String>[];
    var aiTopK = 0;
    var hasSearchTool = false;
    for (final i in indices) {
      final fn = _pendingToolCalls[i]?['function'];
      if (fn is! Map || fn['name'] != 'web_search') continue;
      hasSearchTool = true;
      final (query, topK) = _parseSearchArgs(fn['arguments']);
      if (query.isNotEmpty) queries.add(query);
      if (topK > aiTopK) aiTopK = topK;
    }
    _pendingToolCalls.clear();
    _lastFinishReason = null;

    if (!hasSearchTool) {
      // 只认 web_search；其它工具（将来扩展）暂不支持，回退普通响应
      await _handleStreamDoneNormal();
      return;
    }
    await _handleWebSearchTool(queries, aiTopK: aiTopK);
  }

  /// 解析一次工具调用的参数，返回 (query, top_k)；参数不合法时返回空查询
  static (String, int) _parseSearchArgs(dynamic raw) {
    if (raw is! String || raw.isEmpty) return ('', 0);
    try {
      final parsed = jsonDecode(raw) as Map?;
      final query = parsed?['query']?.toString().trim() ?? '';
      final topK = parsed?['top_k'];
      return (query, topK is int && topK > 0 ? topK : 0);
    } catch (_) {
      return ('', 0);
    }
  }

  /// 处理联网搜索工具调用（[queries] 可能有多路）
  Future<void> _handleWebSearchTool(
    List<String> queries, {
    required int aiTopK,
  }) async {
    // ① 查询去重（模型偶尔把同一路发两遍）+ 限量，避免搜索计费失控
    final unique = <String>[];
    final seen = <String>{};
    for (final q in queries) {
      final trimmed = q.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed.toLowerCase())) unique.add(trimmed);
      if (unique.length >= _maxQueriesPerTurn) break;
    }

    if (unique.isEmpty) {
      // 工具调用参数异常，回退普通响应
      await _handleStreamDoneNormal();
      return;
    }

    // ② 执行搜索（按用户选择的来源分派；多路查询逐路执行后合并）
    final setting = _settingCache!;
    // 保存 Phase 1 文本（搜索前的预回答）
    _phase1Text = _streamingText;
    _phase1Thinking = _streamingThinking;
    // 进入搜索等待：预回答改由 phase1 展示，流式缓冲清空；思考内容继续
    // 留在 _streamingThinking 里，第二阶段接续输出。立刻 notify 一次，
    // 让界面在搜索开始时就切到「预回答 + 搜索中」，而不是等结果返回时
    // 整个气泡突然消失再出现（那一下就是用户看到的闪烁）。
    _streamingText = '';
    notifyListeners();
    try {
      // 每路查询的条数：AI 指定的 top_k 优先，上限是用户设置的最大条数
      final perQuery = aiTopK > 0
          ? aiTopK.clamp(1, _maxSearchCount(setting))
          : setting.searchCount;

      final batches = <List<Map<String, dynamic>>>[];
      String? firstError;
      for (final q in unique) {
        try {
          batches.add(await _runWebSearch(setting, query: q, topK: perQuery));
        } catch (e) {
          // 多路查询里挂了一路：其余路仍可用，不该让整次回答失败
          firstError ??= e.toString().replaceFirst('Exception: ', '');
        }
      }
      if (batches.isEmpty) {
        throw Exception(firstError ?? '搜索失败');
      }

      _streamingSearchResults = mergeSearchResults(
        batches,
        maxTotal: _maxTotalResults(perQuery, unique.length),
      );
    } catch (e) {
      final errMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '联网搜索失败：${e.toString().replaceFirst('Exception: ', '')}',
        timestamp: DateTime.now().toIso8601String(),
      );
      _messages.add(errMsg);
      if (_currentSession?.id != null) {
        final saved = await ChatMessageService.insertMessage(
          errMsg,
          _currentSession!.id!,
        );
        _messages[_messages.length - 1] = saved;
      }
      _streamingText = '';
      _streamingThinking = '';
      _phase1Text = '';
      _phase1Thinking = '';
      _streamingSearchResults = null;
      _isLoading = false;
      notifyListeners();
      await _persistSession();
      return;
    }

    // ③ 组装搜索结果上下文，发起第二阶段流式请求
    final searchContext = _buildSearchContext(
      _streamingSearchResults ?? const [],
    );
    // 模型有时会在第二阶段又想搜一次；明确告诉它结果已经拿到，直接回答。
    // 这段属于尾部新增内容（本来就不会命中缓存），不影响前面的前缀。
    final answerContext =
        '以下搜索结果已经由 web_search 工具检索完成，'
        '请直接基于这些结果回答用户的问题，不要再次调用任何工具。\n\n'
        '$searchContext';

    // 缓存关键：第二阶段 = 第一阶段已发送的消息（含 tools）原样复用 + 末尾追加搜索结果。
    // 这样前缀与第一阶段逐字节一致，能命中第一阶段已写好的缓存；
    // 如果改成重建历史，时间注记会丢失，前缀从最后一条用户消息开始就失配。
    final phaseOne = _phaseOneMessages;
    final List<Map<String, dynamic>> apiMessages;
    if (phaseOne != null) {
      apiMessages = buildSearchAnswerMessages(
        phaseOneMessages: phaseOne,
        searchContext: answerContext,
      );
    } else {
      // 兜底（理论上不会走到）：没有快照时按旧逻辑重建
      apiMessages = _buildApiMessages();
      final sessionPrompt = _currentSession?.systemPrompt ?? '';
      final systemContent = buildChatSystemPrompt(sessionPrompt: sessionPrompt);
      if (systemContent.isNotEmpty) {
        apiMessages.insert(0, {'role': 'system', 'content': systemContent});
      }
      apiMessages.add({'role': 'user', 'content': answerContext});
    }

    // 进入第二阶段：保留思考内容（Phase 1 思考已包含在 _streamingThinking
    // 里），只清空正文缓冲；_phase1Thinking 置空，避免最终消息重复拼接。
    _streamingText = '';
    _phase1Thinking = '';
    notifyListeners();

    // 保留与第一阶段完全相同的 tools，否则提示词前缀不一致、缓存全部失效。
    //
    // 实测：`tool_choice: 'none'` 会让服务端把 tools 从提示词里整个去掉
    // （输入 token 从 350+ 掉到 86），前缀照样失配；所以这里用默认的 auto，
    // 靠搜索结果里的“不要再次调用工具”约束，并做一层降级兜底。
    final phaseOneTools = _phaseOneTools;
    var failed = false;

    Future<void> requestAnswer({required bool withTools}) async {
      _pendingToolCalls.clear();
      _lastFinishReason = null;
      _cancelToken = CancelToken();
      final params = setting.toApiParams();
      if (withTools && phaseOneTools != null && phaseOneTools.isNotEmpty) {
        params['tools'] = phaseOneTools;
      }
      await _apiService.streamChat(
        apiKey: setting.apiKey,
        apiParams: params,
        messages: apiMessages,
        onChunk: (chunk) => _handleStreamChunk(chunk, setting),
        // 收尾不在回调里做：先回到本方法，检测到二次工具调用才能降级重试
        onDone: () {},
        onError: (error) {
          failed = true;
          _handleStreamError(error);
        },
        cancelToken: _cancelToken,
      );
    }

    await requestAnswer(withTools: true);
    if (failed) return;

    // 兜底：模型无视提示再次发起工具调用时，去掉 tools 再请求一次（这次放弃缓存），
    // 避免把一条空回答存进数据库。
    if (_lastFinishReason == 'tool_calls' || _pendingToolCalls.isNotEmpty) {
      _streamingText = '';
      _streamingThinking = '';
      await requestAnswer(withTools: false);
      if (failed) return;
    }

    await _handleStreamDoneNormal();
  }

  /// 按当前来源执行搜索，返回归一化后的结果 Map 列表。
  ///
  /// 两个来源的返回都被压成同一套键（name/url/snippet/content + 可选的
  /// summary/site_name/date/authority），所以数据库格式、消息气泡、Web 端
  /// 读取逻辑都不用感知"这次用的是哪个来源"。
  Future<List<Map<String, dynamic>>> _runWebSearch(
    UserSetting setting, {
    required String query,
    required int topK,
  }) async {
    final engine = effectiveSearchEngine(setting);
    final count = topK > 0 ? topK : setting.searchCount;

    if (engine == UserSetting.searchEngineDeepseek) {
      // DeepSeek 官方搜索：同一个 Key、支持 ori_question 传原始问题帮助理解意图
      final results = await _deepSeekSearchService.search(
        query: query,
        apiKey: setting.apiKey,
        count: count,
        needContent: setting.searchNeedContent,
        oriQuestion: _lastUserQuestion(),
        freshness: setting.searchFreshness,
      );
      return results.map((r) => r.toMap()).toList();
    }

    final results = await _baiduSearchService.search(
      query: query,
      apiKey: setting.baiduApiKey,
      count: count,
      freshness: setting.searchFreshness,
    );
    return results.map((r) => r.toMap()).toList();
  }

  /// 最近一条用户消息，作为搜索的 ori_question（官方建议传原始问题以理解意图）
  String _lastUserQuestion() {
    for (final m in _messages.reversed) {
      if (m.isUser) return m.content;
    }
    return '';
  }

  /// 单次搜索的条数上限：百度用设置值；DeepSeek 官方硬上限 50，超了会 400
  static int _maxSearchCount(UserSetting? s) {
    final configured = s?.searchCount ?? 5;
    if (s != null &&
        effectiveSearchEngine(s) == UserSetting.searchEngineDeepseek) {
      return configured.clamp(
        DeepSeekSearchService.minCount,
        DeepSeekSearchService.maxCount,
      );
    }
    return configured;
  }

  /// 合并后注入模型的结果总条数上限。
  ///
  /// 每路查询的条数是用户设置的；多路合并会成倍增长（实测模型常发 2 路），
  /// 这里再压一道上限，避免"设置 20 条 × 3 路"变成 60 条灌进上下文。
  static int _maxTotalResults(int perQuery, int queryCount) =>
      (perQuery * queryCount).clamp(1, _maxMergedResults);

  /// 多路查询结果的合并：按链接去重 + 轮流取（轮流是为了保证每一路都有代表，
  /// 否则第一路条数多时会把后面几路全挤掉）。
  @visibleForTesting
  static List<Map<String, dynamic>> mergeSearchResults(
    List<List<Map<String, dynamic>>> batches, {
    required int maxTotal,
  }) {
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};

    var index = 0;
    while (merged.length < maxTotal) {
      var progressed = false;
      for (final batch in batches) {
        if (index >= batch.length) continue;
        progressed = true;
        final r = batch[index];
        final url = (r['url'] ?? r['link'] ?? '').toString().trim();
        // 链接为空时用"标题#序号"当键，避免多条空链接结果被误判成重复
        final key = url.isEmpty
            ? '${r['name'] ?? r['title'] ?? ''}#$index'
            : url;
        if (seen.add(key)) {
          merged.add(r);
          if (merged.length >= maxTotal) break;
        }
      }
      if (!progressed) break;
      index++;
    }
    return merged;
  }

  /// 把搜索结果拼成注入模型的上下文。
  ///
  /// 字段取舍：正文（content）> 长摘要（summary）> 短摘要（snippet）
  ///   * 百度链路只有 snippet/content，行为与改动前一致；
  ///   * DeepSeek 官方把 summary 定位成"给模型阅读"（600~800 字）、snippet 定位成
  ///     "给前端展现"（100~200 字）。所以没开"抓取正文"时注入 summary，而不是
  ///     拿 100 字的 snippet 当唯一依据；
  ///   * 单条正文按 [_maxContentCharsPerResult] 截断：开 need_content 后单条
  ///     可能是整页上万字，5 条不截就把上下文塞满了。
  String _buildSearchContext(List<Map<String, dynamic>> results) {
    final buf = StringBuffer();
    buf.writeln('以下是来自互联网的搜索结果（共 ${results.length} 条），请基于这些信息回答用户问题：');
    var used = 0;
    var injected = 0;
    for (int i = 0; i < results.length; i++) {
      final r = results[i];
      final title = _str(r['name']) ?? _str(r['title']) ?? '';
      final url = _str(r['url']) ?? _str(r['link']) ?? '';
      final siteName = _str(r['site_name']) ?? '';
      final date = _str(r['date']) ?? '';
      final snippet = _str(r['snippet']) ?? '';
      final summary = _str(r['summary']) ?? '';
      final content = _str(r['content']) ?? '';

      final block = StringBuffer();
      final meta = [
        if (siteName.isNotEmpty) siteName,
        if (date.isNotEmpty) date,
      ].join(' ');
      block.writeln('[$i] $title${meta.isEmpty ? '' : '（$meta）'}');
      if (url.isNotEmpty) block.writeln('   链接：$url');

      if (content.isNotEmpty) {
        block.writeln('   正文：${_clip(content, _maxContentCharsPerResult)}');
      } else if (summary.isNotEmpty) {
        block.writeln('   摘要：${_clip(summary, _maxSummaryCharsPerResult)}');
      } else if (snippet.isNotEmpty) {
        block.writeln('   摘要：$snippet');
      }

      final text = block.toString();
      // 总预算：超了就不再注入（宁可少几条，也不让单次请求的上下文爆炸）
      if (injected > 0 && used + text.length > _searchContextBudget) break;
      buf.write(text);
      used += text.length;
      injected++;
    }
    if (injected < results.length) {
      buf.writeln('（其余 ${results.length - injected} 条因上下文长度限制未列出）');
    }
    return buf.toString();
  }

  static String? _str(dynamic v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// 按码点截断（不能按 UTF-16 长度切，会把中文/emoji 劈成半个字符）
  static String _clip(String s, int max) {
    final runes = s.runes.toList(growable: false);
    if (runes.length <= max) return s;
    return '${String.fromCharCodes(runes.take(max))}…（已截断）';
  }

  /// 普通流式结束处理：保存消息、重置状态
  Future<void> _handleStreamDoneNormal() async {
    final hasThinking =
        _streamingThinking.isNotEmpty || _phase1Thinking.isNotEmpty;
    final hasContent = _streamingText.isNotEmpty || _phase1Text.isNotEmpty;

    ChatMessage? assistantMsg;
    if (hasThinking || hasContent) {
      // 合并 Phase 1 + Phase 2 内容
      final mergedContent = _phase1Text.isNotEmpty && _streamingText.isNotEmpty
          ? '$_phase1Text\n\n$_streamingText'
          : (_phase1Text.isNotEmpty ? _phase1Text : _streamingText);
      final mergedThinking =
          _phase1Thinking.isNotEmpty && _streamingThinking.isNotEmpty
          ? '$_phase1Thinking\n\n$_streamingThinking'
          : (_phase1Thinking.isNotEmpty ? _phase1Thinking : _streamingThinking);

      assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: mergedContent,
        thinkingText: mergedThinking.isNotEmpty ? mergedThinking : null,
        timestamp: DateTime.now().toIso8601String(),
        searchResults: _streamingSearchResults,
        // 记录产生这条回答的那次请求的 usage：消息菜单里的「缓存命中」用它，
        // 和会话累计（输入框上方）区分开。
        promptTokens: _contextTokens,
        cachedTokens: _cachedTokens,
        completionTokens: _completionTokens,
      );
      _messages.add(assistantMsg);

      // 消息入库（仅已持久化会话）
      if (_currentSession?.id != null) {
        final saved = await ChatMessageService.insertMessage(
          assistantMsg,
          _currentSession!.id!,
        );
        _messages[_messages.length - 1] = saved;
      }
    }

    _streamingText = '';
    _streamingThinking = '';
    _streamingSearchResults = null;
    _phase1Text = '';
    _phase1Thinking = '';
    _isLoading = false;
    notifyListeners();
    await _persistSession();
  }

  void _handleStreamError(String error) async {
    final errMsg = ChatMessage(
      role: MessageRole.assistant,
      content: '请求失败：$error',
      timestamp: DateTime.now().toIso8601String(),
    );
    _messages.add(errMsg);
    if (_currentSession?.id != null) {
      final saved = await ChatMessageService.insertMessage(
        errMsg,
        _currentSession!.id!,
      );
      _messages[_messages.length - 1] = saved;
    }
    _streamingText = '';
    _streamingThinking = '';
    _phase1Text = '';
    _phase1Thinking = '';
    _streamingSearchResults = null;
    _isLoading = false;
    notifyListeners();
    await _persistSession();
  }

  // ============================================================
  //  ── 会话管理 ──
  // ============================================================

  /// 新建空白会话
  Future<void> newSession() async {
    _messages = [];
    _summary = '';
    _summaryCount = 0;
    _contextTokens = 0;
    _cachedTokens = 0;
    _completionTokens = 0;
    _contextWindow = 0;
    _totalPromptTokens = 0;
    _totalCachedTokens = 0;
    _estimatedTokens = 0;
    _lastCompactedCount = 0;
    _isCompacting = false;
    _streamingText = '';
    _streamingThinking = '';
    _phase1Text = '';
    _phase1Thinking = '';
    _streamingSearchResults = null;
    // 创建内存会话（id=null），等发消息时再入库，避免空会话堆积
    _currentSession = ChatSession(
      title: '新对话',
      createTime: DateTime.now().toIso8601String(),
    );
    notifyListeners();
  }

  /// 加载已有会话：从数据库读取历史消息
  Future<void> loadSession(ChatSession session) async {
    _currentSession = session;
    _summary = session.summary; // 加载持久化的检查点
    _summaryCount = session.summaryCount;
    _contextTokens = session.contextTokens;
    _cachedTokens = session.cachedTokens;
    _completionTokens = 0;
    _contextWindow = session.contextWindow;
    _totalPromptTokens = session.totalPromptTokens;
    _totalCachedTokens = session.totalCachedTokens;
    _estimatedTokens = 0;
    _lastCompactedCount = 0;
    _isCompacting = false;
    _streamingText = '';
    _streamingThinking = '';
    _phase1Text = '';
    _phase1Thinking = '';
    _streamingSearchResults = null;
    _isLoading = false;
    notifyListeners();

    // 从数据库加载该会话的历史消息
    try {
      _messages = await ChatMessageService.getMessagesBySession(session.id!);
    } catch (_) {
      _messages = [];
    }
    // 兼容旧数据：摘要覆盖条数不能超过当前消息数
    if (_summaryCount > _messages.length) {
      _summaryCount = _messages.length;
    }
    // 旧版本的摘要没有记录覆盖条数（summary_count=0）：直接丢弃，
    // 因为所有消息都还在本地，重新按窗口压缩即可，避免摘要与全文重复注入。
    if (_summary.isNotEmpty && _summaryCount <= 0) {
      _summary = '';
    }
    // 打开会话就先给一个估算占用，进度条不用等下一轮
    final setting = _settingCache ?? const UserSetting();
    _contextWindow = _contextWindow > 0
        ? _contextWindow
        : _budgetFor(setting).window;
    _estimatedTokens = _estimateContext(setting);
    notifyListeners();
  }

  /// 持久化当前会话元数据（插入或更新），并写入待入库消息
  Future<void> _persistSession() async {
    final lastMsg = _messages.isNotEmpty ? _messages.last.content : '';

    if (_currentSession == null || _currentSession!.id == null) {
      // 新会话/内存会话：生成标题（取首条用户消息前 20 字）
      final firstUserMsg = _messages.where((m) => m.isUser).firstOrNull;
      final title = firstUserMsg != null
          ? (firstUserMsg.content.length > 20
                ? '${firstUserMsg.content.substring(0, 20)}...'
                : firstUserMsg.content)
          : _currentSession?.title ?? '新对话';

      final newSession = ChatSession(
        title: title,
        createTime:
            _currentSession?.createTime ?? DateTime.now().toIso8601String(),
        lastMessage: lastMsg,
        systemPrompt: _currentSession?.systemPrompt ?? '', // 继承内存中的系统提示词
        summary: _summary,
        summaryCount: _summaryCount,
        contextTokens: _contextTokens,
        cachedTokens: _cachedTokens,
        contextWindow: _contextWindow,
        totalPromptTokens: _totalPromptTokens,
        totalCachedTokens: _totalCachedTokens,
      );

      final id = await ChatSessionService.insertSession(newSession);
      _currentSession = newSession.copyWith(id: id);

      // 新会话创建后，将当前内存消息批量入库
      for (int i = 0; i < _messages.length; i++) {
        final saved = await ChatMessageService.insertMessage(_messages[i], id);
        _messages[i] = saved;
      }
    } else {
      // 已有会话：更新最后一条消息与检查点/用量
      final updated = _currentSession!.copyWith(
        lastMessage: lastMsg,
        summary: _summary,
        summaryCount: _summaryCount,
        contextTokens: _contextTokens,
        cachedTokens: _cachedTokens,
        contextWindow: _contextWindow,
        totalPromptTokens: _totalPromptTokens,
        totalCachedTokens: _totalCachedTokens,
      );
      await ChatSessionService.updateSession(updated);
      _currentSession = updated;
    }
    notifyListeners();
  }

  /// 只更新会话元数据（检查点与 usage），不动消息表；压缩后立即调用。
  Future<void> _saveSessionMeta() async {
    final session = _currentSession;
    if (session == null || session.id == null) return;
    final updated = session.copyWith(
      summary: _summary,
      summaryCount: _summaryCount,
      contextTokens: _contextTokens,
      cachedTokens: _cachedTokens,
      contextWindow: _contextWindow,
      totalPromptTokens: _totalPromptTokens,
      totalCachedTokens: _totalCachedTokens,
    );
    await ChatSessionService.updateSession(updated);
    _currentSession = updated;
  }

  // ============================================================
  //  ── 删除消息 ──
  // ============================================================

  /// 按索引列表删除消息（同时从内存和数据库删除）
  Future<void> deleteMessages(Set<int> indices) async {
    if (indices.isEmpty || _isLoading) return;

    // 按降序排列索引，避免删除时索引偏移
    final sorted = indices.toList()..sort((a, b) => b.compareTo(a));
    final dbIds = <int>[];
    var removedBeforeSummary = 0;

    for (final index in sorted) {
      if (index >= 0 && index < _messages.length) {
        final msg = _messages[index];
        if (msg.id != null) dbIds.add(msg.id!);
        if (index < _summaryCount) removedBeforeSummary++;
        _messages.removeAt(index);
      }
    }
    // 检查点覆盖的条数跟着删除前移，避免把未被摘要的消息重复注入
    _summaryCount = (_summaryCount - removedBeforeSummary)
        .clamp(0, _messages.length)
        .toInt();

    // 从数据库删除
    if (dbIds.isNotEmpty) {
      await ChatMessageService.deleteMessagesByIds(dbIds);
    }

    notifyListeners();
  }

  // ============================================================
  //  ── 缓存管理 ──
  // ============================================================

  /// 由 SessionSettingsPage 调用，更新当前会话的系统提示词
  void updateSessionSystemPrompt(String prompt) {
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(systemPrompt: prompt);
      notifyListeners();
    }
  }

  /// 清空配置缓存（设置页保存后调用，下次对话重新查库）
  void clearSettingCache() {
    _settingCache = null;
  }
}

/// ChatController Riverpod Provider（全局单例，主聊天页与悬浮迷你面板共用）
final chatProvider = ChangeNotifierProvider<ChatController>(
  (ref) => ChatController(),
);
