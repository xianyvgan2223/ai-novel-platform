// lib/game/character_chat/controller/chat_controller.dart
// 对话游戏控制器 — 对话流 + Swipe + WorldInfo + 摘要 + 记忆

import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../../core/network/api_service.dart';
import '../../../../core/db/database_helper.dart';
import '../../../../core/config/user_setting_service.dart';
import '../model/character_model.dart';
import '../data/chat_db_service.dart';
import '../data/world_info_service.dart';
import '../data/memory_service.dart';

/// 单条对话消息
class ChatMessage {
  final bool isUser;
  final String content;
  final DateTime timestamp;

  const ChatMessage({
    required this.isUser,
    required this.content,
    required this.timestamp,
  });
}

/// 对话游戏控制器
class CharacterChatController extends ChangeNotifier {
  final ApiService _apiService;

  // ── 核心状态 ──
  CharacterModel? _character;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  String? _error;
  CancelToken? _cancelToken;
  String? _apiKey;
  int? _sessionId;
  List<CharacterChatSession> _sessions = [];

  // ── Swipe 多候选 ──
  /// 每条 AI 消息的候选列表，key 为消息在 _messages 中的索引
  final Map<int, List<String>> _candidates = {};

  /// 当前选中的候选索引
  final Map<int, int> _candidateIndex = {};

  // ── World Info ──
  List<WorldInfoEntry> _worldEntries = [];

  // ── 摘要 ──
  static const int _summaryThreshold = 30; // 超过30条消息触发摘要
  String? _summary;

  // ── 记忆 ──
  int _messageCountSinceMemoryCheck = 0;
  static const int _memoryCheckInterval = 6; // 每6条消息提取一次记忆

  CharacterChatController({ApiService? apiService})
    : _apiService = apiService ?? ApiService();

  // ── Getters ──
  CharacterModel? get character => _character;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasCharacter => _character != null;
  int? get sessionId => _sessionId;
  List<CharacterChatSession> get sessions => List.unmodifiable(_sessions);
  String? get summary => _summary;
  List<WorldInfoEntry> get worldEntries => List.unmodifiable(_worldEntries);

  /// 获取指定 AI 消息的候选回复数量
  int candidateCount(int messageIndex) =>
      _candidates[messageIndex]?.length ?? 1;

  /// 获取当前选中的候选索引
  int currentCandidateIndex(int messageIndex) =>
      _candidateIndex[messageIndex] ?? 0;

  /// 切换到下一条候选
  void swipeNext(int messageIndex) {
    final list = _candidates[messageIndex];
    if (list == null || list.length <= 1) return;
    final current = (_candidateIndex[messageIndex] ?? 0);
    final next = (current + 1) % list.length;
    _candidateIndex[messageIndex] = next;
    _messages = _messages.toList();
    _messages[messageIndex] = ChatMessage(
      isUser: false,
      content: list[next],
      timestamp: _messages[messageIndex].timestamp,
    );
    notifyListeners();
  }

  /// 切换到上一条候选
  void swipePrev(int messageIndex) {
    final list = _candidates[messageIndex];
    if (list == null || list.length <= 1) return;
    final current = (_candidateIndex[messageIndex] ?? 0);
    final prev = (current - 1 + list.length) % list.length;
    _candidateIndex[messageIndex] = prev;
    _messages = _messages.toList();
    _messages[messageIndex] = ChatMessage(
      isUser: false,
      content: list[prev],
      timestamp: _messages[messageIndex].timestamp,
    );
    notifyListeners();
  }

  // ───────────────── 会话管理 ─────────────────

  Future<void> loadSessions() async {
    try {
      _sessions = await CharacterChatDbService.getAllSessions();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> loadSession(int sessionId) async {
    try {
      final session = await CharacterChatDbService.getSession(sessionId);
      if (session == null) return;
      _sessionId = sessionId;
      _character = session.toCharacter();
      _messages = await CharacterChatDbService.getMessages(sessionId);
      _error = null;
      _worldEntries = await WorldInfoService.getEntries(sessionId);
      _summary = session.summary.isNotEmpty ? session.summary : null;
      _candidates.clear();
      _candidateIndex.clear();
      await _loadApiKey();
    } catch (e) {
      _error = '加载会话失败: $e';
    }
    notifyListeners();
  }

  Future<void> selectCharacter(CharacterModel character) async {
    _character = character;
    _messages = [
      ChatMessage(
        isUser: false,
        content: character.firstMes,
        timestamp: DateTime.now(),
      ),
    ];
    _error = null;
    _sessionId = null;
    _candidates.clear();
    _candidateIndex.clear();
    _worldEntries = [];
    _summary = null;
    _messageCountSinceMemoryCheck = 0;

    try {
      final sessionRecord = CharacterChatSession.fromCharacter(character);
      _sessionId = await CharacterChatDbService.createSession(sessionRecord);
      await CharacterChatDbService.deleteMessages(_sessionId!);
      await CharacterChatDbService.saveMessages(_sessionId!, _messages);
    } catch (e) {
      debugPrint('创建会话失败: $e');
    }

    await _loadApiKey();
    notifyListeners();
  }

  Future<void> _loadApiKey() async {
    try {
      final settings = await UserSettingService.getSettings();
      _apiKey = settings.apiKey;
      if (_apiKey == null || _apiKey!.isEmpty) {
        _error = '请先在设置中配置 API Key';
      }
    } catch (e) {
      _error = '读取配置失败: $e';
    }
  }

  Future<void> _persistMessages() async {
    if (_sessionId == null) return;
    try {
      await CharacterChatDbService.deleteMessages(_sessionId!);
      await CharacterChatDbService.saveMessages(_sessionId!, _messages);
      await CharacterChatDbService.touchSession(_sessionId!);
    } catch (e) {
      debugPrint('持久化消息失败: $e');
    }
  }

  // ───────────────── 对话交互 ─────────────────

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || _isLoading || _character == null) return;
    if (_apiKey == null || _apiKey!.isEmpty) {
      _error = '请先在设置中配置 API Key';
      notifyListeners();
      return;
    }

    final userMsg = ChatMessage(
      isUser: true,
      content: text.trim(),
      timestamp: DateTime.now(),
    );
    _messages = [..._messages, userMsg];
    _error = null;

    // World Info 匹配
    await _injectWorldInfo();

    notifyListeners();
    await _requestAi();
  }

  /// World Info 注入：在用户消息中匹配关键词
  Future<void> _injectWorldInfo() async {
    if (_sessionId == null || _worldEntries.isEmpty) return;
    final lastMsg = _messages.last;
    final matched = WorldInfoService.matchContent(
      _worldEntries,
      lastMsg.content,
    );
    if (matched.isNotEmpty) {
      // 将匹配到的 world info 以系统消息形式加入上下文
      // 实际上我们把它注入到 _buildContextMessages 中
    }
  }

  /// 请求 AI 回复（主回复，流式）
  Future<void> _requestAi() async {
    if (_character == null || _apiKey == null) return;

    _isLoading = true;
    _cancelToken = CancelToken();
    notifyListeners();

    final messages = await _buildContextMessages();

    try {
      final settings = await UserSettingService.getSettings();
      final apiParams = settings.toApiParams();

      // 记录当前最后一条 AI 消息的索引（用于后续 swipe 候选定位）
      final aiMsgIndex = _messages.length;

      await _apiService.streamChat(
        apiKey: _apiKey!,
        apiParams: apiParams,
        messages: messages,
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          try {
            final choices = chunk['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map<String, dynamic>?;
              final content = delta?['content'] as String? ?? '';
              if (content.isNotEmpty) {
                if (_messages.isNotEmpty && !_messages.last.isUser) {
                  final last = _messages.last;
                  _messages = [
                    ..._messages.sublist(0, _messages.length - 1),
                    ChatMessage(
                      isUser: false,
                      content: last.content + content,
                      timestamp: last.timestamp,
                    ),
                  ];
                } else {
                  _messages = [
                    ..._messages,
                    ChatMessage(
                      isUser: false,
                      content: content,
                      timestamp: DateTime.now(),
                    ),
                  ];
                }
                notifyListeners();
              }
            }
          } catch (_) {}
        },
        onDone: () async {
          _isLoading = false;
          notifyListeners();

          // 保存主回复到候选列表
          if (_messages.isNotEmpty && !_messages.last.isUser) {
            final lastIdx = _messages.length - 1;
            _candidates[lastIdx] = [_messages.last.content];
            _candidateIndex[lastIdx] = 0;
          }

          // 持久化
          await _persistMessages();

          // 后台生成额外候选
          _generateSwipes(aiMsgIndex);

          // 检查摘要
          await _checkSummary();

          // 检查记忆提取
          await _checkMemoryExtraction();
        },
        onError: (error) {
          _isLoading = false;
          _error = error;
          notifyListeners();
          _persistMessages();
        },
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) return;
      _isLoading = false;
      _error = 'AI 请求失败: $e';
      notifyListeners();
      _persistMessages();
    }
  }

  /// 后台生成额外候选回复（非流式，生成2个备选）
  Future<void> _generateSwipes(int aiMsgIndex) async {
    if (_sessionId == null || _character == null || _apiKey == null) return;
    if (aiMsgIndex < 0 || aiMsgIndex >= _messages.length) return;
    if (_messages[aiMsgIndex].isUser) return;

    try {
      // 构建与主回复相同的上下文（不含当前待回复的用户消息）
      final messages = await _buildContextMessages();
      // 移除最后的 assistant 占位消息
      if (messages.isNotEmpty && messages.last['role'] == 'assistant') {
        messages.removeLast();
      }

      final settings = await UserSettingService.getSettings();
      final apiParams = Map<String, dynamic>.from(settings.toApiParams());
      apiParams['n'] = 2; // 额外生成2个
      apiParams['stream'] = false;

      final response = await _apiService.chat(
        apiKey: _apiKey!,
        apiParams: apiParams,
        messages: messages,
        cancelToken: CancelToken(),
      );

      final choices = response['choices'] as List?;
      if (choices == null || choices.length < 2) return;

      final existing = _candidates[aiMsgIndex] ?? [];
      for (int i = 1; i < choices.length; i++) {
        final content = choices[i]['message']?['content'] as String? ?? '';
        if (content.isNotEmpty && !existing.contains(content)) {
          existing.add(content);
        }
      }
      _candidates[aiMsgIndex] = existing;
      debugPrint('Swipe: 生成 ${existing.length} 个候选');
      notifyListeners();
    } catch (e) {
      debugPrint('Swipe 生成失败: $e');
    }
  }

  /// 构建上下文消息列表（含 World Info 和记忆注入）
  ///
  /// system 里只放整场对话保持不变的内容（角色卡 + 对话摘要），
  /// 每次请求都一致才能命中前缀缓存；World Info（按本轮输入匹配）与长期记忆
  /// （随对话增长）这些会变的内容追加到本轮用户消息末尾，
  /// 否则 system 一变，system 之后的所有历史消息都缓存失效。
  Future<List<Map<String, dynamic>>> _buildContextMessages() async {
    final char = _character!;
    final parts = <String>[char.buildSystemPrompt()];

    // 注入摘要（如果有）
    if (_summary != null && _summary!.isNotEmpty) {
      parts.add('[对话摘要]\n$_summary');
    }

    final result = <Map<String, dynamic>>[
      {'role': 'system', 'content': parts.join('\n\n')},
    ];

    result.addAll(
      _messages.map(
        (msg) => {
          'role': msg.isUser ? 'user' : 'assistant',
          'content': msg.content,
        },
      ),
    );

    // 本轮才变化的内容：匹配到的 World Info + 长期记忆，追加到最后一条用户消息末尾
    final dynamicParts = <String>[];
    if (_worldEntries.isNotEmpty) {
      final lastMsg = _messages.isNotEmpty ? _messages.last.content : '';
      final wiContent = WorldInfoService.matchContent(_worldEntries, lastMsg);
      if (wiContent.isNotEmpty) {
        dynamicParts.add(wiContent);
      }
    }
    if (_sessionId != null) {
      final memoryBlock = await MemoryService.buildMemoryBlock(_sessionId!);
      if (memoryBlock.isNotEmpty) {
        dynamicParts.add(memoryBlock);
      }
    }
    if (dynamicParts.isNotEmpty) {
      final lastUserIndex = result.lastIndexWhere((m) => m['role'] == 'user');
      if (lastUserIndex >= 0) {
        final last = result[lastUserIndex];
        last['content'] = '${last['content']}${dynamicParts.join()}';
      } else {
        // 没有用户消息（理论上不会发生）：退回 system 末尾，保证信息不丢
        result.first['content'] =
            '${result.first['content']}\n\n${dynamicParts.join()}';
      }
    }

    return result;
  }

  /// 检查是否需要摘要压缩
  Future<void> _checkSummary() async {
    if (_sessionId == null || _messages.length < _summaryThreshold) return;
    if (_summary != null) return; // 已摘要过

    // 取前 2/3 的消息做摘要
    final summarizeCount = (_messages.length * 2 ~/ 3);
    final toSummarize = _messages.sublist(0, summarizeCount);
    if (toSummarize.isEmpty) return;

    final text = toSummarize
        .map(
          (m) => '${m.isUser ? "用户" : _character?.name ?? "角色"}: ${m.content}',
        )
        .join('\n');

    // 简单截断式的摘要（不额外调用 API 节省 token）
    const maxChars = 2000;
    if (text.length > maxChars) {
      _summary = text.substring(0, maxChars) + '...(截断)';
    } else {
      _summary = text;
    }

    // 从消息列表中移除被摘要的消息
    _messages = _messages.sublist(summarizeCount);
    debugPrint('摘要: 压缩了 $summarizeCount 条消息');

    // 持久化摘要到会话记录
    if (_sessionId != null) {
      try {
        final db = await DatabaseHelper.database;
        await db.update(
          'character_chat_sessions',
          {'summary': _summary},
          where: 'id = ?',
          whereArgs: [_sessionId],
        );
      } catch (_) {}
    }

    notifyListeners();
  }

  /// 检查是否需要提取记忆
  Future<void> _checkMemoryExtraction() async {
    _messageCountSinceMemoryCheck++;
    if (_sessionId == null) return;
    if (_messageCountSinceMemoryCheck < _memoryCheckInterval) return;
    _messageCountSinceMemoryCheck = 0;

    // 从最近几条消息中提取关键信息
    final recent = _messages.length >= 6
        ? _messages.sublist(_messages.length - 6)
        : _messages;

    for (final msg in recent) {
      if (msg.isUser) continue;
      await _extractMemories(msg.content);
    }
  }

  /// 从 AI 回复中提取记忆
  Future<void> _extractMemories(String content) async {
    if (_sessionId == null) return;

    // 简单规则提取：含特定模式的行
    final patterns = [
      RegExp(r'(?:记住|别忘了|我是|我叫|我的名字是).{3,50}'),
      RegExp(r'(?:喜欢|讨厌|害怕|热爱|渴望).{3,30}'),
      RegExp(r'(?:曾经|过去|以前|那时).{5,50}'),
      RegExp(r'(?:约定|承诺|答应).{3,30}'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final text = match.group(0)!;
        // 去重：检查是否已存在相似记忆
        final existing = await MemoryService.getMemories(_sessionId!);
        final isDuplicate = existing.any(
          (m) => m.content.contains(text.substring(0, min(10, text.length))),
        );
        if (!isDuplicate) {
          await MemoryService.saveMemory(
            MemoryItem(
              sessionId: _sessionId!,
              content: text,
              importance: 2,
              createdAt: DateTime.now(),
            ),
          );
          debugPrint('记忆提取: $text');
        }
      }
    }
  }

  /// 添加世界书条目
  Future<void> addWorldEntry(
    String title,
    String content,
    List<String> keywords,
  ) async {
    if (_sessionId == null) return;
    final entry = WorldInfoEntry(
      sessionId: _sessionId!,
      title: title,
      content: content,
      keywords: keywords,
      createdAt: DateTime.now(),
    );
    final id = await WorldInfoService.createEntry(entry);
    _worldEntries = [
      ..._worldEntries,
      WorldInfoEntry(
        id: id,
        sessionId: _sessionId!,
        title: title,
        content: content,
        keywords: keywords,
        createdAt: DateTime.now(),
      ),
    ];
    notifyListeners();
  }

  /// 删除世界书条目
  Future<void> removeWorldEntry(int id) async {
    await WorldInfoService.deleteEntry(id);
    _worldEntries = _worldEntries.where((e) => e.id != id).toList();
    notifyListeners();
  }

  // ───────────────── 工具 ─────────────────

  void cancelRequest() {
    _cancelToken?.cancel();
    _isLoading = false;
    notifyListeners();
  }

  void reset() {
    cancelRequest();
    _character = null;
    _messages = [];
    _error = null;
    _apiKey = null;
    _sessionId = null;
    _candidates.clear();
    _candidateIndex.clear();
    _worldEntries = [];
    _summary = null;
    _messageCountSinceMemoryCheck = 0;
    notifyListeners();
  }

  Future<void> deleteSession(int id) async {
    try {
      await CharacterChatDbService.deleteSession(id);
      await MemoryService.deleteMemories(id);
      _sessions = await CharacterChatDbService.getAllSessions();
      if (_sessionId == id) {
        _sessionId = null;
        _character = null;
        _messages = [];
        _candidates.clear();
        _candidateIndex.clear();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('删除会话失败: $e');
    }
  }

  @override
  void dispose() {
    cancelRequest();
    super.dispose();
  }
}
