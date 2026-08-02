import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/chapter_write_service.dart';
import '../../shared/domain/outline_record.dart';
import '../../shared/domain/outline_chapter.dart';
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

  bool get isAllCompleted => chapters.every((c) => c.status == 'completed');
  int get completedCount =>
      chapters.where((c) => c.status == 'completed').length;

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
    if (ch.id == null) return;
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
    final prompt = ChapterWritePromptTemplate.buildWritePrompt(
      outline: outline,
      outlineContent: outlineContent,
      ch: ch,
      prevContent: prevContent,
      parentMajor: _findParentMajor(ch),
      prevEventTitle: _findAdjacentTitle(ch, -1),
      nextEventTitle: _findAdjacentTitle(ch, 1),
    );

    isWriting = true;
    writingId = ch.id;
    writingText = '';
    _cancelToken = CancelToken();
    onUpdate();

    await OutlineChapterDbHelper().updateStatus(ch.id!, 'generating');

    try {
      await _service.streamWrite(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.outlineSetting.model,
          'temperature': settings.outlineSetting.temperature,
          'max_tokens': settings.outlineSetting.maxTokens,
          'stream': true,
        },
        messages: [
          {
            'role': 'system',
            'content': settings.outlineSetting.chapterSystemPrompt.isNotEmpty
                ? settings.outlineSetting.chapterSystemPrompt
                : '你是一个专业的小说作家。',
          },
          {'role': 'user', 'content': prompt},
        ],
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;
          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;
          final text = delta['content'] as String?;
          if (text != null) {
            writingText += text;
            onUpdate();
          }
        },
        onDone: () {
          _cancelToken = null;
          if (writingText.isNotEmpty) {
            OutlineChapterDbHelper().updateContent(ch.id!, writingText);
            final idx = chapters.indexWhere((c) => c.id == ch.id);
            if (idx != -1) {
              chapters[idx] = chapters[idx].copyWith(
                content: writingText,
                status: 'completed',
              );
            }
          }
          isWriting = false;
          writingId = null;
          onUpdate();
        },
        onError: (_) {
          _cancelToken = null;
          if (writingText.isNotEmpty) {
            OutlineChapterDbHelper().updateContent(ch.id!, writingText);
          } else {
            OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
          }
          isWriting = false;
          writingId = null;
          onUpdate();
        },
      );
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (writingText.isNotEmpty) {
          OutlineChapterDbHelper().updateContent(ch.id!, writingText);
        } else {
          await OutlineChapterDbHelper().updateStatus(ch.id!, 'pending');
        }
      }
      isWriting = false;
      writingId = null;
      onUpdate();
    }
  }

  /// 清空某章节已生成的内容，恢复为待生成状态
  Future<void> resetChapter(OutlineChapter ch) async {
    await OutlineChapterDbHelper().updateContent(ch.id!, '');
    final idx = chapters.indexWhere((c) => c.id == ch.id);
    if (idx != -1) {
      chapters[idx] = chapters[idx].copyWith(content: '', status: 'pending');
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
      // 大事件标题行：允许可选的 ══ 包裹（模型输出常省略）、编号为数字或占位符 X
      final majorMatch = RegExp(
        r'^\s*═*\s*(大事件\s*[0-9Xx]*|事件\s*[0-9Xx]*|Major\s*[0-9Xx]*)\s*[：:]\s*(.+?)\s*═*\s*$',
      ).firstMatch(trimmed);
      if (majorMatch != null) {
        eventIndex++;
        final title = majorMatch.group(2)?.trim() ?? '大事件$eventIndex';
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
      // 小事件标题行：允许 ○ / - / • / * 等符号（模型输出不固定），编号为数字或占位符 X
      final minorMatch = RegExp(
        r'^\s*[○\-•*]?\s*(小事件\s*[0-9Xx]*|事件\s*[0-9Xx]*)\s*[：:]\s*(.+?)\s*$',
      ).firstMatch(trimmed);
      if (minorMatch != null) {
        eventIndex++;
        final title = minorMatch.group(2)?.trim() ?? '小事件$eventIndex';
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
    return prevs
        .map(
          (c) =>
              '【${c.eventTitle}】\n${c.content.substring(0, c.content.length > 200 ? 200 : c.content.length)}...',
        )
        .join('\n\n');
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
}
