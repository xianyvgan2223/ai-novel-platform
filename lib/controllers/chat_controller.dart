/// lib/controllers/chat_controller.dart
/// 对话控制器 — 负责消息发送、流式接收、上下文裁剪、会话持久化、消息入库
/// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/user_setting.dart';
import '../services/api_service.dart';
import '../services/user_setting_service.dart';
import '../services/chat_session_service.dart';
import '../services/chat_message_service.dart';
import '../services/baidu_search_service.dart';
import 'package:dio/dio.dart';

class ChatController extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final BaiduSearchService _baiduSearchService = BaiduSearchService();

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
    if (setting.webSearch) {
      if (setting.baiduApiKey.isEmpty) {
        final errMsg = ChatMessage(
          role: MessageRole.assistant,
          content: '联网搜索已开启，但未填写百度千帆 API Key，请在设置页面填写后再发送。',
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
      tools.add({
        'type': 'function',
        'function': {
          'name': 'web_search',
          'description': '搜索互联网获取实时信息。当用户询问新闻、实时数据或需要最新信息时使用。',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': '搜索关键词，使用简洁明确的关键词组合，长度不超过72个字符。',
              },
              'top_k': {
                'type': 'integer',
                'description':
                    '返回搜索结果数量，不传则使用默认值。请根据用户需求合理调整，范围1-${setting.searchCount}。',
              },
            },
            'required': ['query'],
          },
        },
      });
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

    final firstToolCall = _pendingToolCalls[0]!;
    final toolCallId = firstToolCall['id'] as String?;
    final tc = firstToolCall['function'];
    final toolName = tc?['name'] as String?;
    _pendingToolCalls.clear();
    _lastFinishReason = null;

    if (toolName == 'web_search') {
      await _handleWebSearchTool(tc, toolCallId: toolCallId);
    } else {
      await _handleStreamDoneNormal();
    }
  }

  /// 处理联网搜索工具调用
  Future<void> _handleWebSearchTool(
    Map<String, dynamic>? tc, {
    String? toolCallId,
  }) async {
    // ① 提取搜索关键词和条数
    String query = '';
    int topK = 0;
    if (tc != null && tc['arguments'] is String) {
      try {
        final parsed = jsonDecode(tc['arguments']) as Map?;
        query = parsed?['query']?.toString() ?? '';
        // AI 指定的 top_k，上限为用户设置的最大值
        final aiTopK = parsed?['top_k'];
        if (aiTopK is int && aiTopK > 0) {
          topK = aiTopK.clamp(1, _settingCache?.searchCount ?? 5);
        }
      } catch (_) {}
    }

    if (query.isEmpty) {
      // 工具调用参数异常，回退普通响应
      await _handleStreamDoneNormal();
      return;
    }

    // ② 执行百度搜索
    final setting = _settingCache!;
    // 保存 Phase 1 文本（搜索前的预回答）
    _phase1Text = _streamingText;
    _phase1Thinking = _streamingThinking;
    try {
      final searchResults = await _baiduSearchService.search(
        query: query,
        apiKey: setting.baiduApiKey,
        count: topK > 0 ? topK : setting.searchCount,
        freshness: setting.searchFreshness,
      );
      _streamingSearchResults = searchResults.map((r) => r.toMap()).toList();
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

    // ③ 组装 tool_call 消息 + tool 结果消息，发起第二阶段流式请求
    final searchContext = StringBuffer();
    searchContext.writeln('以下是来自互联网的搜索结果，请基于这些信息回答用户问题：');
    if (_streamingSearchResults != null) {
      for (int i = 0; i < _streamingSearchResults!.length; i++) {
        final r = _streamingSearchResults![i];
        final title = r['name']?.toString() ?? r['title']?.toString() ?? '';
        final snippet = r['snippet']?.toString() ?? '';
        final content = r['content']?.toString() ?? '';
        searchContext.writeln('[$i] $title');
        if (snippet.isNotEmpty) searchContext.writeln('   摘要：$snippet');
        if (content.isNotEmpty) searchContext.writeln('   正文：$content');
      }
    }

    // 从原始上下文中排除旧 system 工具结果，重建消息列表
    final apiMessages = _buildApiMessages(setting.contextRounds);
    final sessionPrompt = _currentSession?.systemPrompt ?? '';
    final systemContent = sessionPrompt.trim().isNotEmpty
        ? '$sessionPrompt\n\n$_noMarkdownInstruction'
        : _noMarkdownInstruction;
    apiMessages.insert(0, {'role': 'system', 'content': systemContent});
    apiMessages.add({'role': 'user', 'content': searchContext.toString()});

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
          'max_tokens': 500,
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
