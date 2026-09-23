import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/chapter_write_service.dart';
import '../../outline_format/service/outline_format_service.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/character_profile.dart';
import '../../shared/data/outline_chapter_db_helper.dart';
import '../../shared/data/outline_record_db_helper.dart';
import '../../shared/outline_event_parser.dart';
import '../../shared/outline_text_sync.dart';

/// 章节写作控制器
class ChapterWriteController {
  final OutlineRecord outline;
  final ChapterWriteService _service;

  /// 大纲文本内容（可变，与 DB 同步后更新）
  String outlineContent;

  ChapterWriteController(this.outline, {ChapterWriteService? service})
    : _service = service ?? ChapterWriteService(),
      outlineContent = outline.content;

  List<OutlineChapter> chapters = [];
  bool isLoading = true;
  bool isWriting = false;
  int? writingId;
  String writingText = '';
  String thinkingText = ''; // 当前生成的思考过程（reasoning_content，跨轮累积，供全屏视图展示）
  bool reviewing = false; // 生成完成后的 AI 审查修正阶段（供 UI 展示审查中状态）
  String reviewText = ''; // AI 审查意见输出（流式累积，供全屏视图气泡展示）
  String reviewBefore = ''; // 审查对比：修改前正文（原版）
  String reviewAfter = ''; // 审查对比：修改后正文（修正版）
  String storyStateText = ''; // 剧情状态账本提炼输出（流式累积，供全屏视图气泡展示）
  bool extractingStory = false; // 账本提炼阶段（供 UI 展示提炼中状态）
  String protagonistText = ''; // 主角人物档案提炼输出（流式累积，供全屏视图气泡展示）
  bool extractingProtagonist = false; // 主角档案提炼阶段（供 UI 展示提炼中状态）
  String protagonistThinking = ''; // 主角档案提炼的思考过程（独立气泡展示）
  String reviewThinking = ''; // 章节审查的思考过程（独立气泡展示，位于正文下方）
  String storyStateThinking = ''; // 账本提炼的思考过程（独立气泡展示）
  bool reviewingProtagonist = false; // 主角档案审查阶段（独立于章节审查的 UI 状态）
  String protagonistReviewText = ''; // 主角档案审查意见（独立气泡，位于主角区，区别于章节审查）
  String protagonistReviewThinking = ''; // 档案审查思考过程（独立气泡展示）
  String errorText = ''; // 最近一次生成失败的错误信息（写视图错误气泡展示，避免静默失败）
  bool isRefreshingForeshadows = false; // 伏笔清单后台提炼中（账本页/章节页显示加载提示）
  String foreshadowThinkingText = ''; // 伏笔提炼 AI 思考过程（流式累积，供详情页实时展示）
  String foreshadowOutputText = ''; // 伏笔提炼 AI 输出（流式累积）
  bool summarizingChapter = false; // 整章小结提炼中（编辑保存时可见）
  String chapterSummaryThinkingText = ''; // 小结 AI 思考（流式累积）
  String chapterSummaryOutputText = ''; // 小结输出（流式累积）
  int? processingChapterId; // 编辑保存后正在提炼账本/小结的章节 id（列表加载显示、编辑/查看续显进度）

  /// 指定章节是否正在后台提炼（账本或小结阶段）
  bool isProcessingChapter(OutlineChapter ch) =>
      processingChapterId != null &&
      processingChapterId == ch.id &&
      (extractingStory || summarizingChapter);
  CancelToken? _cancelToken;
  bool _cancelled = false;

  // 大事件不可写，仅小事件作为章节生成正文
  bool get isAllCompleted {
    final writable = chapters.where((c) => c.eventType == 'minor');
    return writable.isNotEmpty &&
        writable.every((c) => c.status == 'completed');
  }

  int get completedCount =>
      chapters.where((c) => c.status == 'completed').length;

  /// 可写章节数（仅小事件，大事件不计入进度分母）
  int get writableCount => chapters.where((c) => c.eventType == 'minor').length;

  bool needsResync = false;

  /// 最近一次生成是否被用户主动停止（用于 UI 区分「已完成/已停止」）
  bool get wasCancelled => _cancelled;

  /// 重新从大纲内容解析事件并更新数据库（保留已完成的正文内容）
  ///
  /// [previousChapters] 重同步前的旧章节（含已生成正文）。调用方必须传入：
  /// 页面加载时若从空的 [chapters] 字段取旧数据，已完成内容将全部丢失。
  /// 匹配策略：先按标题精确匹配（内容随标题保留）；标题对不上（事件被改名）时
  /// 按序号兜底匹配，避免改名/重排导致正文被误删。
  Future<void> resync({List<OutlineChapter>? previousChapters}) async {
    needsResync = false;
    final oldChapters = previousChapters ?? chapters;
    final oldByTitle = Map.fromEntries(
      oldChapters.map((c) => MapEntry(c.eventTitle, c)),
    );
    final newChapters = parseOutlineEvents(
      outlineContent,
      outlineId: outline.id!,
    );
    final matchedIndexes = <int>{}; // 已被标题匹配占用的旧序号，序号兜底时跳过
    for (int i = 0; i < newChapters.length; i++) {
      final byTitle = oldByTitle[newChapters[i].eventTitle];
      if (byTitle != null &&
          byTitle.status == 'completed' &&
          byTitle.content.isNotEmpty) {
        final oldIdx = oldChapters.indexOf(byTitle);
        if (oldIdx >= 0) matchedIndexes.add(oldIdx);
        newChapters[i] = newChapters[i].copyWith(
          content: byTitle.content,
          status: 'completed',
          aiSummary: byTitle.aiSummary,
          storyState: byTitle.storyState,
        );
      }
    }
    // 标题未匹配到的（改名/新增事件）：若同一序号位置的旧章节已完成且有正文，
    // 且该旧章节尚未被其他新章节以标题匹配占用，则按序号继承内容
    for (int i = 0; i < newChapters.length; i++) {
      if (newChapters[i].status == 'completed') continue;
      if (matchedIndexes.contains(i)) continue;
      if (i >= oldChapters.length) break;
      final byIndex = oldChapters[i];
      if (byIndex.status == 'completed' && byIndex.content.isNotEmpty) {
        matchedIndexes.add(i);
        newChapters[i] = newChapters[i].copyWith(
          content: byIndex.content,
          status: 'completed',
          aiSummary: byIndex.aiSummary,
          storyState: byIndex.storyState,
        );
      }
    }
    await OutlineChapterDbHelper().deleteByOutlineId(outline.id!);
    await OutlineChapterDbHelper().batchInsert(
      newChapters.map((c) => c.toMap()).toList(),
    );
    await _reloadChapters();
  }

  /// 将章节标题/概要的修改同步到大纲记录文本中
  Future<void> syncEventToOutline(
    OutlineChapter oldCh,
    String newTitle,
    String newSummary,
  ) async {
    if (outline.id == null) return;
    // 文本合并规则与「大纲编辑」共用（shared/outline_text_sync.dart），
    // 保证两个入口改标题/概要后的写回结果一致
    outlineContent = mergeEventIntoOutlineText(
      outlineContent,
      oldTitle: oldCh.eventTitle,
      newTitle: newTitle,
      newSummary: newSummary,
    );
    await OutlineRecordDbHelper().update(outline.id!, {
      'content': outlineContent,
      'title': outline.title,
      'genre': outline.genre,
      'theme': outline.theme,
      'protagonist': outline.protagonist,
      'worldview': outline.worldview,
    });
  }

  Future<void> initLoad() async {
    isLoading = true;
    try {
      final rows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      if (rows.isNotEmpty) {
        // 以最新大纲内容为准重新解析，与 DB 中的旧数据比较。
        // 标题/序号之外还要比较事件类型与概要：历史详情页就地编辑大纲
        // 常只改事件概要（标题不变），若只按标题比较会漏判，章节卡片
        // 会一直显示旧概要
        final freshChapters = parseOutlineEvents(
          outlineContent,
          outlineId: outline.id!,
        );
        final dirty =
            freshChapters.length != rows.length ||
            freshChapters.asMap().entries.any((entry) {
              final c = OutlineChapter.fromMap(rows[entry.key]);
              return c.eventTitle != entry.value.eventTitle ||
                  c.eventIndex != entry.value.eventIndex ||
                  c.eventType != entry.value.eventType ||
                  c.eventSummary != entry.value.eventSummary;
            });
        if (dirty) {
          // 大纲已更新：自动重同步章节结构（保留已完成的正文内容），
          // 确保事件列表始终与大纲标题一致。
          // 注意必须传入旧行：此时 chapters 字段尚未赋值（为空），
          // 若 resync 从 chapters 取旧数据会拿不到任何已完成内容，
          // deleteByOutlineId 会把已生成的正文全部删光（致命数据丢失）
          await resync(
            previousChapters: rows
                .map((m) => OutlineChapter.fromMap(m))
                .toList(),
          );
        } else {
          chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
        }
      } else {
        chapters = parseOutlineEvents(
          outlineContent,
          outlineId: outline.id!,
        );
        await OutlineChapterDbHelper().batchInsert(
          chapters.map((c) => c.toMap()).toList(),
        );
        await _reloadChapters();
      }
    } catch (_) {}
    // 清理遗留的 generating 状态：页面退出/进程被杀可能留下「生成中」但无正文的
    // 章节（旧版本返回键取消生成的产物），统一恢复为待生成，避免卡死后续章节的
    // 「写」按钮；有正文的章节在生成流程中已落盘为 completed，不受影响。
    for (int i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (c.status == 'generating' && c.content.trim().isEmpty && c.id != null) {
        await OutlineChapterDbHelper().updateStatus(c.id!, 'pending');
        chapters[i] = c.copyWith(status: 'pending');
      }
    }
    isLoading = false;
  }

  /// 章节默认目标字数（设置中的单章最少字数），供生成前输入框预填。
  Future<int> loadDefaultWords() async {
    try {
      final settings = await _service.loadSettings();
      return settings.chapterSetting.chapterMinWords;
    } catch (_) {
      return 2000;
    }
  }

  /// 开始生成章节内容
  ///
  /// [targetWords] 用户为本章指定的目标字数：传入时覆盖设置默认范围
  /// （min=max=目标字数），并按目标同步放大单次输出上限，避免被 max_tokens 截断；
  /// 为空时沿用设置的默认范围。
  Future<void> startWrite(
    BuildContext context,
    OutlineChapter ch,
    VoidCallback onUpdate, {
    int? targetWords,
  }) async {
    if (ch.id == null || ch.eventType != 'minor') return; // 大事件不可写
    final settings = await _service.loadSettings();
    if (settings.apiKey.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先在设置中填写 API Key')));
      }
      return;
    }

    isWriting = true;
    writingId = ch.id;
    writingText = '';
    thinkingText = '';
    reviewText = '';
    storyStateText = '';
    protagonistText = '';
    reviewBefore = '';
    reviewAfter = '';
    protagonistThinking = '';
    reviewThinking = '';
    storyStateThinking = '';
    protagonistReviewText = '';
    protagonistReviewThinking = '';
    reviewing = false;
    reviewingProtagonist = false;
    extractingStory = false;
    extractingProtagonist = false;
    errorText = '';
    _cancelled = false;
    _cancelToken = CancelToken();
    onUpdate();

    try {
      // 一次性加载章节列表与记录，避免前文/小结/状态多处重复查库
      final allRows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      final allChapters = allRows.map((m) => OutlineChapter.fromMap(m)).toList();
      final prevContent = _buildPrevContent(ch, allChapters);
      // 读取最新的剧情状态、人物档案与伏笔清单（写章节期间可能已累积）
      var freshRow = await OutlineRecordDbHelper().getById(outline.id!);
      var allCharacters = _parseCharacters(
        freshRow?['characters'] as String? ?? '',
      );
      // 第一章生成前：人物档案为空时先自动提炼主角档案（提炼 + 审查，过程可见气泡），
      // 确保章节提示词能注入主角档案；已有档案则跳过
      if (allCharacters.isEmpty && outline.protagonist.trim().isNotEmpty) {
        await _seedProtagonistFromOutline(onUpdate: onUpdate);
        freshRow = await OutlineRecordDbHelper().getById(outline.id!);
        allCharacters = _parseCharacters(
          freshRow?['characters'] as String? ?? '',
        );
      }
      // 只直接注入主角档案，其他人物由模型按需调用工具查询
      final protagonists = allCharacters.where((c) => c.isProtagonist).toList();
      final directChars = protagonists.isNotEmpty
          ? protagonists
          : (allCharacters.isNotEmpty
                ? [allCharacters.first]
                : const <CharacterProfile>[]);
      // 仅当存在主角以外的人物档案时才启用按需查询工具：
      // 第一章通常只有主角档案，禁用工具让模型直接写作，避免模型为查询
      // 并不存在的配角档案而多轮调用工具，导致正文生成失败
      final enableCharacterLookup = allCharacters.any((c) => !c.isProtagonist);
      // 用户指定本章字数时：min=max=目标字数（提示词显示「字数 N 字」），
      // 并按目标放大单次输出上限（约 2 token/字，封顶 8192），避免被 max_tokens 截断；
      // 设置值异常（>8192 或 <1，如误填大数）时不参与 clamp，直接沿用设置值，
      // 避免 clamp 上下界非法抛 ArgumentError 导致生成在开始前就失败
      final minWords = targetWords ?? settings.chapterSetting.chapterMinWords;
      final maxWords = targetWords ?? settings.chapterSetting.chapterMaxWords;
      final baseMaxTokens = settings.chapterSetting.maxTokens;
      final effectiveMaxTokens =
          (targetWords != null && baseMaxTokens >= 1 && baseMaxTokens <= 8192)
              ? (targetWords * 2).clamp(baseMaxTokens, 8192).toInt()
              : baseMaxTokens;
      final prompt = ChapterWritePromptTemplate.buildWritePrompt(
        outline: outline,
        outlineExcerpt: _buildLocalOutline(ch),
        ch: ch,
        prevContent: prevContent,
        prevEnding: _buildPrevEnding(ch, allChapters),
        // 全局剧情状态取上一章账本（第一章为空），与账本提炼的输入保持一致
        storyState: _prevChapterLedger(ch, allChapters),
        characters: _renderCharactersText(directChars),
        foreshadows: freshRow?['foreshadows'] as String? ?? '',
        parentMajor: _findParentMajor(ch),
        prevEventTitle: _findAdjacentTitle(ch, -1),
        nextEvents: _findNextEvents(ch, 3),
        isLastOfMajor: _isLastMinorOfMajor(ch),
        minWords: minWords,
        maxWords: maxWords,
        enableCharacterLookup: enableCharacterLookup,
      );
      await OutlineChapterDbHelper().updateStatus(ch.id!, 'generating');
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': settings.chapterSetting.chapterSystemPrompt.isNotEmpty
              ? settings.chapterSetting.chapterSystemPrompt
              : '你是一个专业的小说作家。',
        },
        {'role': 'user', 'content': prompt},
      ];
      // 多轮 function-calling：模型可先调用 get_character_profiles 查询人物档案再写作
      const maxRounds = 4;
      // 跨轮累积正文：每一轮输出的正文都保留（模型可能边写边调用工具），避免只取最后一轮丢内容
      final chapterBuffer = StringBuffer();
      for (int round = 0; round < maxRounds; round++) {
        if (_cancelled) break;
        final result = await _streamChapterWithTools(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': settings.chapterSetting.temperature,
            'max_tokens': effectiveMaxTokens,
            // 与大纲生成保持一致：关闭深度思考时显式禁用，避免思考抢占输出预算
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: messages,
          initialText: chapterBuffer.toString(),
          initialThinking: thinkingText,
          tools: enableCharacterLookup ? characterLookupTools : null,
          onUpdate: onUpdate,
        );
        if (_cancelled) break;
        if (result.content.isNotEmpty) {
          chapterBuffer.write(result.content);
          writingText = chapterBuffer.toString();
          onUpdate();
        }
        if (result.toolCalls.isEmpty) break;
        messages.add({
          'role': 'assistant',
          'content': result.content.isEmpty ? null : result.content,
          // 推理模型（deepseek-v4 思考模式）多轮工具调用：必须把上一轮 assistant 的
          // reasoning_content 原样回传，否则 API 报 400「Missing reasoning_content
          // in assistant message history」，章节生成会静默失败
          if (result.reasoning.isNotEmpty) 'reasoning_content': result.reasoning,
          'tool_calls': result.toolCalls
              .map(
                (tc) => {
                  'id': tc.id,
                  'type': 'function',
                  'function': {'name': tc.name, 'arguments': tc.arguments},
                },
              )
              .toList(),
        });
        for (final tc in result.toolCalls) {
          final output = _queryCharacterProfiles(tc.arguments, allCharacters);
          messages.add({
            'role': 'tool',
            'tool_call_id': tc.id,
            'content': output,
          });
        }
        onUpdate();
      }

      // 正常结束或取消：保留已生成内容
      if (writingText.isNotEmpty) {
        // 先落盘正文：在慢速尾段（AI 审查/账本提炼/整章小结）之前保存，
        // 即使中途返回页面、误触返回键或进程被杀也不丢内容
        await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        // 生成完成后插入 AI 审查修正（只修不合理处，不改变伏笔/剧情走向），
        // 审查失败或输出异常时保留原文
        if (!_cancelled) {
          reviewing = true;
          onUpdate();
          writingText = await _reviewChapter(
            ch: ch,
            content: writingText,
            prevEnding: _buildPrevEnding(ch, allChapters),
            storyState: _prevChapterLedger(ch, allChapters),
            characters: _renderCharactersText(directChars),
            onUpdate: onUpdate,
          );
          reviewing = false;
          onUpdate();
          // 审查可能修正正文：修正后再落盘一次
          await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        }
        // 账本/小结更新计入章节生成流程：基于修正后的正文提炼，
        // 完成后再把章节置为「已完成」，避免出现正文已生成但账本未更新的情况
        await _updateStoryState(
          ch,
          writingText,
          onUpdate: onUpdate,
          allChapters: allChapters,
        );
        await _summarizeChapter(ch, writingText);
        final idx = chapters.indexWhere((c) => c.id == ch.id);
        if (idx != -1) {
          chapters[idx] = chapters[idx].copyWith(
            content: writingText,
            status: 'completed',
          );
        }
      }
    } catch (e) {
      // 任何失败（含网络错误/取消）都不丢弃已生成的正文；状态兜底在 finally。
      // 记录错误信息供写视图展示，避免正文未生成时静默失败无从排查
      errorText = e.toString().replaceFirst('Exception: ', '');
      if (writingText.isNotEmpty) {
        await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
      }
    } finally {
      _cancelToken = null;
      isWriting = false;
      writingId = null;
      // 状态兜底：任何路径都不允许章节卡在 generating（会锁住后续章节的
      // 「写」按钮），也不允许内存状态与已落盘正文不一致
      if (writingText.isNotEmpty) {
        final idx = chapters.indexWhere((c) => c.id == ch.id);
        if (idx != -1) {
          final cur = chapters[idx];
          if (cur.status != 'completed' || cur.content != writingText) {
            chapters[idx] = cur.copyWith(
              content: writingText,
              status: 'completed',
            );
          }
        }
      } else {
        await OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
        final idx = chapters.indexWhere((c) => c.id == ch.id);
        if (idx != -1) {
          chapters[idx] = chapters[idx].copyWith(status: 'pending');
        }
      }
      onUpdate();
    }
  }

  /// 单轮流式请求：累积正文并收集流式 tool_calls 增量
  ///
  /// [initialText] / [initialThinking] 前几轮已生成的正文/思考，仅用于流式展示时
  /// 拼接显示，返回的 `content` 仍只包含本轮新增内容，由调用方累积保存。
  /// [tools] 可传 null 禁用工具（第一章只有主角档案时直接写作，避免多轮工具调用失败）。
  /// 流式请求失败或未产出任何内容（既无正文也无工具调用）时，回退一次非流式请求。
  Future<_StreamChapterResult> _streamChapterWithTools({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required VoidCallback onUpdate,
    String initialText = '',
    String initialThinking = '',
    List<Map<String, dynamic>>? tools,
  }) async {
    final completer = Completer<void>();
    final content = StringBuffer();
    final thinking = StringBuffer();
    final toolAccs = <int, _ToolCallAcc>{};
    String? streamError;
    try {
      await _service.streamWrite(
        apiKey: apiKey,
        apiParams: {...apiParams, 'stream': true},
        messages: messages,
        tools: tools,
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;
          final text = delta['content'] as String?;
          if (text != null && text.isNotEmpty) {
            content.write(text);
            writingText = initialText.isEmpty
                ? content.toString()
                : '$initialText${content.toString()}';
            onUpdate();
          }
          final reasoning = delta['reasoning_content'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) {
            thinking.write(reasoning);
            thinkingText = initialThinking.isEmpty
                ? thinking.toString()
                : '$initialThinking${thinking.toString()}';
            onUpdate();
          }
          final tcs = delta['tool_calls'] as List?;
          if (tcs != null) {
            for (final raw in tcs) {
              if (raw is! Map) continue;
              final index = raw['index'] as int? ?? 0;
              final acc = toolAccs.putIfAbsent(index, () => _ToolCallAcc());
              final id = raw['id'] as String?;
              if (id != null && id.isNotEmpty) acc.id = id;
              final fn = raw['function'];
              if (fn is Map<String, dynamic>) {
                final name = fn['name'] as String?;
                if (name != null && name.isNotEmpty) acc.name = name;
                final args = fn['arguments'] as String?;
                if (args != null && args.isNotEmpty) acc.arguments += args;
              }
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (msg) {
          if (!completer.isCompleted) completer.completeError(msg);
        },
      );
      await completer.future;
    } catch (e) {
      streamError = e.toString();
    }
    final toolCalls = toolAccs.values.where((t) => t.name.isNotEmpty).toList();
    // 流式失败或未产出任何内容时回退一次非流式请求，
    // 避免接口对 stream+tools 组合不兼容时正文静默为空
    if ((streamError != null || (content.isEmpty && toolCalls.isEmpty)) &&
        !_cancelled) {
      try {
        final fallback = await _service.chatOnce(
          apiKey: apiKey,
          apiParams: apiParams,
          messages: messages,
        );
        if (fallback.isNotEmpty) {
          content.write(fallback);
          writingText = initialText.isEmpty
              ? content.toString()
              : '$initialText${content.toString()}';
          onUpdate();
        } else if (streamError != null && content.isEmpty) {
          // 流式失败且兜底也无结果：记录错误供界面展示，不再静默
          errorText = streamError.replaceFirst('Exception: ', '');
        }
      } catch (_) {}
    }
    return _StreamChapterResult(
      content: content.toString(),
      // 本轮思考过程随结果返回：模型先思考再调工具时，下一轮请求需回传
      // reasoning_content（见 startWrite 中 assistant 消息构造）
      reasoning: thinking.toString(),
      toolCalls: toolCalls,
    );
  }

  /// 执行 get_character_profiles 工具调用：按姓名/关键词匹配人物档案并返回 JSON
  String _queryCharacterProfiles(
    String arguments,
    List<CharacterProfile> allCharacters,
  ) {
    List<String> names = [];
    try {
      final args = jsonDecode(arguments);
      if (args is Map) {
        final raw = args['names'];
        if (raw is List) names = raw.whereType<String>().toList();
      }
    } catch (_) {}
    final available = allCharacters
        .map((c) => c.name)
        .where((n) => n.isNotEmpty)
        .toList();
    final availableText = available.isEmpty ? '（暂无）' : available.join('、');
    if (names.isEmpty) {
      return '未指定人物名。当前可用人物：$availableText';
    }
    final matched = <CharacterProfile>[];
    final matchedNames = <String>{};
    for (final n in names) {
      final key = n.trim();
      if (key.isEmpty) continue;
      for (final c in allCharacters) {
        if (c.name.isEmpty || matchedNames.contains(c.name)) continue;
        if (c.name.contains(key) || key.contains(c.name)) {
          matched.add(c);
          matchedNames.add(c.name);
        }
      }
    }
    if (matched.isEmpty) {
      return '未找到与「${names.join('、')}」匹配的人物。当前可用人物：$availableText';
    }
    return jsonEncode(matched.map((c) => c.toJson()).toList());
  }

  /// 清空某章节已生成的内容，恢复为待生成状态
  Future<void> resetChapter(OutlineChapter ch) => resetChapters([ch]);

  /// 批量清空已生成的内容（正文 + AI 小结 + 本章账本），恢复为待生成状态。
  /// 清空后 outline_records.story_state 自动回退到剩余已完成章节中最新一章的账本，
  /// 实现「重新生成后剧情账本可退回」。
  Future<void> resetChapters(List<OutlineChapter> items) async {
    for (final ch in items) {
      if (ch.id == null) continue;
      await OutlineChapterDbHelper().updateContent(ch.id!, '');
      // 同时清空 AI 小结，避免下一章承接已删除的内容
      await OutlineChapterDbHelper().updateAiSummary(ch.id!, '');
      // 同时清空本章独立账本，重新生成后按上一章账本重新提炼
      await OutlineChapterDbHelper().updateStoryState(ch.id!, '');
      final idx = chapters.indexWhere((c) => c.id == ch.id);
      if (idx != -1) {
        chapters[idx] = chapters[idx].copyWith(
          content: '',
          status: 'pending',
          aiSummary: '',
          storyState: '',
        );
      }
    }
    // 账本页展示的全局账本回退到剩余已完成章节中最新一章
    await _syncLatestLedgerToRecord();
  }

  /// 把 outline_records.story_state 同步为当前最新已完成小事件的账本
  /// （账本页展示最新一章内容；无已完成章节时清空）。
  Future<void> _syncLatestLedgerToRecord() async {
    if (outline.id == null) return;
    try {
      final all = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      final completed = all
          .map((m) => OutlineChapter.fromMap(m))
          .where((c) => c.eventType == 'minor' && c.status == 'completed')
          .toList()
        ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
      final latest = completed.isEmpty ? null : completed.last;
      await OutlineRecordDbHelper().update(outline.id!, {
        'story_state': latest?.storyState ?? '',
      });
    } catch (_) {
      // 同步失败静默，不影响主流程
    }
  }

  /// 保存某章节的剧情账本（章节独立字段），若本章是当前最新已完成章节，
  /// 同步到 outline_records.story_state（账本页展示最新一章）。
  Future<void> saveChapterLedger(OutlineChapter ch, String content) async {
    if (ch.id == null) return;
    await OutlineChapterDbHelper().updateStoryState(ch.id!, content);
    await _syncLatestLedgerToRecord();
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(storyState: content);
    }
  }

  /// 上一章账本：当前章节之前最近一个已完成章节所保存的剧情账本。
  /// 第一章或前序无已完成章节时返回空串（账本从本章起全新提炼）。
  String _prevChapterLedger(OutlineChapter ch, List<OutlineChapter> all) {
    final ordered = List<OutlineChapter>.from(all)
      ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
    final idx = ordered.indexWhere((c) => c.id == ch.id);
    if (idx <= 0) return '';
    for (int i = idx - 1; i >= 0; i--) {
      final prev = ordered[i];
      if (prev.status == 'completed' && prev.storyState.trim().isNotEmpty) {
        return prev.storyState;
      }
    }
    return '';
  }

  /// 保存手动编辑后的章节内容。
  /// 正文落盘与内存同步**即时完成**（保存返回后重新编辑/查看内容立即读到新内容）；
  /// 账本提炼与整章小结（AI 调用，耗时长）改为后台执行——
  /// 此前内存更新排在两次 AI 调用之后，保存退出后重新点开编辑/查看内容
  /// 读到的还是修改前的旧内容，只有重新进入页面才刷新。
  Future<void> saveChapterContent(OutlineChapter ch, String content) async {
    await OutlineChapterDbHelper().updateContent(ch.id!, content);
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(
        content: content,
        status: content.trim().isEmpty ? 'pending' : 'completed',
      );
    }
    if (content.trim().isEmpty) return;
    // 编辑保存后的可见提炼流程（编辑页正文下方气泡实时展示）：
    // 账本提炼 → 整章小结，全部完成后返回（编辑页据此提醒并退出）。
    // 正文已先落盘+同步内存，中途退出/失败均不影响已保存内容；
    // 退出页面后流程继续在后台完成，processingChapterId 供列表/编辑/查看页显示进度
    storyStateText = '';
    storyStateThinking = '';
    chapterSummaryOutputText = '';
    chapterSummaryThinkingText = '';
    processingChapterId = ch.id;
    try {
      final all = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
      await _updateStoryState(
        ch,
        content,
        allChapters: all.map((m) => OutlineChapter.fromMap(m)).toList(),
      );
      await _summarizeChapterVisible(ch, content);
    } catch (_) {
      // 提炼失败不影响正文保存
    } finally {
      processingChapterId = null;
    }
  }

  /// 修改章节标题/概要，并同步回大纲记录
  Future<void> updateChapterSummary(
    OutlineChapter ch,
    String title,
    String summary,
  ) async {
    await OutlineChapterDbHelper().updateSummary(ch.id!, title, summary);
    final oldCh = chapters.firstWhere((c) => c.id == ch.id);
    await syncEventToOutline(oldCh, title, summary);
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(
        eventTitle: title,
        eventSummary: summary,
      );
    }
    // 注意：不再在保存时自动提炼伏笔清单——改为账本页手动「重新提炼」触发，
    // 避免保存流程被 AI 调用拖慢，也避免频繁触发消耗额度
  }


  void stopWrite() {
    _cancelled = true;
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  /// 释放资源。注意：不再在此取消进行中的生成——用户误触返回键退出页面后，
  /// 生成流程继续在后台完成并落盘（正文/账本/小结），避免已生成内容丢失、
  /// 章节状态卡在 generating。主动停止仍走 [stopWrite]（停止按钮）。
  void dispose() {}

  Future<void> _reloadChapters() async {
    final rows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
    chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
  }

  /// 构造前文内容：紧邻上一章注入**完整正文**（保证结尾衔接），
  /// 更早的 2-3 章改用 AI 整章小结一句话带过，再更早的用一行统计省略，
  /// 避免整篇注入导致提示词膨胀、注意力分散。
  String _buildPrevContent(OutlineChapter currentCh, List<OutlineChapter> all) {
    if (currentCh.id == null) return '';
    final prevs = all
        .where(
          (c) => c.status == 'completed' && c.eventIndex < currentCh.eventIndex,
        )
        .toList();
    if (prevs.isEmpty) return '故事刚开始，没有前文。';
    const fullCount = 1; // 紧邻上一章：完整正文
    const summaryCount = 3; // 再往前 3 章：AI 小结带过
    final fullStart = prevs.length > fullCount ? prevs.length - fullCount : 0;
    final summaryStart = fullStart - summaryCount;
    final fullChapters = prevs.sublist(fullStart);
    final summaryChapters = summaryStart > 0
        ? prevs.sublist(summaryStart, fullStart)
        : prevs.sublist(0, fullStart);
    final buf = StringBuffer();
    if (prevs.length > fullCount + summaryCount) {
      buf.writeln(
        '（此前还有 ${prevs.length - fullCount - summaryCount} 个已完成事件，内容省略）',
      );
      buf.writeln();
    }
    for (final c in fullChapters) {
      final content = c.content.trim();
      buf.writeln('【${c.eventTitle}】');
      buf.writeln(content.isEmpty ? '（本章暂无正文内容）' : content);
      buf.writeln();
    }
    if (summaryChapters.isNotEmpty) {
      buf.writeln('（更早章节小结）');
      for (final c in summaryChapters) {
        var s = c.aiSummary.trim();
        if (s.isEmpty) {
          // 小结尚未生成（旧数据/快速连写）：回退正文末尾片段
          final content = c.content.trim();
          s = content.isEmpty
              ? '（暂无小结）'
              : (content.length > 150
                    ? content.substring(content.length - 150)
                    : content);
        }
        buf.writeln('【${c.eventTitle}】$s');
      }
    }
    return buf.toString().trim();
  }

  /// 上一章小结：紧邻当前事件的已完成事件。
  /// 优先使用 AI 提炼的整章小结；小结尚未生成（快速连写/旧数据）时回退正文末尾 300 字。
  String _buildPrevEnding(OutlineChapter currentCh, List<OutlineChapter> all) {
    final ordered = List<OutlineChapter>.from(all)
      ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
    final idx = ordered.indexWhere((c) => c.id == currentCh.id);
    if (idx <= 0) return '';
    final prev = ordered[idx - 1];
    if (prev.status != 'completed') return '';
    if (prev.aiSummary.trim().isNotEmpty) return prev.aiSummary.trim();
    final content = prev.content.trim();
    if (content.isEmpty) return '';
    const len = 300;
    return content.length > len
        ? content.substring(content.length - len)
        : content;
  }

  /// 通用流式收集：把一次流式对话的 content 与 reasoning_content 分别累积进
  /// 两个 StringBuffer，每个分块到达后回调 [onUpdate] 刷新 UI（气泡实时展示）。
  /// 返回累积的 content 完整文本；失败时抛错由调用方兜底。
  Future<String> _streamCollect({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required StringBuffer content,
    required StringBuffer thinking,
    required VoidCallback onUpdate,
  }) async {
    final completer = Completer<void>();
    await _service.streamWrite(
      apiKey: apiKey,
      apiParams: {...apiParams, 'stream': true},
      messages: messages,
      cancelToken: _cancelToken,
      onChunk: (chunk) {
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) return;
        final delta = choices[0]['delta'] as Map<String, dynamic>?;
        if (delta == null) return;
        final text = delta['content'] as String?;
        if (text != null && text.isNotEmpty) {
          content.write(text);
        }
        final reasoning = delta['reasoning_content'] as String?;
        if (reasoning != null && reasoning.isNotEmpty) {
          thinking.write(reasoning);
        }
        onUpdate();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (msg) {
        if (!completer.isCompleted) completer.completeError(msg);
      },
    );
    await completer.future;
    return content.toString();
  }

  /// 流式提取 + 非流式兜底：优先流式（供气泡实时查看）；
  /// 流式失败或未产出内容时回退一次非流式 [ChapterWriteService.chatOnce]，
  /// 兜底结果会回填到 [content] 缓冲（气泡可看到最终结果）。
  Future<String> _streamOrFallback({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required StringBuffer content,
    required StringBuffer thinking,
    required VoidCallback onUpdate,
  }) async {
    String text = '';
    try {
      text = await _streamCollect(
        apiKey: apiKey,
        apiParams: apiParams,
        messages: messages,
        content: content,
        thinking: thinking,
        onUpdate: onUpdate,
      );
    } catch (_) {
      // 流式失败（如 response_format + stream 不被接口支持），走非流式兜底
    }
    if (text.trim().isNotEmpty) return text;
    final fallback = await _service.chatOnce(
      apiKey: apiKey,
      apiParams: apiParams,
      messages: messages,
    );
    if (fallback.isNotEmpty && content.isEmpty) {
      content.write(fallback);
      onUpdate();
    }
    return fallback;
  }

  /// AI 审查修正章节正文（在生成完成与账本提炼之间执行）。
  /// 只修正逻辑/矛盾/细节不合理处，不改变伏笔、剧情走向、人物设定与大纲情节；
  /// 审查失败、无 API Key 或输出异常（过短/为空）时原样返回原文，不影响主流程。
  /// 过程流式写入 [reviewText]，供全屏生成视图气泡实时查看。
  Future<String> _reviewChapter({
    required OutlineChapter ch,
    required String content,
    required String prevEnding,
    String storyState = '',
    required String characters,
    required VoidCallback onUpdate,
  }) async {
    if (outline.id == null || content.trim().isEmpty) return content;
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return content;
      final fresh = await OutlineRecordDbHelper().getById(outline.id!);
      final contentBuf = StringBuffer();
      final thinkingBuf = StringBuffer();
      var thinkingShown = 0; // 已追加到 thinkingText 的审查思考长度
      final revised = await _streamOrFallback(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.chapterSetting.model,
          'temperature': 0.3,
          'max_tokens': settings.chapterSetting.maxTokens,
          if (!settings.chapterSetting.enableThinking)
            'thinking': {'type': 'disabled'},
        },
        messages: _service.buildReviewMessages(
          eventTitle: ch.eventTitle,
          eventSummary: ch.eventSummary,
          prevEnding: prevEnding,
          storyState: storyState,
          characters: characters,
          foreshadows: fresh?['foreshadows'] as String? ?? '',
          chapterContent: content,
        ),
        content: contentBuf,
        thinking: thinkingBuf,
        onUpdate: () {
          reviewText = contentBuf.toString();
          // 审查思考过程实时写入独立气泡（位于正文下方），不再丢弃
          final t = thinkingBuf.toString();
          if (t.length > thinkingShown) {
            reviewThinking += t.substring(thinkingShown);
            thinkingShown = t.length;
          }
          onUpdate();
        },
      );
      final cleaned = _stripMarkdownFence(revised);
      // 审查按格式输出【审查意见】+【修正后正文】：
      // 审查气泡只保留【审查意见】，对比气泡展示修改前后，正文区取【修正后正文】
      const marker = '【修正后正文】';
      final hasMarker = cleaned.contains(marker);
      final body = hasMarker
          ? cleaned.substring(cleaned.indexOf(marker) + marker.length).trim()
          : cleaned;
      if (hasMarker) {
        reviewText = cleaned.substring(0, cleaned.indexOf(marker)).trim();
      }
      // 审查输出过短视为异常（模型未完整回写正文），保留原文
      if (body.trim().length >= content.trim().length * 0.5) {
        final newBody = body.trim();
        // 有实际修改时填充对比气泡；无修改（原样输出）则只保留审查意见
        if (newBody != content.trim()) {
          reviewBefore = content;
          reviewAfter = newBody;
        }
        return newBody;
      }
      return content;
    } catch (_) {
      return content; // 审查失败不影响主流程
    }
  }

  /// 去除模型输出外层可能包裹的 markdown 代码围栏
  String _stripMarkdownFence(String text) {
    final t = text.trim();
    final m = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$').firstMatch(t);
    return m != null ? m.group(1)!.trim() : t;
  }

  /// 后台提炼整章小结：调用轻量接口把本章正文压缩为小结，
  /// 写入 outline_chapters.ai_summary，供下一章开头承接。
  /// 失败静默，不影响章节生成流程。
  Future<void> _summarizeChapter(OutlineChapter ch, String content) async {
    if (ch.id == null || content.trim().isEmpty) return;
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return;
      final summary = await _service.summarizeChapter(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.chapterSetting.model,
          'temperature': 0.3,
          'max_tokens': settings.chapterSetting.maxTokens,
        },
        eventTitle: ch.eventTitle,
        eventSummary: ch.eventSummary,
        chapterContent: content,
      );
      if (summary.isNotEmpty) {
        await OutlineChapterDbHelper().updateAiSummary(ch.id!, summary);
      }
    } catch (_) {
      // 提炼失败不影响章节生成，静默跳过
    }
  }

  /// 整章小结（流式可见版）：把本章正文压缩为小结并写库；
  /// 过程流式写入 [chapterSummaryThinkingText]（AI 思考）与
  /// [chapterSummaryOutputText]（小结输出），供编辑保存页气泡实时展示；
  /// 流式失败时回退一次非流式调用。失败静默不影响正文保存。
  Future<void> _summarizeChapterVisible(OutlineChapter ch, String content) async {
    if (ch.id == null || content.trim().isEmpty) return;
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return;
      final buf = StringBuffer();
      final thinkBuf = StringBuffer();
      summarizingChapter = true;
      chapterSummaryThinkingText = '';
      chapterSummaryOutputText = '';
      try {
        final completer = Completer<void>();
        await _service.streamSummarizeChapter(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          eventTitle: ch.eventTitle,
          eventSummary: ch.eventSummary,
          chapterContent: content,
          onContent: (c) {
            buf.write(c);
            chapterSummaryOutputText = buf.toString();
          },
          onReasoning: (r) {
            thinkBuf.write(r);
            chapterSummaryThinkingText = thinkBuf.toString();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (msg) {
            if (!completer.isCompleted) completer.completeError(msg);
          },
        );
        await completer.future;
      } finally {
        summarizingChapter = false;
      }
      var summary = buf.toString().trim();
      if (summary.isEmpty) {
        // 流式失败或无输出：回退非流式一次
        summary = await _service.summarizeChapter(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
          },
          eventTitle: ch.eventTitle,
          eventSummary: ch.eventSummary,
          chapterContent: content,
        );
        if (summary.isNotEmpty) chapterSummaryOutputText = summary;
      }
      if (summary.isNotEmpty) {
        await OutlineChapterDbHelper().updateAiSummary(ch.id!, summary);
      }
    } catch (_) {
      // 提炼失败不影响正文保存
    }
  }

  /// 当前事件是否可写：仅小事件可写，且其之前的所有小事件必须已完成
  /// （强制顺序生成，避免跳过前序章节导致上下文断裂）。
  bool isWritable(OutlineChapter ch) {
    if (ch.eventType != 'minor') return false; // 大事件不可写
    return !chapters.any(
      (c) =>
          c.eventType == 'minor' &&
          c.eventIndex < ch.eventIndex &&
          c.status != 'completed',
    );
  }

  /// 提炼剧情状态账本：调用轻量接口把「前序状态 + 当前人物档案 + 本章正文」
  /// 合并为最新状态与人物档案，写入 outline_records。
  /// 仅在设置开启时执行；失败静默，不影响章节生成流程。
  /// 提炼过程流式写入 [storyStateText]（供全屏生成视图气泡实时查看），
  /// [onUpdate] 可选：章节生成流程中传入以刷新 UI，手动编辑保存时可不传。
  /// 性格字段由代码层按姓名回填保留，AI 不会覆盖用户维护的性格。
  /// [allChapters] 章节列表（含各章独立账本）：上一章账本作为本章提炼的输入，
  /// 第一章（或前序无已完成章节）时从空开始；提炼结果写入本章 story_state 列，
  /// 并同步 outline_records.story_state 为最新已完成章节的账本（账本页展示最新一章）。
  Future<void> _updateStoryState(
    OutlineChapter ch,
    String content, {
    VoidCallback? onUpdate,
    List<OutlineChapter>? allChapters,
  }) async {
    if (outline.id == null || content.trim().isEmpty) return;
    try {
      final settings = await _service.loadSettings();
      if (!settings.chapterSetting.enableStoryState) return;
      if (settings.apiKey.isEmpty) return;
      final fresh = await OutlineRecordDbHelper().getById(outline.id!);
      // 上一章账本：取最近一个已完成章节的独立账本（第一章为空），
      // 不再使用全局 story_state——每章账本独立保存，重新生成后可回退
      final prevChapters = allChapters ??
          (await OutlineChapterDbHelper().getByOutlineId(outline.id!))
              .map((m) => OutlineChapter.fromMap(m))
              .toList();
      final prevState = _prevChapterLedger(ch, prevChapters);
      final oldChars = _parseCharacters(fresh?['characters'] as String? ?? '');
      final contentBuf = StringBuffer();
      final thinkingBuf = StringBuffer();
      var thinkingShown = 0; // 已追加到 thinkingText 的账本提炼思考长度
      String result;
      extractingStory = true;
      onUpdate?.call();
      try {
        result = await _streamOrFallback(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
            'response_format': {'type': 'json_object'},
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: _service.buildStoryStateMessages(
            prevState: prevState,
            characters: oldChars,
            eventTitle: ch.eventTitle,
            eventSummary: ch.eventSummary,
            chapterContent: content,
          ),
          content: contentBuf,
          thinking: thinkingBuf,
          onUpdate: () {
            storyStateText = contentBuf.toString();
            // 账本提炼思考过程实时写入独立气泡，不再丢弃
            final t = thinkingBuf.toString();
            if (t.length > thinkingShown) {
              storyStateThinking += t.substring(thinkingShown);
              thinkingShown = t.length;
            }
            onUpdate?.call();
          },
        );
      } finally {
        extractingStory = false;
        onUpdate?.call();
      }
      // 流式结果无法解析出 JSON（如被截断）时，再走一次非流式兜底重试
      if (_extractJson(result) == null) {
        final fallback = await _service.chatOnce(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
            'response_format': {'type': 'json_object'},
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: _service.buildStoryStateMessages(
            prevState: prevState,
            characters: oldChars,
            eventTitle: ch.eventTitle,
            eventSummary: ch.eventSummary,
            chapterContent: content,
          ),
        );
        if (_extractJson(fallback) != null) {
          result = fallback;
          if (storyStateText.isEmpty) {
            storyStateText = fallback;
            onUpdate?.call();
          }
        }
      }
      final decoded = _extractJson(result);
      if (decoded == null) return; // 解析失败则保留旧账本
      final newState = (decoded['story_state'] as String? ?? '').trim();
      final newChars = _parseCharacters(jsonEncode(decoded['characters']));
      final merged = _mergeCharacters(oldChars, newChars);
      if (newState.isEmpty && merged.isEmpty) return;
      final ledger = newState.isEmpty ? prevState : newState;
      // 本章账本独立落盘到 outline_chapters.story_state
      await OutlineChapterDbHelper().updateStoryState(ch.id!, ledger);
      final idx = chapters.indexWhere((c) => c.id == ch.id);
      if (idx != -1) {
        chapters[idx] = chapters[idx].copyWith(storyState: ledger);
      }
      // 全局账本镜像为最新已完成章节的账本（账本页展示最新一章）
      await _syncLatestLedgerToRecord();
      await OutlineRecordDbHelper().update(outline.id!, {
        'characters': jsonEncode(merged.map((c) => c.toJson()).toList()),
      });
    } catch (_) {
      // 状态提炼失败不影响章节生成，静默跳过
    }
  }

  /// 从大纲提炼主角人物档案（含 AI 审查）：基于主角完整人设调用 AI 提炼并补全缺失描述，
  /// 提炼完成后对档案执行一轮合理性审查（遵循提炼约束，修正不合理处）再写库。
  /// 过程流式写入 [protagonistText]（提炼）与 [reviewText]（审查），供全屏视图气泡展示；
  /// [onUpdate] 可选：章节生成流程中传入以刷新 UI，账本页手动触发时可不传。
  /// 返回是否成功写入档案。
  Future<bool> _seedProtagonistFromOutline({VoidCallback? onUpdate}) async {
    if (outline.id == null) return false;
    final setting = outline.protagonist.trim();
    if (setting.isEmpty) return false; // 无主角设定（如匹配大纲格式的旧记录）则跳过
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return false;
      // 1) 提炼主角档案（流式）
      final extractBuf = StringBuffer();
      final extractThinkBuf = StringBuffer();
      var extractThinkShown = 0; // 已追加到 thinkingText 的主角提炼思考长度
      String raw;
      extractingProtagonist = true;
      onUpdate?.call();
      try {
        raw = await _streamOrFallback(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
            'response_format': {'type': 'json_object'},
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: _service.buildProtagonistMessages(
            protagonistSetting: setting,
            outlineContent: outlineContent,
          ),
          content: extractBuf,
          thinking: extractThinkBuf,
          onUpdate: () {
            protagonistText = extractBuf.toString();
            // 主角提炼思考过程实时写入独立气泡，不再丢弃
            final t = extractThinkBuf.toString();
            if (t.length > extractThinkShown) {
              protagonistThinking += t.substring(extractThinkShown);
              extractThinkShown = t.length;
            }
            onUpdate?.call();
          },
        );
      } finally {
        extractingProtagonist = false;
        onUpdate?.call();
      }
      var decoded = _extractJson(raw);
      if (decoded == null) return false;
      var p = decoded['protagonist'];
      if (p is! Map<String, dynamic>) return false;

      // 2) 对提炼结果执行一轮 AI 审查（遵循提炼约束，修正不合理处）。
      // 使用独立的 reviewingProtagonist / protagonistReviewText / protagonistReviewThinking，
      // 与章节审查（reviewing / reviewText / reviewThinking）区分展示，
      // 避免用户误以为「AI 审查」在审查尚未生成的章节正文
      final profileJson = jsonEncode({'protagonist': p});
      final reviewBuf = StringBuffer();
      final reviewThinkBuf = StringBuffer();
      var reviewThinkShown = 0; // 已追加到 protagonistReviewThinking 的档案审查思考长度
      reviewingProtagonist = true;
      onUpdate?.call();
      String reviewedRaw;
      try {
        reviewedRaw = await _streamOrFallback(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
            'response_format': {'type': 'json_object'},
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: _service.buildProtagonistReviewMessages(
            protagonistSetting: setting,
            profileJson: profileJson,
          ),
          content: reviewBuf,
          thinking: reviewThinkBuf,
          onUpdate: () {
            protagonistReviewText = reviewBuf.toString();
            // 档案审查思考过程实时写入独立气泡，不再丢弃
            final t = reviewThinkBuf.toString();
            if (t.length > reviewThinkShown) {
              protagonistReviewThinking += t.substring(reviewThinkShown);
              reviewThinkShown = t.length;
            }
            onUpdate?.call();
          },
        );
      } finally {
        reviewingProtagonist = false;
        onUpdate?.call();
      }
      // 从审查输出中解析【修正后档案】JSON；解析失败则沿用提炼结果
      const marker = '【修正后档案】';
      final cleaned = _stripMarkdownFence(reviewedRaw);
      if (cleaned.contains(marker)) {
        // 档案审查气泡只保留【审查意见】
        protagonistReviewText = cleaned.substring(0, cleaned.indexOf(marker)).trim();
      }
      final reviewedJson = cleaned.contains(marker)
          ? cleaned.substring(cleaned.indexOf(marker) + marker.length).trim()
          : cleaned;
      final reviewedDecoded = _extractJson(reviewedJson);
      if (reviewedDecoded != null) {
        final reviewedP = reviewedDecoded['protagonist'];
        if (reviewedP is Map<String, dynamic>) {
          decoded = reviewedDecoded;
          p = reviewedP;
        }
      }

      final profile = CharacterProfile(
        name: (p['name'] as String? ?? '').trim(),
        description: (p['description'] as String? ?? '').trim(),
        abilities: (p['abilities'] as String? ?? '').trim(),
        // 人设/大纲中明确提到的性格首次种入；此后由用户维护，AI 提炼不会覆盖
        personality: (p['personality'] as String? ?? '').trim(),
        isProtagonist: true, // 主角标记：档案直接注入章节提示词
      );
      if (profile.name.isEmpty) return false;
      await OutlineRecordDbHelper().update(outline.id!, {
        'characters': jsonEncode([profile.toJson()]),
      });
      return true;
    } catch (_) {
      // 提取失败静默跳过，后续可在账本页手动维护
      return false;
    }
  }

  /// 供账本页「手动生成主角档案」调用：提炼 + 审查 + 写库，返回用户可读的结果。
  Future<String> generateProtagonistProfile() async {
    final ok = await _seedProtagonistFromOutline();
    if (ok) {
      return '已从大纲生成主角档案';
    }
    if (outline.protagonist.trim().isEmpty) {
      return '大纲未设置主角人设，无法生成';
    }
    return '生成失败，请检查 API Key 或稍后重试';
  }

  /// 供账本页「重新提炼伏笔」调用：从最新大纲内容**流式**提炼伏笔清单并写库，
  /// 思考过程（reasoning_content）与清单输出实时累积到 [foreshadowThinkingText] /
  /// [foreshadowOutputText]，供「AI 伏笔生成详情」页实时展示；返回用户可读结果（失败保留旧清单）。
  Future<String> regenerateForeshadows() async {
    if (outline.id == null) return '大纲记录不存在';
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return '请先填写 API Key';
      isRefreshingForeshadows = true;
      foreshadowThinkingText = '';
      foreshadowOutputText = '';
      final contentBuf = StringBuffer();
      final thinkingBuf = StringBuffer();
      try {
        // 读取旧伏笔清单：结合旧清单修改/补充/删除，避免每次从零提取覆盖
        final fresh = await OutlineRecordDbHelper().getById(outline.id!);
        final existingForeshadows = fresh?['foreshadows'] as String? ?? '';
        final completer = Completer<void>();
        await OutlineFormatService().streamExtractForeshadows(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.chapterSetting.model,
            'temperature': 0.3,
            'max_tokens': settings.chapterSetting.maxTokens,
          },
          outlineContent: outlineContent,
          existingForeshadows: existingForeshadows,
          onContent: (c) {
            contentBuf.write(c);
            foreshadowOutputText = contentBuf.toString();
          },
          onReasoning: (r) {
            thinkingBuf.write(r);
            foreshadowThinkingText = thinkingBuf.toString();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (msg) {
            if (!completer.isCompleted) completer.completeError(msg);
          },
        );
        await completer.future;
        final text = contentBuf.toString().trim();
        if (text.isEmpty) return '未提炼出伏笔内容，已保留原清单';
        await OutlineRecordDbHelper().update(outline.id!, {
          'foreshadows': text,
        });
        return '伏笔清单已重新提炼';
      } finally {
        isRefreshingForeshadows = false;
      }
    } catch (e) {
      isRefreshingForeshadows = false;
      return '提炼失败：${e.toString().replaceFirst('Exception: ', '')}';
    }
  }

  /// 从 JSON 字符串解析人物档案列表（容错返回空列表）
  List<CharacterProfile> _parseCharacters(String jsonText) {
    if (jsonText.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(CharacterProfile.fromJson)
          .where((c) => c.name.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 合并人物档案：描述/能力取 AI 新值；性格规则——
  /// 已有角色（含大纲提取的主角等）性格由用户维护，AI 不写不覆盖；
  /// 正文中新出现的人物，首次由 AI 从正文提炼性格，此后同样由用户维护。
  /// AI 未提及的旧人物保留，避免丢失用户编辑过的角色。
  List<CharacterProfile> _mergeCharacters(
    List<CharacterProfile> old,
    List<CharacterProfile> fresh,
  ) {
    final byName = {for (final c in old) c.name.trim(): c};
    final result = <CharacterProfile>[];
    final seen = <String>{};
    for (final c in fresh) {
      final name = c.name.trim();
      if (name.isEmpty) continue;
      seen.add(name);
      final oldChar = byName[name];
      result.add(
        CharacterProfile(
          name: name,
          description: c.description.isNotEmpty
              ? c.description
              : (oldChar?.description ?? ''),
          abilities: c.abilities.isNotEmpty
              ? c.abilities
              : (oldChar?.abilities ?? ''),
          // 已有角色保留用户维护的性格；新角色采用 AI 首次提炼的性格
          personality: oldChar != null ? oldChar.personality : c.personality,
          // 主角标记持续保留（AI 提炼不会携带该字段）
          isProtagonist: (oldChar?.isProtagonist ?? false) || c.isProtagonist,
        ),
      );
    }
    for (final c in old) {
      if (c.name.trim().isNotEmpty && !seen.contains(c.name.trim())) {
        result.add(c);
      }
    }
    return result;
  }

  /// 渲染人物档案为提示词可读文本（含性格，写章节时需遵循用户设定）
  String _renderCharactersText(List<CharacterProfile> chars) {
    if (chars.isEmpty) return '';
    return chars
        .map(
          (c) => [
            '· ${c.name}',
            if (c.description.isNotEmpty) '  描述：${c.description}',
            if (c.abilities.isNotEmpty) '  能力：${c.abilities}',
            if (c.personality.isNotEmpty) '  性格：${c.personality}',
          ].join('\n'),
        )
        .join('\n');
  }

  /// 从文本提取 JSON 对象（容错 markdown 围栏与前后杂文）
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

  /// 查找当前事件所属的大事件（若当前事件本身是大事件则返回自身）
  OutlineChapter? _findParentMajor(OutlineChapter ch) {
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx == -1) return null;
    for (int i = idx; i >= 0; i--) {
      if (chapters[i].eventType == 'major') return chapters[i];
    }
    return null;
  }

  /// 查找当前事件相邻的上一/下一事件标题（offset 为 -1/1）
  String _findAdjacentTitle(OutlineChapter ch, int offset) {
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    final target = idx + offset;
    if (idx == -1 || target < 0 || target >= chapters.length) return '';
    return chapters[target].eventTitle;
  }

  /// 查找当前事件之后的 [count] 个事件（含下个大事件，供衔接提示使用）
  List<OutlineChapter> _findNextEvents(OutlineChapter ch, int count) {
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx == -1 || count <= 0) return const [];
    final result = <OutlineChapter>[];
    for (int i = idx + 1; i < chapters.length && result.length < count; i++) {
      result.add(chapters[i]);
    }
    return result;
  }

  /// 当前小事件是否是其所属大事件的最后一个事件（之后紧跟下个大事件或已到末尾）。
  /// 用于提示模型结尾必须衔接下文，避免提前收尾/完结故事。
  bool _isLastMinorOfMajor(OutlineChapter ch) {
    if (ch.eventType != 'minor') return false;
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx == -1) return false;
    if (idx + 1 >= chapters.length) return true;
    return chapters[idx + 1].eventType == 'major';
  }

  /// 提取当前事件附近的大纲片段，避免把整篇大纲注入提示词。
  ///
  /// 按 `parseOutlineEvents` 相同的规则逐行计数事件，用 [eventIndex] 直接定位
  /// 当前章节所在行（不依赖标题子串匹配，标题重复或出现在概要中也不会选错块），
  /// 只取「当前事件所属大事件」的完整块（大事件标题+概述+其下全部小事件），
  /// 不取整幕——每幕大事件很多，整幕注入会撑大提示词；后续衔接由
  /// 【后续事件】单独注入。找不到对应事件时回退整篇大纲。
  String _buildLocalOutline(OutlineChapter ch) {
    final lines = outlineContent.split('\n');
    final majorRe = RegExp(
      r'^\s*═*\s*(?:大事件|Major|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]',
    );
    final minorRe = RegExp(
      r'^\s*[○\-•*\·]?\s*(?:小事件|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]',
    );
    final actRe = RegExp(r'^\s*══\s*第[一二三四五六0-9]+幕[^═]*══');
    // 与 parseOutlineEvents 一致：大/小事件标题行各计一个事件，据此定位第 eventIndex 个事件所在行
    int seen = 0;
    int curIdx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (majorRe.hasMatch(lines[i]) || minorRe.hasMatch(lines[i])) {
        seen++;
        if (seen == ch.eventIndex) {
          curIdx = i;
          break;
        }
      }
    }
    if (curIdx == -1) return outlineContent;
    // 块起点：当前事件所在的大事件标题行（当前事件自身为大事件时即其本身）
    int blockStart = curIdx;
    for (int i = curIdx; i >= 0; i--) {
      if (majorRe.hasMatch(lines[i])) {
        blockStart = i;
        break;
      }
    }
    // 块终点：下一条大事件标题行或下一幕标题行
    int blockEnd = lines.length;
    for (int i = curIdx + 1; i < lines.length; i++) {
      if (majorRe.hasMatch(lines[i]) || actRe.hasMatch(lines[i])) {
        blockEnd = i;
        break;
      }
    }
    return lines.sublist(blockStart, blockEnd).join('\n').trim();
  }
}

/// 单轮流式章节生成结果
class _StreamChapterResult {
  final String content;
  final String reasoning; // 本轮思考过程（reasoning_content，工具调用多轮时需回传 API）
  final List<_ToolCallAcc> toolCalls;
  _StreamChapterResult({
    required this.content,
    required this.reasoning,
    required this.toolCalls,
  });
}

/// 流式 tool_calls 增量累积器（按 index 归并 id/name/arguments 分片）
class _ToolCallAcc {
  String id = '';
  String name = '';
  String arguments = '';
}
