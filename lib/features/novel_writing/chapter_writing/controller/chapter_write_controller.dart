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
  Future<void> resync() async {
    needsResync = false;
    final oldChapters = Map.fromEntries(
      chapters.map((c) => MapEntry(c.eventTitle, c)),
    );
    final newChapters = _parseEvents(outlineContent);
    for (int i = 0; i < newChapters.length; i++) {
      final old = oldChapters[newChapters[i].eventTitle];
      if (old != null && old.status == 'completed' && old.content.isNotEmpty) {
        newChapters[i] = newChapters[i].copyWith(
          content: old.content,
          status: 'completed',
          aiSummary: old.aiSummary,
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
    var content = outlineContent;
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trimLeft();
      if (trimmed.startsWith('══') &&
          trimmed.contains(oldCh.eventTitle) &&
          trimmed.endsWith('══')) {
        final newLine = trimmed.replaceFirst(oldCh.eventTitle, newTitle);
        final indent = lines[i].length - lines[i].trimLeft().length;
        lines[i] = ' ' * indent + newLine.trimLeft();
        if (newSummary.isNotEmpty) {
          for (int j = i + 1; j < lines.length; j++) {
            final t = lines[j].trimLeft();
            if (t.startsWith('══') || t.startsWith('○') || t.startsWith('-'))
              break;
            if (t.isNotEmpty) {
              final indent2 = lines[j].length - lines[j].trimLeft().length;
              lines[j] = ' ' * indent2 + newSummary;
              break;
            }
          }
        }
        break;
      }
      if (trimmed.startsWith('○') && trimmed.contains(oldCh.eventTitle)) {
        final newLine = trimmed.replaceFirst(oldCh.eventTitle, newTitle);
        final indent = lines[i].length - lines[i].trimLeft().length;
        lines[i] = ' ' * indent + newLine.trimLeft();
        if (newSummary.isNotEmpty && i + 1 < lines.length) {
          final t = lines[i + 1].trimLeft();
          if (t.isNotEmpty &&
              !t.startsWith('══') &&
              !t.startsWith('○') &&
              !t.startsWith('-')) {
            final indent2 =
                lines[i + 1].length - lines[i + 1].trimLeft().length;
            lines[i + 1] = ' ' * indent2 + newSummary;
          }
        }
        break;
      }
    }
    outlineContent = lines.join('\n');
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
        // 以最新大纲内容为准重新解析，与 DB 中的旧数据比较
        final freshChapters = _parseEvents(outlineContent);
        final dirty =
            freshChapters.length != rows.length ||
            freshChapters.asMap().entries.any((entry) {
              final c = OutlineChapter.fromMap(rows[entry.key]);
              return c.eventTitle != entry.value.eventTitle ||
                  c.eventIndex != entry.value.eventIndex;
            });
        if (dirty) {
          // 大纲已更新：自动重同步章节结构（保留已完成的正文内容），
          // 确保事件列表始终与大纲标题一致
          await resync();
        } else {
          chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
        }
      } else {
        chapters = _parseEvents(outlineContent);
        await OutlineChapterDbHelper().batchInsert(
          chapters.map((c) => c.toMap()).toList(),
        );
        await _reloadChapters();
      }
    } catch (_) {}
    isLoading = false;
  }

  /// 开始生成章节内容
  Future<void> startWrite(
    BuildContext context,
    OutlineChapter ch,
    VoidCallback onUpdate,
  ) async {
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
    final prompt = ChapterWritePromptTemplate.buildWritePrompt(
      outline: outline,
      outlineExcerpt: _buildLocalOutline(ch),
      ch: ch,
      prevContent: prevContent,
      prevEnding: _buildPrevEnding(ch, allChapters),
      storyState: freshRow?['story_state'] as String? ?? '',
      characters: _renderCharactersText(directChars),
      foreshadows: freshRow?['foreshadows'] as String? ?? '',
      parentMajor: _findParentMajor(ch),
      prevEventTitle: _findAdjacentTitle(ch, -1),
      nextEvents: _findNextEvents(ch, 3),
      isLastOfMajor: _isLastMinorOfMajor(ch),
      minWords: settings.chapterSetting.chapterMinWords,
      maxWords: settings.chapterSetting.chapterMaxWords,
    );

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
    reviewing = false;
    extractingStory = false;
    extractingProtagonist = false;
    _cancelled = false;
    _cancelToken = CancelToken();
    onUpdate();

    await OutlineChapterDbHelper().updateStatus(ch.id!, 'generating');

    try {
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
            'max_tokens': settings.chapterSetting.maxTokens,
            // 与大纲生成保持一致：关闭深度思考时显式禁用，避免思考抢占输出预算
            if (!settings.chapterSetting.enableThinking)
              'thinking': {'type': 'disabled'},
          },
          messages: messages,
          initialText: chapterBuffer.toString(),
          initialThinking: thinkingText,
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
        // 生成完成后插入 AI 审查修正（只修不合理处，不改变伏笔/剧情走向），
        // 审查失败或输出异常时保留原文
        if (!_cancelled) {
          reviewing = true;
          onUpdate();
          writingText = await _reviewChapter(
            ch: ch,
            content: writingText,
            prevEnding: _buildPrevEnding(ch, allChapters),
            characters: _renderCharactersText(directChars),
            onUpdate: onUpdate,
          );
          reviewing = false;
          onUpdate();
        }
        // 先落盘正文
        await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        // 账本/小结更新计入章节生成流程：基于修正后的正文提炼，
        // 完成后再把章节置为「已完成」，避免出现正文已生成但账本未更新的情况
        await _updateStoryState(ch, writingText, onUpdate: onUpdate);
        await _summarizeChapter(ch, writingText);
        final idx = chapters.indexWhere((c) => c.id == ch.id);
        if (idx != -1) {
          chapters[idx] = chapters[idx].copyWith(
            content: writingText,
            status: 'completed',
          );
        }
      } else if (!_cancelled) {
        // 工具循环耗尽仍未产出正文，恢复待生成避免卡在 generating
        await OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
      }
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (writingText.isNotEmpty) {
          await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        } else {
          await OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
        }
      }
    } finally {
      _cancelToken = null;
      isWriting = false;
      writingId = null;
      onUpdate();
    }
  }

  /// 单轮流式请求：累积正文并收集流式 tool_calls 增量
  ///
  /// [initialText] / [initialThinking] 前几轮已生成的正文/思考，仅用于流式展示时
  /// 拼接显示，返回的 `content` 仍只包含本轮新增内容，由调用方累积保存。
  Future<_StreamChapterResult> _streamChapterWithTools({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required VoidCallback onUpdate,
    String initialText = '',
    String initialThinking = '',
  }) async {
    final completer = Completer<void>();
    final content = StringBuffer();
    final thinking = StringBuffer();
    final toolAccs = <int, _ToolCallAcc>{};
    await _service.streamWrite(
      apiKey: apiKey,
      apiParams: {...apiParams, 'stream': true},
      messages: messages,
      tools: characterLookupTools,
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
    return _StreamChapterResult(
      content: content.toString(),
      toolCalls: toolAccs.values.where((t) => t.name.isNotEmpty).toList(),
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

  /// 批量清空已生成的内容（正文 + AI 小结），恢复为待生成状态
  Future<void> resetChapters(List<OutlineChapter> items) async {
    for (final ch in items) {
      if (ch.id == null) continue;
      await OutlineChapterDbHelper().updateContent(ch.id!, '');
      // 同时清空 AI 小结，避免下一章承接已删除的内容
      await OutlineChapterDbHelper().updateAiSummary(ch.id!, '');
      final idx = chapters.indexWhere((c) => c.id == ch.id);
      if (idx != -1) {
        chapters[idx] = chapters[idx].copyWith(
          content: '',
          status: 'pending',
          aiSummary: '',
        );
      }
    }
  }

  /// 保存手动编辑后的章节内容
  Future<void> saveChapterContent(OutlineChapter ch, String content) async {
    await OutlineChapterDbHelper().updateContent(ch.id!, content);
    // 用户改写了正文（可能重写伏笔/结局），与章节生成一致：账本/小结更新完成才算保存完成，
    // 避免后续章节沿用基于旧正文提炼的状态
    if (content.trim().isNotEmpty) {
      await _updateStoryState(ch, content);
      await _summarizeChapter(ch, content);
    }
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(
        content: content,
        status: 'completed',
      );
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
    // 大纲已变化：同步重提伏笔清单（失败静默），与保存流程一体，
    // 避免后续章节注入过期伏笔
    await _refreshForeshadows();
  }

  /// 依据最新大纲内容重提伏笔清单并写回记录（失败静默，不影响主流程）
  Future<void> _refreshForeshadows() async {
    if (outline.id == null) return;
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return;
      final text = await OutlineFormatService().extractForeshadows(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.chapterSetting.model,
          'temperature': 0.3,
          'max_tokens': settings.chapterSetting.maxTokens,
        },
        outlineContent: outlineContent,
      );
      if (text.trim().isNotEmpty) {
        await OutlineRecordDbHelper().update(outline.id!, {
          'foreshadows': text,
        });
      }
    } catch (_) {
      // 提炼失败不影响章节生成，静默跳过
    }
  }

  void stopWrite() {
    _cancelled = true;
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  void dispose() {
    stopWrite();
  }

  Future<void> _reloadChapters() async {
    final rows = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
    chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
  }

  List<OutlineChapter> _parseEvents(String content) {
    final lines = content.split('\n');
    final result = <OutlineChapter>[];
    int eventIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      // 大事件标题行：允许可选的 ══ 包裹（模型输出常省略）、
      // 编号为数字/占位符 X/中文数字/带圈数字
      final majorMatch = RegExp(
        r'^\s*═*\s*(?:大事件|Major|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]\s*(.+?)\s*═*\s*$',
      ).firstMatch(trimmed);
      if (majorMatch != null) {
        eventIndex++;
        final title = majorMatch.group(1)?.trim() ?? '大事件$eventIndex';
        result.add(
          OutlineChapter(
            outlineId: outline.id!,
            eventIndex: eventIndex,
            eventType: 'major',
            eventTitle: title,
          ),
        );
        continue;
      }
      if (trimmed.startsWith('══') && trimmed.endsWith('══')) {
        continue;
      }
      // 小事件标题行：允许 ○ / - / • / * / · 等符号（模型输出不固定）、
      // 编号为数字/占位符 X/中文数字/带圈数字，分隔符限定冒号避免误吞概要
      final minorMatch = RegExp(
        r'^\s*[○\-•*\·]?\s*(?:小事件|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]\s*(.+?)\s*$',
      ).firstMatch(trimmed);
      if (minorMatch != null) {
        eventIndex++;
        final title = minorMatch.group(1)?.trim() ?? '小事件$eventIndex';
        result.add(
          OutlineChapter(
            outlineId: outline.id!,
            eventIndex: eventIndex,
            eventType: 'minor',
            eventTitle: title,
          ),
        );
        continue;
      }
      if (result.isNotEmpty &&
          trimmed.isNotEmpty &&
          !trimmed.startsWith('══') &&
          !trimmed.startsWith('○') &&
          !trimmed.startsWith('-')) {
        // 跳过可能的幕标题（如「第一幕：开端」），避免污染上一事件概要
        if (RegExp(r'^第[一二三四五六0-9]+幕').hasMatch(trimmed)) continue;
        final last = result.last;
        // 累积多行概要（模型输出的事件概述常为多行）
        final summary = last.eventSummary.isEmpty
            ? trimmed
            : '${last.eventSummary}\n$trimmed';
        result[result.length - 1] = last.copyWith(eventSummary: summary);
      }
    }

    if (result.isEmpty) {
      result.add(
        OutlineChapter(
          outlineId: outline.id!,
          eventIndex: 1,
          eventType: 'major',
          eventTitle: '正文',
        ),
      );
    }

    return result;
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
          storyState: fresh?['story_state'] as String? ?? '',
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
  Future<void> _updateStoryState(
    OutlineChapter ch,
    String content, {
    VoidCallback? onUpdate,
  }) async {
    if (outline.id == null || content.trim().isEmpty) return;
    try {
      final settings = await _service.loadSettings();
      if (!settings.chapterSetting.enableStoryState) return;
      if (settings.apiKey.isEmpty) return;
      final fresh = await OutlineRecordDbHelper().getById(outline.id!);
      final prevState = fresh?['story_state'] as String? ?? '';
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
      await OutlineRecordDbHelper().update(outline.id!, {
        'story_state': newState.isEmpty ? prevState : newState,
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

      // 2) 对提炼结果执行一轮 AI 审查（遵循提炼约束，修正不合理处）
      final profileJson = jsonEncode({'protagonist': p});
      final reviewBuf = StringBuffer();
      final reviewThinkBuf = StringBuffer();
      var reviewThinkShown = 0; // 已追加到 thinkingText 的档案审查思考长度
      reviewing = true;
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
            reviewText = reviewBuf.toString();
            // 档案审查思考过程实时写入独立气泡，不再丢弃
            final t = reviewThinkBuf.toString();
            if (t.length > reviewThinkShown) {
              reviewThinking += t.substring(reviewThinkShown);
              reviewThinkShown = t.length;
            }
            onUpdate?.call();
          },
        );
      } finally {
        reviewing = false;
        onUpdate?.call();
      }
      // 从审查输出中解析【修正后档案】JSON；解析失败则沿用提炼结果
      const marker = '【修正后档案】';
      final cleaned = _stripMarkdownFence(reviewedRaw);
      if (cleaned.contains(marker)) {
        // 审查气泡只保留【审查意见】
        reviewText = cleaned.substring(0, cleaned.indexOf(marker)).trim();
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
  /// 按 `_parseEvents` 相同的规则逐行计数事件，用 [eventIndex] 直接定位
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
    // 与 _parseEvents 一致：大/小事件标题行各计一个事件，据此定位第 eventIndex 个事件所在行
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
  final List<_ToolCallAcc> toolCalls;
  _StreamChapterResult({required this.content, required this.toolCalls});
}

/// 流式 tool_calls 增量累积器（按 index 归并 id/name/arguments 分片）
class _ToolCallAcc {
  String id = '';
  String name = '';
  String arguments = '';
}
