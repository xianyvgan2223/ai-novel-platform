import 'package:sqflite/sqflite.dart';

import '../../../core/db/database_helper.dart';
import 'domain/outline_chapter.dart';
import 'outline_event_parser.dart';

/// 结构校正结果（供日志与「干跑」报告使用）
class OutlineChapterSyncResult {
  final int updated;
  final int inserted;
  final int kept;
  final int dropped;

  const OutlineChapterSyncResult({
    this.updated = 0,
    this.inserted = 0,
    this.kept = 0,
    this.dropped = 0,
  });

  int get total => updated + inserted + kept;

  @override
  String toString() =>
      '更新 \$updated / 新增 \$inserted / 保留 \$kept / 清理空占位 \$dropped';
}

/// 按大纲正文校正 outline_chapters 结构（「大纲编辑」与「大纲转章节」共用）。
///
/// 与旧实现（先 deleteByOutlineId 整表删除、再 batchInsert 重建）的关键差别是
/// **不再整表重建**：
/// - 命中的旧行原地 UPDATE event_index / event_type，行 id 保持不变，
///   因此 content（已生成的正文）/ ai_summary / story_state / status 全部原地保留；
/// - 只有新增的事件才 INSERT；
/// - 未被新结构命中的旧行：带数据的绝不删除（追加到末尾保留），
///   仅清理完全没有数据的占位行；
/// - 整个过程包在一个事务里，并在提交前断言正文总量没有减少，异常自动回滚。
///
/// 这样即使解析规则再次出错，最坏结果也只是结构不对，不会丢正文。
Future<OutlineChapterSyncResult> reconcileOutlineChapters({
  required int outlineId,
  required String content,
}) async {
  final parsed = parseOutlineEvents(content, outlineId: outlineId);
  final db = await DatabaseHelper.database;
  return db.transaction((txn) async {
    final rawRows = await txn.query(
      'outline_chapters',
      where: 'outline_id = ?',
      whereArgs: <Object?>[outlineId],
      orderBy: 'event_index ASC',
    );
    final old = rawRows.map(OutlineChapter.fromMap).toList();
    final charsBefore = await _contentChars(txn, outlineId);

    // 标题 → 队列：同名事件按出现次序一一配对，避免重复标题互相覆盖
    final buckets = <String, List<OutlineChapter>>{};
    for (final c in old) {
      buckets.putIfAbsent(c.eventTitle.trim(), () => <OutlineChapter>[]).add(c);
    }

    final now = DateTime.now().toIso8601String();
    final usedIds = <int>{};
    var updated = 0;
    var inserted = 0;
    for (final row in parsed) {
      final queue = buckets[row.eventTitle.trim()];
      final hit = (queue != null && queue.isNotEmpty)
          ? queue.removeAt(0)
          : null;
      if (hit == null || hit.id == null) {
        await txn.insert('outline_chapters', row.toMap());
        inserted++;
        continue;
      }
      final hitId = hit.id!;
      usedIds.add(hitId);
      // 正文里确实没写概要（解析结果为空）时不覆盖库里已有的概要：
      // 旧版写回失败时用户改的概要只存在于库里，这里不能抹掉
      final summary = row.eventSummary.trim().isEmpty
          ? hit.eventSummary
          : row.eventSummary;
      if (hit.eventIndex != row.eventIndex ||
          hit.eventType != row.eventType ||
          hit.eventSummary != summary) {
        await txn.update(
          'outline_chapters',
          <String, Object?>{
            'event_index': row.eventIndex,
            'event_type': row.eventType,
            'event_summary': summary,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: <Object?>[hitId],
        );
        updated++;
      }
    }

    var kept = 0;
    var dropped = 0;
    var tail = parsed.length;
    for (final c in old) {
      final id = c.id;
      if (id == null || usedIds.contains(id)) continue;
      final hasData =
          c.content.trim().isNotEmpty ||
          c.aiSummary.trim().isNotEmpty ||
          c.storyState.trim().isNotEmpty;
      if (!hasData) {
        await txn.delete(
          'outline_chapters',
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
        dropped++;
        continue;
      }
      // 带数据的孤儿行：绝不删除，追加到末尾保留（宁可多一行也不能丢正文）
      tail++;
      await txn.update(
        'outline_chapters',
        <String, Object?>{'event_index': tail, 'updated_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      kept++;
    }

    final charsAfter = await _contentChars(txn, outlineId);
    if (charsAfter < charsBefore) {
      throw StateError('章节正文总量从 \$charsBefore 降到 \$charsAfter，已回滚本次结构校正');
    }
    return OutlineChapterSyncResult(
      updated: updated,
      inserted: inserted,
      kept: kept,
      dropped: dropped,
    );
  });
}

Future<int> _contentChars(Transaction txn, int outlineId) async {
  final rows = await txn.rawQuery(
    'SELECT IFNULL(SUM(LENGTH(content)), 0) AS n '
    'FROM outline_chapters WHERE outline_id = ?',
    <Object?>[outlineId],
  );
  final n = rows.isEmpty ? null : rows.first['n'];
  return n is int ? n : 0;
}
