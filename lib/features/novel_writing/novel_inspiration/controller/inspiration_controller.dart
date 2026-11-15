// 小说灵感 — 页面状态与并发生成控制
//
// 一次请求并行生成 N 个推演（N = 设置里的「并发生成数量」）。
// 对话上下文只注入「已采用」的结果；未采用的推演保留为记录但不进入上下文。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/config/deepseek_models.dart';
import '../data/inspiration_db_helper.dart';
import '../../../chat/presentation/markdown_cleaner.dart';
import '../domain/inspiration_models.dart';
import '../service/inspiration_service.dart';

/// 正在流式生成的推演（内存态，完成后才落库）
class InspirationDraftBranch {
  InspirationDraftBranch(this.index);

  final int index;
  final StringBuffer buffer = StringBuffer();
  bool done = false;
  String? error;

  String get text => buffer.toString();
}

class InspirationController extends ChangeNotifier {
  final InspirationDbHelper _db;
  final NovelInspirationService _service;

  InspirationController({
    InspirationDbHelper? db,
    NovelInspirationService? service,
  }) : _db = db ?? InspirationDbHelper(),
       _service = service ?? NovelInspirationService();

  List<InspirationSession> sessions = [];
  InspirationSession? session;
  List<InspirationMessage> messages = [];
  List<InspirationCharacterCard> cards = [];
  List<InspirationChatMessage> chatMessages = [];
  InspirationSettings settings = const InspirationSettings();

  bool loading = true;
  bool generating = false;
  bool merging = false;
  bool chatGenerating = false;
  String chatStreamingText = '';
  String? errorText;

  String? draftInstruction;
  int? draftMessageId;
  List<InspirationDraftBranch> draftBranches = [];

  CancelToken? _cancelToken;
  CancelToken? _chatCancelToken;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasSession => session?.id != null;
  bool get hasDraft => draftBranches.isNotEmpty;
  bool get busy => generating || merging;

  String get displayTitle {
    final t = session?.title.trim() ?? '';
    return t.isEmpty ? '小说灵感' : t;
  }

  List<InspirationOutlineEvent> get selectedEvents =>
      session?.events ?? const <InspirationOutlineEvent>[];

  List<InspirationCharacterCard> get injectedCards =>
      cards.where((c) => c.inject && c.hasContent).toList(growable: false);

  int get effectiveConcurrency => settings.concurrency.clamp(1, 10);

  Future<void> init() async {
    loading = true;
    notifyListeners();
    try {
      await _loadSettings();
      sessions = await _db.listSessions();
      if (sessions.isNotEmpty) {
        await _openSessionInternal(sessions.first.id!);
      }
    } catch (e, st) {
      debugPrint('[inspiration] 初始化失败：$e\n$st');
      errorText = '读取灵感记录失败：$e';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    try {
      settings = await _db.getSettings();
    } catch (e) {
      debugPrint('[inspiration] 读取设置失败：$e');
      settings = const InspirationSettings();
    }
  }

  Future<void> refreshSessions() async {
    try {
      sessions = await _db.listSessions();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _openSessionInternal(int id) async {
    session = await _db.getSession(id);
    if (session == null) {
      messages = [];
      cards = [];
      chatMessages = [];
      return;
    }
    messages = await _db.listMessages(id);
    cards = await _db.listCards(id);
    chatMessages = await _db.listChatMessages(id);
  }

  Future<void> openSession(int id) async {
    if (busy) return;
    loading = true;
    errorText = null;
    notifyListeners();
    try {
      await _openSessionInternal(id);
    } catch (e, st) {
      debugPrint('[inspiration] 打开会话失败：$e\n$st');
      errorText = '打开会话失败：$e';
    }
    loading = false;
    notifyListeners();
  }

  /// 新建灵感会话：立即落库（左侧历史里会出现，可长按删除）。
  Future<void> newSession() async {
    if (busy) return;
    try {
      final now = DateTime.now().toIso8601String();
      final draft = InspirationSession(
        title: '新的灵感',
        createdAt: now,
        updatedAt: now,
      );
      final id = await _db.insertSession(draft);
      session = draft.copyWith(id: id);
      messages = [];
      cards = [];
      chatMessages = [];
      errorText = null;
      sessions = await _db.listSessions();
      notifyListeners();
    } catch (e, st) {
      debugPrint('[inspiration] 新建会话失败：$e\n$st');
      errorText = '新建灵感失败：$e';
      notifyListeners();
    }
  }

  Future<void> deleteSession(int id) async {
    try {
      await _db.deleteSession(id);
      sessions = await _db.listSessions();
      if (session?.id == id) {
        session = null;
        messages = [];
        cards = [];
        chatMessages = [];
        if (sessions.isNotEmpty) {
          await _openSessionInternal(sessions.first.id!);
        }
      }
      notifyListeners();
    } catch (e, st) {
      debugPrint('[inspiration] 删除会话失败：$e\n$st');
      errorText = '删除失败：$e';
      notifyListeners();
    }
  }

  Future<int> _ensureSession() async {
    final existing = session?.id;
    if (existing != null) return existing;
    final now = DateTime.now().toIso8601String();
    final draft = InspirationSession(
      title: '新的灵感',
      createdAt: now,
      updatedAt: now,
    );
    final id = await _db.insertSession(draft);
    session = draft.copyWith(id: id);
    sessions = await _db.listSessions();
    return id;
  }

  /// 发送一条指令：并行生成 N 个推演。
  Future<void> send(String instruction) async {
    final text = instruction.trim();
    if (text.isEmpty || busy) return;
    try {
      final sessionId = await _ensureSession();
      final messageId = await _db.insertMessage(sessionId, text);
      messages = [
        ...messages,
        InspirationMessage(
          id: messageId,
          sessionId: sessionId,
          content: text,
          createdAt: DateTime.now().toIso8601String(),
        ),
      ];
      // 第一条指令顺便当会话标题
      final currentTitle = session?.title.trim() ?? '';
      if (currentTitle.isEmpty || currentTitle == '新的灵感') {
        final title = text.length > 20 ? '${text.substring(0, 20)}…' : text;
        session = session?.copyWith(
          title: title,
          updatedAt: DateTime.now().toIso8601String(),
        );
        if (session != null) await _db.updateSession(session!);
        sessions = await _db.listSessions();
      }
      notifyListeners();
      await _generateForMessage(messageId, text);
    } catch (e, st) {
      debugPrint('[inspiration] 发送失败：$e\n$st');
      errorText = '生成失败：$e';
      generating = false;
      draftBranches = [];
      notifyListeners();
    }
  }

  /// 对已有的一轮重新生成 N 个推演（旧记录保留）。
  Future<void> regenerate(int messageId) async {
    if (busy) return;
    InspirationMessage? target;
    for (final m in messages) {
      if (m.id == messageId) target = m;
    }
    if (target == null) return;
    await _generateForMessage(messageId, target.content);
  }

  Future<List<({String instruction, String result})>> _historyBefore(
    int? messageId,
  ) async {
    final out = <({String instruction, String result})>[];
    for (final m in messages) {
      if (messageId != null && m.id == messageId) break;
      final chosen = m.branches
          .where((b) => b.chosen && b.content.trim().isNotEmpty)
          .map((b) => b.content.trim())
          .toList();
      if (chosen.isEmpty) continue;
      out.add((
        instruction: m.content,
        result: chosen.join('\n\n（另一版已采用结果）\n\n'),
      ));
    }
    return out;
  }

  /// 关闭思考 + 抬高输出上限的兜底参数：用于首轮 content 为空的重试。
  Map<String, dynamic> _directApiParams() {
    final base = _service.buildApiParams(settings);
    final rawMax = base['max_tokens'] as int? ?? settings.maxTokens;
    return {
      ...base,
      'max_tokens': rawMax < 8192 ? 8192 : rawMax,
      'thinking': {'type': 'disabled'},
    };
  }

  Future<void> _generateForMessage(int messageId, String instruction) async {
    generating = true;
    errorText = null;
    draftMessageId = messageId;
    draftInstruction = instruction;
    final count = effectiveConcurrency;
    draftBranches = List<InspirationDraftBranch>.generate(
      count,
      (i) => InspirationDraftBranch(i + 1),
    );
    _cancelToken = CancelToken();
    notifyListeners();

    try {
      final loaded = await _service.loadSettings();
      settings = loaded.settings;
      final history = await _historyBefore(messageId);
      final apiParams = _service.buildApiParams(settings);
      final futures = <Future<void>>[];
      for (var i = 0; i < count; i++) {
        final draft = draftBranches[i];
        final payload = NovelInspirationPromptTemplate.buildGenerateMessages(
          settings: settings,
          worldView: session?.worldView ?? '',
          theme: session?.theme ?? '',
          events: selectedEvents,
          cards: cards,
          history: history,
          instruction: instruction,
          variantIndex: i + 1,
          variantCount: count,
        );
        futures.add(
          _service
              .stream(
                apiKey: loaded.apiKey,
                apiParams: apiParams,
                messages: payload,
                cancelToken: _cancelToken,
                onContent: (chunk) {
                  draft.buffer.write(chunk);
                  _throttledNotify();
                },
                onDone: () {
                  draft.done = true;
                  notifyListeners();
                },
                onError: (error) {
                  draft.error = error;
                  draft.done = true;
                  errorText ??= '生成失败：$error';
                  notifyListeners();
                },
              )
              .catchError((Object e) {
                draft.error = e.toString();
                draft.done = true;
                notifyListeners();
              }),
        );
      }
      await Future.wait(futures);
      // 复杂指令下模型可能把输出预算全用在思考上（content 为空）。此时用
      // 「关闭思考 + 加大输出上限」对空结果各重试一次，避免整轮推演白跑。
      if (settings.enableThinking) {
        final empty = draftBranches
            .where((d) => d.text.trim().isEmpty)
            .toList();
        if (empty.isNotEmpty) {
          await Future.wait(
            empty.map((draft) async {
              draft.buffer.clear();
              draft.done = false;
              draft.error = null;
              final payload =
                  NovelInspirationPromptTemplate.buildGenerateMessages(
                    settings: settings,
                    worldView: session?.worldView ?? '',
                    theme: session?.theme ?? '',
                    events: selectedEvents,
                    cards: cards,
                    history: history,
                    instruction: instruction,
                    variantIndex: draft.index,
                    variantCount: count,
                  );
              try {
                await _service.stream(
                  apiKey: loaded.apiKey,
                  apiParams: _directApiParams(),
                  messages: payload,
                  cancelToken: _cancelToken,
                  onContent: (chunk) {
                    draft.buffer.write(chunk);
                    _throttledNotify();
                  },
                  onDone: () {
                    draft.done = true;
                    notifyListeners();
                  },
                  onError: (error) {
                    draft.error = error;
                    draft.done = true;
                    notifyListeners();
                  },
                );
              } catch (e) {
                draft.error = e.toString();
                draft.done = true;
              }
              if (draft.text.trim().isEmpty && draft.error == null) {
                draft.error = '模型没有返回正文';
              }
              notifyListeners();
            }),
          );
        }
      }
      if (draftBranches.every((d) => d.text.trim().isEmpty)) {
        errorText = '本轮没有生成任何正文，请重试（可在设置里关闭思考模式或调大最大生成长度）';
      }
      await _persistDrafts(messageId);
    } catch (e, st) {
      debugPrint('[inspiration] 生成失败：$e\n$st');
      errorText = '生成失败：$e';
    } finally {
      generating = false;
      draftBranches = [];
      draftInstruction = null;
      draftMessageId = null;
      _cancelToken = null;
      await _reloadMessages();
      notifyListeners();
    }
  }

  Future<void> _persistDrafts(int messageId) async {
    final sessionId = session?.id;
    if (sessionId == null) return;
    final generationNo = (await _db.maxGenerationNo(messageId)) + 1;
    for (final d in draftBranches) {
      // 生成结果统一去掉 Markdown 标记，避免气泡/导出/朗读里出现 **、##、代码块围栏。
      final content = stripMarkdownForChat(d.text.trim());
      if (content.isEmpty) continue;
      await _db.insertBranch(
        InspirationBranch(
          sessionId: sessionId,
          messageId: messageId,
          content: content,
          generationNo: generationNo,
        ),
      );
    }
    // 重新读取消息，再决定采用哪一条
    await _reloadMessages();
    final target = messages.where((m) => m.id == messageId).firstOrNull;
    if (target == null) return;
    if (target.chosenBranch == null && target.branches.isNotEmpty) {
      await _db.setChosen(messageId, target.branches.first.id);
    }
    await _db.touchSession(sessionId);
    sessions = await _db.listSessions();
  }

  Future<void> _reloadMessages() async {
    final id = session?.id;
    if (id == null) {
      messages = [];
      return;
    }
    messages = await _db.listMessages(id);
    cards = await _db.listCards(id);
  }

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      await _loadSettings();
      if (session?.id != null) {
        session = await _db.getSession(session!.id!);
        await _reloadMessages();
      }
      sessions = await _db.listSessions();
    } catch (_) {}
    loading = false;
    notifyListeners();
  }

  void cancelGeneration() {
    _cancelToken?.cancel('用户取消');
  }

  void cancelChat() {
    _chatCancelToken?.cancel('用户取消');
  }

  List<String> _deductionResults() {
    final out = <String>[];
    for (final m in messages) {
      final chosen = m.chosenBranch;
      if (chosen != null && chosen.content.trim().isNotEmpty) {
        out.add(chosen.content.trim());
      }
    }
    return out;
  }

  /// 对话模式：单 AI 流式对话，注入对话历史 + 已采用推演结果，不做并行推演。
  Future<void> sendChat(String instruction) async {
    final text = instruction.trim();
    if (text.isEmpty || chatGenerating) return;
    try {
      final sessionId = await _ensureSession();
      final history = List<InspirationChatMessage>.of(chatMessages);
      final userId = await _db.insertChatMessage(
        sessionId: sessionId,
        role: 'user',
        content: text,
      );
      final currentTitle = session?.title.trim() ?? '';
      if (currentTitle.isEmpty || currentTitle == '新的灵感') {
        final title = text.length > 20 ? '${text.substring(0, 20)}…' : text;
        session = session?.copyWith(
          title: title,
          updatedAt: DateTime.now().toIso8601String(),
        );
        if (session != null) await _db.updateSession(session!);
        sessions = await _db.listSessions();
      }
      chatMessages = [
        ...chatMessages,
        InspirationChatMessage(
          id: userId,
          sessionId: sessionId,
          role: 'user',
          content: text,
          createdAt: DateTime.now().toIso8601String(),
        ),
      ];
      chatGenerating = true;
      chatStreamingText = '';
      errorText = null;
      _chatCancelToken = CancelToken();
      notifyListeners();

      final loaded = await _service.loadSettings();
      settings = loaded.settings;
      final payload = NovelInspirationPromptTemplate.buildChatMessages(
        settings: settings,
        worldView: session?.worldView ?? '',
        theme: session?.theme ?? '',
        events: selectedEvents,
        cards: cards,
        deductionResults: _deductionResults(),
        history: history,
        userText: text,
      );
      final buffer = StringBuffer();
      await _service.stream(
        apiKey: loaded.apiKey,
        apiParams: _directApiParams(),
        messages: payload,
        cancelToken: _chatCancelToken,
        onContent: (chunk) {
          buffer.write(chunk);
          chatStreamingText = buffer.toString();
          _throttledNotify();
        },
        onDone: () {},
        onError: (error) {
          errorText = '对话生成失败：$error';
        },
      );
      final content = stripMarkdownForChat(buffer.toString().trim());
      if (content.isNotEmpty) {
        await _db.insertChatMessage(
          sessionId: sessionId,
          role: 'assistant',
          content: content,
        );
      }
      await _db.touchSession(sessionId);
      sessions = await _db.listSessions();
    } catch (e, st) {
      debugPrint('[inspiration] 对话模式生成失败：$e\n$st');
      errorText = '对话生成失败：$e';
    } finally {
      chatGenerating = false;
      chatStreamingText = '';
      _chatCancelToken = null;
      final id = session?.id;
      if (id != null) {
        try {
          chatMessages = await _db.listChatMessages(id);
        } catch (_) {}
      }
      notifyListeners();
    }
  }

  Future<void> setChosen(int messageId, int branchId) async {
    await _db.setChosen(messageId, branchId);
    await _reloadMessages();
    notifyListeners();
  }

  Future<void> updateBranchContent(int branchId, String content) async {
    await _db.updateBranchContent(branchId, content);
    await _reloadMessages();
    notifyListeners();
  }

  Future<void> deleteBranch(int branchId) async {
    int? messageId;
    for (final m in messages) {
      if (m.branches.any((b) => b.id == branchId)) {
        messageId = m.id;
        break;
      }
    }
    await _db.deleteBranch(branchId);
    await _reloadMessages();
    // 删掉的如果是采用项，自动采用第一条，避免后续对话上下文断掉
    if (messageId != null) {
      final m = messages.where((item) => item.id == messageId).firstOrNull;
      if (m != null && m.chosenBranch == null && m.branches.isNotEmpty) {
        await _db.setChosen(messageId, m.branches.first.id);
        await _reloadMessages();
      }
    }
    notifyListeners();
  }

  Future<void> deleteMessage(int messageId) async {
    await _db.deleteMessage(messageId);
    await _reloadMessages();
    notifyListeners();
  }

  /// 长按对话「修改指令」：保存后不自动重生成，用户可再点重新生成。
  /// 修改对话：记录编辑前指令 / 采用结果，保存新指令，并从本轮重新生成；
  /// 之前的对话上下文只使用已采用结果，保证上文一致。
  Future<void> editMessageAndRegenerate(int messageId, String content) async {
    if (busy) return;
    final text = content.trim();
    if (text.isEmpty) return;
    final target = messages.where((m) => m.id == messageId).firstOrNull;
    if (target == null) return;
    final revision = InspirationMessageRevision(
      instruction: target.content,
      result: target.chosenBranch?.content ?? '',
      createdAt: DateTime.now().toIso8601String(),
    );
    final revisions = [...target.revisions, revision];
    await _db.updateMessageEdit(messageId, text, revisions);
    await _reloadMessages();
    notifyListeners();
    await _generateForMessage(messageId, text);
    await _reloadMessages();
    final updated = messages.where((m) => m.id == messageId).firstOrNull;
    final latest = updated?.branches.lastOrNull;
    if (latest?.id != null) {
      await _db.setChosen(messageId, latest!.id);
      await _reloadMessages();
    }
    notifyListeners();
  }

  /// 把同一轮里选中的多个推演合并成一个完整情节。
  /// [requirement] 为可选的合并要求；返回是否成功产出并保存了合并结果。
  Future<bool> mergeBranches(
    int messageId,
    List<int> branchIds, {
    String requirement = '',
  }) async {
    if (busy) return false;
    final message = messages.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return false;
    final branches = message.branches
        .where((b) => branchIds.contains(b.id) && b.content.trim().isNotEmpty)
        .toList();
    if (branches.length < 2) return false;

    var saved = false;
    merging = true;
    errorText = null;
    draftMessageId = messageId;
    draftInstruction = '合并推演';
    draftBranches = [InspirationDraftBranch(1)];
    _cancelToken = CancelToken();
    notifyListeners();
    try {
      final loaded = await _service.loadSettings();
      settings = loaded.settings;
      final history = await _historyBefore(messageId);
      final payload = NovelInspirationPromptTemplate.buildMergeMessages(
        settings: settings,
        worldView: session?.worldView ?? '',
        theme: session?.theme ?? '',
        events: selectedEvents,
        cards: cards,
        history: history,
        instruction: message.content,
        branches: branches.map((b) => b.content).toList(),
        mergeRequirement: requirement,
      );
      final draft = draftBranches.first;
      Future<void> runMergeStream(Map<String, dynamic> apiParams) {
        return _service.stream(
          apiKey: loaded.apiKey,
          apiParams: apiParams,
          messages: payload,
          cancelToken: _cancelToken,
          onContent: (chunk) {
            draft.buffer.write(chunk);
            _throttledNotify();
          },
          onDone: () {
            draft.done = true;
            notifyListeners();
          },
          onError: (error) {
            draft.error = error;
            errorText = '合并失败：$error';
            draft.done = true;
            notifyListeners();
          },
        );
      }

      await runMergeStream(_directApiParams());
      var content = draft.text.trim();
      // 合并是「整理既有内容」的任务：直接关闭思考，避免 4096 输出预算被
      // reasoning 全部吃掉（实测思考可占用全部 tokens，正文为空）。
      if (content.isEmpty) {
        draft.buffer.clear();
        draft.done = false;
        draft.error = null;
        errorText = null;
        notifyListeners();
        await runMergeStream(_directApiParams());
        content = stripMarkdownForChat(draft.text.trim());
      }
      final sessionId = session?.id;
      if (content.isEmpty) {
        errorText = '合并失败：模型没有返回正文，可尝试调大最大生成长度后重试';
      }
      if (content.isNotEmpty && sessionId != null) {
        final generationNo = (await _db.maxGenerationNo(messageId)) + 1;
        await _db.insertBranch(
          InspirationBranch(
            sessionId: sessionId,
            messageId: messageId,
            content: content,
            kind: 'merge',
            generationNo: generationNo,
            sourceIds: branchIds,
          ),
        );
        await _reloadMessages();
        final target = messages.where((m) => m.id == messageId).firstOrNull;
        final merged = target?.branches.lastOrNull;
        if (target != null && merged?.id != null) {
          await _db.setChosen(messageId, merged!.id);
        }
        saved = true;
      }
    } catch (e, st) {
      debugPrint('[inspiration] 合并失败：$e\n$st');
      errorText = '合并失败：$e';
    } finally {
      merging = false;
      draftBranches = [];
      draftInstruction = null;
      draftMessageId = null;
      _cancelToken = null;
      await _reloadMessages();
      notifyListeners();
    }
    return saved;
  }

  /// 人物卡「AI 生成当前状态」：通过选中注入的大纲事件推演。
  Future<String> generateCardStatus(InspirationCharacterCard card) async {
    final loaded = await _service.loadSettings();
    settings = loaded.settings;
    final messagesPayload =
        NovelInspirationPromptTemplate.buildCardStatusMessages(
          worldView: session?.worldView ?? '',
          theme: session?.theme ?? '',
          card: card,
          events: selectedEvents,
        );
    final text = await _service.complete(
      apiKey: loaded.apiKey,
      apiParams: _directApiParams(),
      messages: messagesPayload,
    );
    return text;
  }

  Future<void> saveCard(InspirationCharacterCard card) async {
    final sessionId = session?.id;
    if (sessionId == null) return;
    if (card.id == null) {
      await _db.insertCard(card.copyWith());
    } else {
      await _db.updateCard(card);
    }
    cards = await _db.listCards(sessionId);
    notifyListeners();
  }

  Future<void> deleteCard(int id) async {
    await _db.deleteCard(id);
    final sessionId = session?.id;
    if (sessionId != null) cards = await _db.listCards(sessionId);
    notifyListeners();
  }

  Future<void> saveOutlineSelection({
    required int outlineRecordId,
    required String outlineTitle,
    required List<InspirationOutlineEvent> events,
  }) async {
    final sessionId = await _ensureSession();
    session = session?.copyWith(
      outlineRecordId: outlineRecordId,
      outlineTitle: outlineTitle,
      events: events,
      updatedAt: DateTime.now().toIso8601String(),
    );
    if (session != null) await _db.updateSession(session!);
    sessions = await _db.listSessions();
    notifyListeners();
    // 触发一次读取，确保 session.id 存在
    if (session?.id == null) {
      session = session?.copyWith(id: sessionId);
    }
  }

  Future<void> clearOutlineSelection() async {
    session = session?.copyWith(clearOutline: true);
    if (session?.id != null) await _db.updateSession(session!);
    sessions = await _db.listSessions();
    notifyListeners();
  }

  Future<void> saveWorldTheme({
    required String worldView,
    required String theme,
  }) async {
    await _ensureSession();
    session = session?.copyWith(
      worldView: worldView.trim(),
      theme: theme.trim(),
      updatedAt: DateTime.now().toIso8601String(),
    );
    if (session?.id != null) await _db.updateSession(session!);
    sessions = await _db.listSessions();
    notifyListeners();
  }

  /// 对推演正文里选中的段落做 AI 改写，返回替换文本。
  Future<String> rewriteSegment({
    required String fullText,
    required String selectedText,
    required String instruction,
  }) async {
    final loaded = await _service.loadSettings();
    settings = loaded.settings;
    final payload = NovelInspirationPromptTemplate.buildSegmentMessages(
      settings: settings,
      fullText: fullText,
      selectedText: selectedText,
      instruction: instruction,
    );
    final rewritten = await _service.complete(
      apiKey: loaded.apiKey,
      apiParams: _directApiParams(),
      messages: payload,
    );
    return rewritten;
  }

  /// 对话式段落改写：可带多轮历史要求，返回最新改写结果。
  Future<String> rewriteSegmentChat({
    required String fullText,
    required String selectedText,
    required List<({String instruction, String result})> turns,
    required String instruction,
  }) async {
    final loaded = await _service.loadSettings();
    settings = loaded.settings;
    final payload = NovelInspirationPromptTemplate.buildSegmentChatMessages(
      settings: settings,
      fullText: fullText,
      selectedText: selectedText,
      turns: turns,
      instruction: instruction,
    );
    return _service.complete(
      apiKey: loaded.apiKey,
      apiParams: _directApiParams(),
      messages: payload,
    );
  }

  Future<void> saveSettings(InspirationSettings next) async {
    await _db.saveSettings(next);
    settings = next;
    notifyListeners();
  }

  void clearError() {
    errorText = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('页面关闭');
    _chatCancelToken?.cancel('页面关闭');
    super.dispose();
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 80) return;
    _lastNotify = now;
    notifyListeners();
  }

  /// 供设置页展示的模型名 → 真实 id
  String get modelId => DeepSeekModels.toApiId(settings.model);
}
