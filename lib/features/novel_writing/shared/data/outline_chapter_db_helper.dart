import 'package:sqflite/sqflite.dart';
import '../../../../../core/db/database_helper.dart';

/// 大纲章节数据库操作
class OutlineChapterDbHelper {
  static final OutlineChapterDbHelper _instance =
      OutlineChapterDbHelper._internal();
  factory OutlineChapterDbHelper() => _instance;
  OutlineChapterDbHelper._internal();

  Future<Database> get database => DatabaseHelper.database;

  /// 批量插入事件列表（生成大纲后预填章节占位）
  Future<void> batchInsert(List<Map<String, dynamic>> rows) async {
    final db = await database;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('outline_chapters', row);
    }
    await batch.commit(noResult: true);
  }

  /// 获取某个大纲的所有章节
  Future<List<Map<String, dynamic>>> getByOutlineId(int outlineId) async {
    final db = await database;
    return db.query(
      'outline_chapters',
      where: 'outline_id = ?',
      whereArgs: [outlineId],
      orderBy: 'event_index ASC',
    );
  }

  /// 按大纲分组统计章节数（供「大纲编辑」小说卡片显示进度）：
  /// 返回 outlineId -> (total: 章节总数, completed: 已完成数)。
  /// 该小说还没解析过章节时不返回条目。
  Future<Map<int, ({int total, int completed})>> getStatsByOutline() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT outline_id, COUNT(*) AS total, '
      "SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) AS completed "
      'FROM outline_chapters GROUP BY outline_id',
    );
    final result = <int, ({int total, int completed})>{};
    for (final row in rows) {
      final id = row['outline_id'] as int?;
      if (id == null) continue;
      result[id] = (
        total: (row['total'] as int?) ?? 0,
        completed: (row['completed'] as int?) ?? 0,
      );
    }
    return result;
  }

  /// 获取单条章节
  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await database;
    final results = await db.query(
      'outline_chapters',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// 更新章节内容（有内容则视为已完成；清空内容则恢复待生成）。
  /// 注意：清空内容时必须把 status 改回 pending，否则 DB 重载后
  /// 会出现「内容已删但状态仍显示已生成」的问题。
  Future<void> updateContent(int id, String content) async {
    final db = await database;
    await db.update(
      'outline_chapters',
      {
        'content': content,
        'status': content.trim().isEmpty ? 'pending' : 'completed',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新状态
  Future<void> updateStatus(int id, String status) async {
    final db = await database;
    await db.update(
      'outline_chapters',
      {'status': status, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新章节标题和大纲概要
  Future<void> updateSummary(
    int id,
    String eventTitle,
    String eventSummary,
  ) async {
    final db = await database;
    await db.update(
      'outline_chapters',
      {
        'event_title': eventTitle,
        'event_summary': eventSummary,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新 AI 提炼的整章小结
  Future<void> updateAiSummary(int id, String aiSummary) async {
    final db = await database;
    await db.update(
      'outline_chapters',
      {'ai_summary': aiSummary, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新本章独立的剧情账本（story_state 列）
  Future<void> updateStoryState(int id, String storyState) async {
    final db = await database;
    await db.update(
      'outline_chapters',
      {
        'story_state': storyState,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 插入一个新增事件（「大纲编辑」页添加大事件 / 小事件），返回新行 id。
  ///
  /// 事件行由调用方决定内容：正文 / AI 小结 / 剧情账本一律留空，
  /// 状态与 [OutlineChapter] 的默认值一致（新事件本来就是「待生成」）。
  Future<int> insertEvent({
    required int outlineId,
    required int eventIndex,
    required String eventType,
    required String eventTitle,
    required String eventSummary,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.insert('outline_chapters', {
      'outline_id': outlineId,
      'event_index': eventIndex,
      'event_type': eventType,
      'event_title': eventTitle,
      'event_summary': eventSummary,
      'content': '',
      'status': 'pending',
      'ai_summary': '',
      'story_state': '',
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 批量改写事件序号（增删事件后按最终结构重新编号）。
  ///
  /// 表上没有 (outline_id, event_index) 唯一约束，逐条 update 不会撞键；
  /// 仍统一放进一个事务：序号是「可排序」的唯一依据，写到一半失败会留下
  /// 重复序号的半截结构。
  Future<void> updateEventIndices(Map<int, int> indexById) async {
    if (indexById.isEmpty) return;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final e in indexById.entries) {
      batch.update(
        'outline_chapters',
        {'event_index': e.value, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 删除单个事件（「大纲编辑」页删除事件，已确认可丢正文时调用）。
  ///
  /// 与 [deleteByOutlineId] 的区别：只删一行，且调用方须已确认该行没有要保留的正文。
  Future<void> deleteById(int id) async {
    final db = await database;
    await db.delete('outline_chapters', where: 'id = ?', whereArgs: [id]);
  }

  /// 删除某个大纲的所有章节（**破坏性，已不再用于结构重建**）。
  ///
  /// 结构校正请改用 [reconcileOutlineChapters]：它原地更新行、保留行 id，
  /// 因而正文 / AI 小结 / 剧情账本不会丢；本方法一旦误用（例如解析失败后
  /// 传空列表），会把整本小说的正文一次删光。
  Future<void> deleteByOutlineId(int outlineId) async {
    final db = await database;
    await db.delete(
      'outline_chapters',
      where: 'outline_id = ?',
      whereArgs: [outlineId],
    );
  }
}
