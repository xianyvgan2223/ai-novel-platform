import 'domain/outline_chapter.dart';

/// 从大纲正文解析事件列表（大事件 / 小事件）。
///
/// 「大纲转章节」与「大纲编辑」共用同一套解析规则，保证两个入口看到的章节结构一致：
/// - 大事件：`══...══` 包裹行，或「大事件N：标题」（编号支持数字/占位符 X/
///   中文数字/带圈数字，模型输出常省略 `══`）
/// - 小事件：`○ / - / • / * / ·` 前缀行，或「小事件N：标题」
/// - 事件标题之后的非标题行累积为该事件的概要（模型输出的事件概述常为多行）
/// - 幕标题（如「第一幕：开端」）会被跳过，避免污染上一事件的概要
///
/// 未解析到任何事件时返回单个「正文」大事件，保证调用方始终有可编辑项。
/// 返回的章节均未入库（[OutlineChapter.id] 为 null），由调用方批量插入。
List<OutlineChapter> parseOutlineEvents(
  String content, {
  required int outlineId,
}) {
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
          outlineId: outlineId,
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
          outlineId: outlineId,
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
        outlineId: outlineId,
        eventIndex: 1,
        eventType: 'major',
        eventTitle: '正文',
      ),
    );
  }

  return result;
}
