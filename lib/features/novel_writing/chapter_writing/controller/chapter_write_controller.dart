import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/chapter_write_service.dart';
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
      // 起始：人物档案为空时，先从大纲提取主角（含 AI 补全缺失描述），其他人物由正文生成
      final fresh = await OutlineRecordDbHelper().getById(outline.id!);
      if ((fresh?['characters'] as String? ?? '').trim().isEmpty) {
        unawaited(_seedProtagonistFromOutline());
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

    final prevContent = await _loadPrevSummary(ch);
    // 读取最新的剧情状态、人物档案与伏笔清单（写章节期间可能已累积）
    final freshRow = await OutlineRecordDbHelper().getById(outline.id!);
    final allCharacters = _parseCharacters(
      freshRow?['characters'] as String? ?? '',
    );
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
      prevEnding: await _loadPrevEnding(ch),
      storyState: freshRow?['story_state'] as String? ?? '',
      characters: _renderCharactersText(directChars),
      foreshadows: freshRow?['foreshadows'] as String? ?? '',
      gapCount: _countMissingPrevs(ch),
      parentMajor: _findParentMajor(ch),
      prevEventTitle: _findAdjacentTitle(ch, -1),
      nextEvents: _findNextEvents(ch, 3),
      isLastOfMajor: _isLastMinorOfMajor(ch),
    );

    isWriting = true;
    writingId = ch.id;
    writingText = '';
    _cancelled = false;
    _cancelToken = CancelToken();
    onUpdate();

    await OutlineChapterDbHelper().updateStatus(ch.id!, 'generating');

    try {
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': settings.outlineSetting.chapterSystemPrompt.isNotEmpty
              ? settings.outlineSetting.chapterSystemPrompt
              : '你是一个专业的小说作家。',
        },
        {'role': 'user', 'content': prompt},
      ];
      // 多轮 function-calling：模型可先调用 get_character_profiles 查询人物档案再写作
      const maxRounds = 4;
      for (int round = 0; round < maxRounds; round++) {
        if (_cancelled) break;
        final result = await _streamChapterWithTools(
          apiKey: settings.apiKey,
          apiParams: {
            'model': settings.outlineSetting.model,
            'temperature': settings.outlineSetting.temperature,
            'max_tokens': settings.outlineSetting.maxTokens,
          },
          messages: messages,
          onUpdate: onUpdate,
        );
        if (_cancelled) break;
        if (result.toolCalls.isEmpty) {
          writingText = result.content;
          break;
        }
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
        await OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        final idx = chapters.indexWhere((c) => c.id == ch.id);
        if (idx != -1) {
          chapters[idx] = chapters[idx].copyWith(
            content: writingText,
            status: 'completed',
          );
        }
        // 后台提炼剧情状态账本（不阻塞、失败静默），供后续章节注入
        unawaited(_updateStoryState(ch, writingText));
        // 后台提炼整章小结（不阻塞、失败静默），供下一章开头承接
        unawaited(_summarizeChapter(ch, writingText));
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
  Future<_StreamChapterResult> _streamChapterWithTools({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    required VoidCallback onUpdate,
  }) async {
    final completer = Completer<void>();
    final content = StringBuffer();
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
          writingText = content.toString();
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
  Future<void> resetChapter(OutlineChapter ch) async {
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

  /// 保存手动编辑后的章节内容
  Future<void> saveChapterContent(OutlineChapter ch, String content) async {
    await OutlineChapterDbHelper().updateContent(ch.id!, content);
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(
        content: content,
        status: 'completed',
      );
    }
    // 用户改写了正文（可能重写伏笔/结局），后台同步刷新剧情状态账本与整章小结，
    // 避免后续章节沿用基于旧正文提炼的状态
    if (content.trim().isNotEmpty) {
      unawaited(_updateStoryState(ch, content));
      unawaited(_summarizeChapter(ch, content));
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

  /// 加载前文内容：只取最近 [recentCount] 个已完成事件的**完整正文**，
  /// 更早的事件用一行统计带过，避免提示词无限膨胀；取完整结尾保证与上文衔接。
  Future<String> _loadPrevSummary(OutlineChapter currentCh) async {
    if (currentCh.id == null) return '';
    final all = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
    final prevs = all
        .map((m) => OutlineChapter.fromMap(m))
        .where(
          (c) => c.status == 'completed' && c.eventIndex < currentCh.eventIndex,
        )
        .toList();
    if (prevs.isEmpty) return '故事刚开始，没有前文。';
    const recentCount = 4;
    final recent = prevs.length > recentCount
        ? prevs.sublist(prevs.length - recentCount)
        : prevs;
    final buf = StringBuffer();
    if (prevs.length > recent.length) {
      buf.writeln('（此前还有 ${prevs.length - recent.length} 个已完成事件，内容省略）');
      buf.writeln();
    }
    for (final c in recent) {
      final content = c.content.trim();
      buf.writeln('【${c.eventTitle}】');
      buf.writeln(content.isEmpty ? '（本章暂无正文内容）' : content);
      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// 上一章小结：紧邻当前事件的已完成事件。
  /// 优先使用 AI 提炼的整章小结；小结尚未生成（快速连写/旧数据）时回退正文末尾 300 字。
  Future<String> _loadPrevEnding(OutlineChapter currentCh) async {
    final all = await OutlineChapterDbHelper().getByOutlineId(outline.id!);
    final ordered = all.map((m) => OutlineChapter.fromMap(m)).toList()
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
          'model': settings.outlineSetting.model,
          'temperature': 0.3,
          'max_tokens': 400,
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

  /// 当前事件之前尚未完成的事件数量（乱序生成提示）
  int _countMissingPrevs(OutlineChapter ch) => chapters
      .where((c) => c.eventIndex < ch.eventIndex && c.status != 'completed')
      .length;

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

  /// 后台提炼剧情状态账本：调用轻量接口把「前序状态 + 当前人物档案 + 本章正文」
  /// 合并为最新状态与人物档案，写入 outline_records。
  /// 仅在设置开启时执行；失败静默，不影响章节生成流程。
  /// 性格字段由代码层按姓名回填保留，AI 不会覆盖用户维护的性格。
  Future<void> _updateStoryState(OutlineChapter ch, String content) async {
    if (outline.id == null || content.trim().isEmpty) return;
    try {
      final settings = await _service.loadSettings();
      if (!settings.outlineSetting.enableStoryState) return;
      if (settings.apiKey.isEmpty) return;
      final fresh = await OutlineRecordDbHelper().getById(outline.id!);
      final prevState = fresh?['story_state'] as String? ?? '';
      final oldChars = _parseCharacters(fresh?['characters'] as String? ?? '');
      final result = await _service.extractStoryState(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.outlineSetting.model,
          'temperature': 0.3,
          'max_tokens': 800,
        },
        prevState: prevState,
        characters: oldChars,
        eventTitle: ch.eventTitle,
        eventSummary: ch.eventSummary,
        chapterContent: content,
      );
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

  /// 起始从大纲提取主角人物档案：基于主角完整人设调用 AI 提炼并补全缺失描述，
  /// 性格留空由用户维护；其他人物在写作过程中根据正文由提炼接口生成。
  Future<void> _seedProtagonistFromOutline() async {
    if (outline.id == null) return;
    final setting = outline.protagonist.trim();
    if (setting.isEmpty) return; // 无主角设定（如匹配大纲格式的旧记录）则跳过
    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) return;
      final result = await _service.extractProtagonist(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.outlineSetting.model,
          'temperature': 0.3,
          'max_tokens': 800,
        },
        protagonistSetting: setting,
        outlineContent: outlineContent,
      );
      final decoded = _extractJson(result);
      if (decoded == null) return;
      final p = decoded['protagonist'];
      if (p is! Map<String, dynamic>) return;
      final profile = CharacterProfile(
        name: (p['name'] as String? ?? '').trim(),
        description: (p['description'] as String? ?? '').trim(),
        abilities: (p['abilities'] as String? ?? '').trim(),
        personality: '', // 性格仅用户维护
        isProtagonist: true, // 主角标记：档案直接注入章节提示词
      );
      if (profile.name.isEmpty) return;
      await OutlineRecordDbHelper().update(outline.id!, {
        'characters': jsonEncode([profile.toJson()]),
      });
    } catch (_) {
      // 提取失败静默跳过，后续可在账本页手动维护
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
  /// 只取「当前事件所属大事件」的完整块（大事件标题+概述+其下全部小事件），
  /// 不取整幕——每幕大事件很多，整幕注入会撑大提示词；后续衔接由
  /// 【后续事件】单独注入。找不到所属大事件时回退整篇大纲。
  String _buildLocalOutline(OutlineChapter ch) {
    final lines = outlineContent.split('\n');
    final majorRe = RegExp(
      r'^\s*═*\s*(?:大事件|Major|事件)\s*(?:[0-9Xx]|①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩|[一二三四五六七八九十]+)?\s*[：:]',
    );
    final actRe = RegExp(r'^\s*══\s*第[一二三四五六0-9]+幕[^═]*══');
    int curIdx = -1;
    for (int i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.contains(ch.eventTitle) &&
          (t.startsWith('══') ||
              t.startsWith('○') ||
              t.startsWith('-') ||
              t.startsWith('•') ||
              t.startsWith('*'))) {
        curIdx = i;
        break;
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
