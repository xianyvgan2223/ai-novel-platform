/// lib/controllers/chat_controller.dart
/// 对话控制器 — 负责消息发送、流式接收、上下文裁剪、会话持久化、消息入库
/// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/chat_message.dart';
import '../domain/chat_session.dart';
import '../../../core/config/user_setting.dart';
import '../../../core/network/api_service.dart';
import '../../../core/config/user_setting_service.dart';
import '../data/chat_session_service.dart';
import '../data/chat_message_service.dart';
import '../../../core/network/baidu_search_service.dart';
import '../../../core/network/deepseek_search_service.dart';
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

  /// 禁止 Markdown 格式的系统指令
  static const String _noMarkdownInstruction =
      '重要：回复中全文禁止使用任何Markdown语法，不允许出现#、##、*、**、-、1.、`、```、>、---、[]()等标记，请使用纯文本表达。';

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
  String _summary = ''; // 当前会话的对话历史摘要（持久化到 DB）
  int _summarizedUserCount = 0; // 已被摘要覆盖的用户消息轮数

  // ── getter ──
  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  String get streamingText => _streamingText;
  String get streamingThinking => _streamingThinking;
  List<Map<String, dynamic>>? get streamingSearchResults =>
      _streamingSearchResults;
  ChatSession? get currentSession => _currentSession;
  bool get isStreamingEmpty =>
      _streamingText.isEmpty && _streamingThinking.isEmpty;
  String get phase1Text => _phase1Text;
  String get phase1Thinking => _phase1Thinking;

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
    return s.webSearch ? UserSetting.searchEngineBaidu : UserSetting.searchEngineOff;
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
    final today = DeepSeekSearchService.isoDate(DateTime.now());
    final baseDescription =
        '搜索互联网获取实时信息。当用户询问新闻、实时数据或需要最新信息时使用。'
        '当前日期是 $today，检索最新信息时请使用正确的年份。';
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
              'description':
                  '返回搜索结果数量，不传则使用默认值。请根据用户需求合理调整，范围1-$maxTopK。',
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

    // ④ 组装 API 消息：历史摘要 + 最近 N 轮原文
    final apiMessages = _buildApiMessages(setting.contextRounds);

    // ⑤ 组装 API 参数
    final apiParams = setting.toApiParams();

    // ⑤b 注入系统提示词（始终附加禁止 Markdown 指令）
    final sessionPrompt = _currentSession?.systemPrompt ?? '';
    final systemContent = sessionPrompt.trim().isNotEmpty
        ? '$sessionPrompt\n\n$_noMarkdownInstruction'
        : _noMarkdownInstruction;
    apiMessages.insert(0, {'role': 'system', 'content': systemContent});

    // ⑤c 工具注入（AI 可决策的工具列表）
    final tools = <Map<String, dynamic>>[];

    // 联网搜索工具
    final searchEngine = effectiveSearchEngine(setting);
    if (searchEngine != UserSetting.searchEngineOff) {
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
        await _updateSummary();
        return;
      }
      tools.add(buildWebSearchTool(setting, searchEngine));
    }

    if (tools.isNotEmpty) {
      apiParams['tools'] = tools;
    }

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
  //  ── 上下文裁剪逻辑 ──
  // ============================================================

  /// 从完整 messages 中截取最近 contextRounds 轮对话（本地完整保留）
  List<ChatMessage> _trimContext(int contextRounds) {
    if (_messages.isEmpty) return [];

    // 按用户消息轮次计数，保留最后 N 轮
    final reversed = _messages.reversed.toList();
    final result = <ChatMessage>[];
    int userCount = 0;

    for (final msg in reversed) {
      result.insert(0, msg);
      if (msg.isUser) {
        userCount++;
        if (userCount >= contextRounds) break;
      }
    }

    return result;
  }

  /// 提取超出 contextRounds 的老消息（需要被压缩进摘要的部分）
  List<ChatMessage> _extractOldMessages(int contextRounds) {
    final userMsgCount = _messages.where((m) => m.isUser).length;
    if (userMsgCount <= contextRounds) return [];

    final maxOldUserRounds = userMsgCount - contextRounds;
    final oldMessages = <ChatMessage>[];
    int userCount = 0;

    for (final msg in _messages) {
      if (msg.isUser) {
        if (userCount >= maxOldUserRounds) break;
        userCount++;
      }
      oldMessages.add(msg);
    }

    return oldMessages;
  }

  /// 组装发送给 API 的消息列表：[历史摘要(system)] + [最近 N 轮原文]
  List<Map<String, dynamic>> _buildApiMessages(int contextRounds) {
    final apiMessages = <Map<String, dynamic>>[];

    // ① 注入对话历史摘要（早期对话的压缩总结）
    if (_summary.isNotEmpty) {
      apiMessages.add({
        'role': 'system',
        'content': '以下是对话前期的历史摘要（包含已超出上下文的早期对话）：\n$_summary',
      });
    }

    // ② 注入最近 N 轮原始消息
    final recentMessages = _trimContext(contextRounds);
    apiMessages.addAll(recentMessages.map((m) => m.toApiMessage()));

    return apiMessages;
  }

  // ============================================================
  //  ── 流式数据分片处理 ──
  // ============================================================

  void _handleStreamChunk(Map<String, dynamic> chunk, UserSetting setting) {
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
      _streamingSearchResults = null;
      _isLoading = false;
      notifyListeners();
      await _persistSession();
      await _updateSummary();
      return;
    }

    // ③ 组装搜索结果上下文，发起第二阶段流式请求
    final searchContext = _buildSearchContext(_streamingSearchResults ?? const []);

    // 从原始上下文中排除旧 system 工具结果，重建消息列表
    final apiMessages = _buildApiMessages(setting.contextRounds);
    final sessionPrompt = _currentSession?.systemPrompt ?? '';
    final systemContent = sessionPrompt.trim().isNotEmpty
        ? '$sessionPrompt\n\n$_noMarkdownInstruction'
        : _noMarkdownInstruction;
    apiMessages.insert(0, {'role': 'system', 'content': systemContent});
    apiMessages.add({'role': 'user', 'content': searchContext});

    // 重置流式状态，保持 _isLoading
    _streamingText = '';
    _streamingThinking = '';
    notifyListeners();

    // 发起第二阶段流式请求
    final apiParams = setting.toApiParams();
    apiParams.remove('tools'); // 第二阶段不需要 tools
    _cancelToken = CancelToken();
    await _apiService.streamChat(
      apiKey: setting.apiKey,
      apiParams: apiParams,
      messages: apiMessages,
      onChunk: (chunk) => _handleStreamChunk(chunk, setting),
      onDone: () => _handleStreamDoneNormal(),
      onError: (error) => _handleStreamError(error),
      cancelToken: _cancelToken,
    );
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
    await _updateSummary(); // 摘要更新（静默，不会阻塞 UI）
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
    _summarizedUserCount = 0;
    _streamingText = '';
    _streamingThinking = '';
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
    _summary = session.summary; // 加载持久化的对话摘要
    _streamingText = '';
    _streamingThinking = '';
    _isLoading = false;
    notifyListeners();

    // 从数据库加载该会话的历史消息
    try {
      _messages = await ChatMessageService.getMessagesBySession(session.id!);
    } catch (_) {
      _messages = [];
    }
    // 标记当前所有消息已覆盖（避免加载后立即触发重复摘要）
    _summarizedUserCount = _messages.where((m) => m.isUser).length;
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
      );

      final id = await ChatSessionService.insertSession(newSession);
      _currentSession = newSession.copyWith(id: id);

      // 新会话创建后，将当前内存消息批量入库
      for (int i = 0; i < _messages.length; i++) {
        final saved = await ChatMessageService.insertMessage(_messages[i], id);
        _messages[i] = saved;
      }
    } else {
      // 已有会话：更新最后一条消息
      final updated = _currentSession!.copyWith(lastMessage: lastMsg);
      await ChatSessionService.updateSession(updated);
      _currentSession = updated;
    }
    notifyListeners();
  }

  /// 异步更新对话历史摘要（仅在消息超出 contextRounds 时触发）
  Future<void> _updateSummary() async {
    final setting = _settingCache;
    if (setting == null) return;
    if (_currentSession?.id == null) return; // 未持久化的会话不更新摘要

    // 提取所有被裁掉的老消息
    final oldMessages = _extractOldMessages(setting.contextRounds);
    final oldUserCount = oldMessages.where((m) => m.isUser).length;
    if (oldUserCount <= _summarizedUserCount) return; // 没有新增被裁的消息，跳过

    // 提取新增被裁的消息（oldMessages 中靠后的 newCutUserRounds 轮）
    final newCutUserRounds = oldUserCount - _summarizedUserCount;
    final newCutMessages = <ChatMessage>[];
    int count = 0;
    for (final msg in oldMessages.reversed) {
      newCutMessages.insert(0, msg);
      if (msg.isUser) {
        count++;
        if (count >= newCutUserRounds) break;
      }
    }

    // 构建摘要更新提示
    final summaryMessages = <Map<String, dynamic>>[];
    summaryMessages.add({
      'role': 'system',
      'content':
          '你是一个对话摘要生成器。请根据已有的摘要和新内容，生成更新后的完整对话摘要。'
          '要求：保持简洁（200字以内），保留关键信息，使用与对话相同的语言。',
    });

    final prompt = StringBuffer();
    if (_summary.isNotEmpty) {
      prompt.writeln('【当前摘要】\n$_summary\n');
    }
    prompt.writeln('【新被裁掉的对话内容，请将其融入摘要】');
    for (final msg in newCutMessages) {
      final role = msg.isUser ? '用户' : '助手';
      prompt.writeln('$role：${msg.content}');
    }
    prompt.writeln('\n请输出更新后的完整摘要：');
    summaryMessages.add({'role': 'user', 'content': prompt.toString()});

    try {
      final result = await _apiService.chat(
        apiKey: setting.apiKey,
        apiParams: {
          'model': setting.model,
          'temperature': 0.3,
          'max_tokens': setting.maxTokens,
        },
        messages: summaryMessages,
      );
      final choices = result['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final content = choices[0]['message']?['content'] as String?;
        if (content != null && content.trim().isNotEmpty) {
          _summary = content.trim();

          // 持久化摘要到数据库
          _currentSession = _currentSession!.copyWith(summary: _summary);
          await ChatSessionService.updateSession(_currentSession!);
          _summarizedUserCount = oldUserCount; // 更新已覆盖计数
        }
      }
    } catch (_) {
      // 静默失败，保留旧摘要
    }
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

    for (final index in sorted) {
      if (index >= 0 && index < _messages.length) {
        final msg = _messages[index];
        if (msg.id != null) dbIds.add(msg.id!);
        _messages.removeAt(index);
      }
    }

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
