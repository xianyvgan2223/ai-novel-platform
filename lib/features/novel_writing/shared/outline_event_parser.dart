import 'domain/outline_chapter.dart';
import 'outline_event_syntax.dart';

/// 从大纲正文解析事件列表（大事件 / 小事件）。
///
/// 「大纲转章节」与「大纲编辑」共用同一套解析规则，保证两个入口看到的章节结构一致。
/// 行识别（含编号、markdown 前缀、══ 包裹的容错）统一由 [classifyOutlineLine] 提供，
/// **本文件不再自行维护正则**——历史上这里手写的副本只认一位编号，导致
/// `大事件10：` 起的大事件整体丢失。
///
/// - 大事件：`══...══` 包裹行，或「大事件N：标题」
/// - 小事件：`○ / - / • / * / ·` 前缀行，或「小事件N：标题」
/// - 事件标题之后的非标题行累积为该事件的概要（模型输出的事件概述常为多行）
/// - 幕标题（如「第一幕：开端」）与纯装饰行会被跳过，避免污染上一事件的概要
///
/// 边界只认**被 [classifyOutlineLine] 识别出来的事件行 / 幕标题 / 装饰行**：
/// 概述里以 `-` 开头的列表项（如「- 旧铁条」）属于概要内容，不再被排除——
/// 否则「大纲转章节 / 大纲编辑」看到的概述会比正文少几行（与局部重新生成的
/// `_parseRecordActs` 规则也不一致：那边一直把 `-` 行算进概述）。
///
/// 未解析到任何事件时返回单个「正文」大事件，保证调用方始终有可编辑项。
/// 返回的章节均未入库（[OutlineChapter.id] 为 null），由调用方批量插入。
List<OutlineChapter> parseOutlineEvents(
  String content, {
  required int outlineId,
}) {
  final result = <OutlineChapter>[];
  var eventIndex = 0;

  for (final raw in content.split('\n')) {
    final trimmed = raw.trim();
    final line = classifyOutlineLine(raw);

    if (line.isEvent) {
      eventIndex++;
      result.add(
        OutlineChapter(
          outlineId: outlineId,
          eventIndex: eventIndex,
          eventType: line.isMajor ? 'major' : 'minor',
          eventTitle: line.title,
        ),
      );
      continue;
    }

    // 幕标题与纯 ══ 装饰行：既不作为事件，也不并入上一事件的概要
    if (line.isAct || line.kind == OutlineLineKind.decoration) continue;

    if (result.isNotEmpty && trimmed.isNotEmpty) {
      final last = result.last;
      // 累积多行概要（模型输出的事件概述常为多行；含 `-` 列表项）
      final summary = last.eventSummary.isEmpty
          ? trimmed
          : '${last.eventSummary}\n$trimmed';
      result[result.length - 1] = last.copyWith(eventSummary: summary);
    }
  }

  if (result.isEmpty) {
    result.add(
      OutlineChapter(
        outlineId: outlineId,
        eventIndex: 1,
        eventType: 'major',
        eventTitle: '正文',
      ),
    );
  }

  return result;
}
