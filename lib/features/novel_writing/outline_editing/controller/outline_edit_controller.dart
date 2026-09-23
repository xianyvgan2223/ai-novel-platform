import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../shared/data/outline_chapter_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/outline_text_sync.dart';
import '../model/outline_edit_chat_message.dart';
import '../model/outline_edit_draft.dart';
import '../service/outline_edit_service.dart';

/// 「大纲编辑」控制器。
///
/// 负责：
/// - 多章草稿（每章一份 OutlineEditDraft，切换章节不丢未保存内容）
/// - 保存：写回 outline_chapters 表，并把标题/概要改动同步回大纲正文文本
/// - AI 对话：把「小说设定 + 当前章节最新内容 + 对话历史」交给模型流式生成，
///   生成结果由界面插入 / 追加 / 替换到当前章节
class OutlineEditController extends ChangeNotifier {
  final OutlineRecord outline;
  final OutlineEditService _service;

  OutlineEditController(this.outline, {OutlineEditService? service})
    : outlineContent = outline.content,
      _service = service ?? OutlineEditService();

  /// 参与编辑的章节草稿（顺序与章节事件序号一致）
  final List<OutlineEditDraft> drafts = [];

  /// 当前正在编辑的草稿下标
  int activeIndex = 0;

  bool saving = false;
  String saveError = '';

  /// 大纲正文（标题/概要改动会合并写回其中并持久化）
  String outlineContent;

  /// 从记录中读取的最新伏笔清单 / 剧情账本（AI 上下文用）
  String foreshadows = '';
  String storyState = '';

  /// AI 对话消息（含流式中的占位助手消息）
  final List<OutlineEditChatMessage> messages = [];
  bool chatting = false;
  String chatError = '';

  CancelToken? _cancelToken;
  bool _cancelled = false;
  bool _disposed = false;
  // 对话轮次号：新一轮对话/主动停止会让旧轮次的回调失效，
  // 避免旧请求的收尾代码清掉新一轮的生成状态
  int _chatSeq = 0;

  OutlineEditDraft? get activeDraft =>
      activeIndex >= 0 && activeIndex < drafts.length
      ? drafts[activeIndex]
      : null;

  int get dirtyCount => drafts.where((d) => d.isDirty).length;

  bool get hasUnsaved => dirtyCount > 0;

  /// 载入待编辑章节（仅内存，不落库）
  void init(List<OutlineChapter> chapters) {
    for (final c in chapters) {
      if (c.id == null) continue;
      drafts.add(OutlineEditDraft(c)..onChanged = _safeNotify);
    }
    _loadFreshRecord();
  }

  /// 读取记录中的最新伏笔清单 / 账本：进入页面时传入的 OutlineRecord
  /// 可能是列表页加载时的快照，期间章节生成可能已更新这些字段
  Future<void> _loadFreshRecord() async {
    if (outline.id == null) return;
    try {
      final row = await OutlineRecordDbHelper().getById(outline.id!);
      if (row == null) return;
      foreshadows = row['foreshadows'] as String? ?? '';
      storyState = row['story_state'] as String? ?? '';
      final content = row['content'] as String? ?? '';
      if (content.isNotEmpty) outlineContent = content;
      _safeNotify();
    } catch (_) {
      // 读取失败不影响编辑，沿用进入页面时的快照
    }
  }

  void setActive(int index) {
    if (index < 0 || index >= drafts.length || index == activeIndex) return;
    activeIndex = index;
    _safeNotify();
  }

  /// 保存所有有改动的章节，返回实际保存的章节数
  Future<int> saveAll() async {
    if (saving) return 0;
    final dirty = drafts.where((d) => d.isDirty).toList();
    if (dirty.isEmpty) return 0;
    saving = true;
    saveError = '';
    _safeNotify();
    int saved = 0;
    try {
      for (final d in dirty) {
        final newTitle = d.titleCtrl.text.trim();
        final newSummary = d.summaryCtrl.text.trim();
        await OutlineChapterDbHelper().updateFull(
          d.chapterId,
          eventTitle: newTitle,
          eventSummary: newSummary,
          content: d.contentCtrl.text,
        );
        // 标题/概要改动同步回大纲正文：否则「大纲转章节」下次进入时会按
        // 大纲文本重解析，把手改的标题/概要吃回旧值
        if (newTitle != d.savedTitle || newSummary != d.savedSummary) {
          outlineContent = mergeEventIntoOutlineText(
            outlineContent,
            oldTitle: d.savedTitle,
            newTitle: newTitle,
            newSummary: newSummary,
          );
        }
        d.markSaved();
        saved++;
      }
      await _persistOutlineContent();
    } catch (e) {
      saveError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      saving = false;
      _safeNotify();
    }
    return saved;
  }

  /// 把合并后的大纲正文写回记录（其余设定字段原样回写，避免列被清空）
  Future<void> _persistOutlineContent() async {
    if (outline.id == null) return;
    await OutlineRecordDbHelper().update(outline.id!, {
      'content': outlineContent,
      'title': outline.title,
      'genre': outline.genre,
      'theme': outline.theme,
      'protagonist': outline.protagonist,
      'worldview': outline.worldview,
    });
  }

  /// 发送一条对话：把当前章节最新内容作为上下文交给 AI，流式展示结果
  Future<void> sendChat(String input) async {
    final text = input.trim();
    if (text.isEmpty || chatting) return;
    final draft = activeDraft;
    if (draft == null) {
      chatError = '没有可编辑的章节';
      _safeNotify();
      return;
    }
    final settings = await _service.loadSettings();
    if (_disposed) return;
    if (settings.apiKey.isEmpty) {
      chatError = '请先在设置中填写 API Key';
      _safeNotify();
      return;
    }

    final userMsg = OutlineEditChatMessage.user(text);
    final assistant = OutlineEditChatMessage.assistant()..streaming = true;
    messages.add(userMsg);
    messages.add(assistant);
    final int seq = ++_chatSeq;
    chatting = true;
    chatError = '';
    _cancelled = false;
    _cancelToken = CancelToken();
    _safeNotify();

    final requestMessages = _service.buildChatMessages(
      outline: outline,
      eventTitle: draft.titleCtrl.text.trim(),
      eventSummary: draft.summaryCtrl.text.trim(),
      isMajor: draft.isMajor,
      userInput: text,
      // 历史不含刚插入的占位助手消息
      history: messages.sublist(0, messages.length - 1),
      parentMajor: _parentMajorText(draft),
      prevSummary: _prevSummaryText(draft),
      storyState: _storyStateText(draft),
      foreshadows: foreshadows,
      chapterContent: draft.contentCtrl.text,
      rolePrompt: settings.chapterSetting.chapterSystemPrompt,
    );
    final apiParams = <String, dynamic>{
      'model': settings.chapterSetting.model,
      'temperature': settings.chapterSetting.temperature,
      'max_tokens': settings.chapterSetting.maxTokens,
      // 与章节生成保持一致：关闭深度思考时显式禁用，避免思考抢占输出预算
      if (!settings.chapterSetting.enableThinking)
        'thinking': {'type': 'disabled'},
    };

    try {
      await _service.streamChat(
        apiKey: settings.apiKey,
        apiParams: apiParams,
        messages: requestMessages,
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          if (seq != _chatSeq) return;
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;
          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty) assistant.content += content;
          final reasoning = delta['reasoning_content'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) {
            assistant.thinking += reasoning;
          }
          _safeNotify();
        },
        onDone: () {},
        onError: (msg) {
          if (seq == _chatSeq && chatError.isEmpty) chatError = msg;
        },
      );
    } catch (e) {
      if (seq == _chatSeq && chatError.isEmpty) {
        chatError = e.toString().replaceFirst('Exception: ', '');
      }
    }

    // 流式不可用或没有输出时回退一次非流式请求（与章节链路一致的兜底）
    if (seq == _chatSeq && !_cancelled && assistant.content.trim().isEmpty) {
      try {
        final fallback = await _service.chatOnce(
          apiKey: settings.apiKey,
          apiParams: apiParams,
          messages: requestMessages,
        );
        if (fallback.isNotEmpty) assistant.content = fallback;
      } catch (_) {
        // 兜底失败：交给下方统一提示
      }
    }

    if (seq != _chatSeq) return; // 已被新一轮对话/停止接管
    assistant.streaming = false;
    chatting = false;
    _cancelToken = null;
    if (assistant.content.trim().isEmpty && chatError.isEmpty && !_cancelled) {
      chatError = '未获取到内容，请重试';
    }
    _safeNotify();
  }

  /// 停止当前生成（保留已生成的部分内容）
  void stopChat() {
    if (!chatting) return;
    _cancelled = true;
    _chatSeq++; // 让旧轮次的回调与收尾全部失效
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final m in messages) {
      m.streaming = false;
    }
    chatting = false;
    _safeNotify();
  }

  /// 清空对话记录（生成中不可清空）
  void clearChat() {
    if (chatting) return;
    messages.clear();
    chatError = '';
    _safeNotify();
  }

  /// 所属大事件（标题 + 概要），无则返回空串
  String _parentMajorText(OutlineEditDraft draft) {
    OutlineEditDraft? parent;
    for (final d in drafts) {
      if (d.eventIndex >= draft.eventIndex) break;
      if (d.isMajor) parent = d;
    }
    if (parent == null) return '';
    final title = parent.titleCtrl.text.trim();
    final summary = parent.summaryCtrl.text.trim();
    return summary.isEmpty ? title : '$title\n$summary';
  }

  /// 上一章小结：优先 AI 提炼的小结，缺失时回退正文末尾片段
  String _prevSummaryText(OutlineEditDraft draft) {
    OutlineEditDraft? prev;
    for (final d in drafts) {
      if (d.eventIndex >= draft.eventIndex) break;
      prev = d;
    }
    if (prev == null) return '';
    final aiSummary = prev.chapter.aiSummary.trim();
    if (aiSummary.isNotEmpty) return aiSummary;
    final content = prev.contentCtrl.text.trim();
    if (content.isEmpty) return '';
    return content.length > 300
        ? content.substring(content.length - 300)
        : content;
  }

  /// 全局剧情状态：优先当前章节之前最近一章保存的账本，其次记录中的账本
  String _storyStateText(OutlineEditDraft draft) {
    OutlineEditDraft? prev;
    for (final d in drafts) {
      if (d.eventIndex >= draft.eventIndex) break;
      prev = d;
    }
    final prevState = prev?.chapter.storyState.trim() ?? '';
    return prevState.isNotEmpty ? prevState : storyState;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _chatSeq++;
    _cancelToken?.cancel();
    _cancelToken = null;
    for (final d in drafts) {
      d.dispose();
    }
    drafts.clear();
    super.dispose();
  }
}
