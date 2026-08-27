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
      {'story_state': storyState, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除某个大纲的所有章节
  Future<void> deleteByOutlineId(int outlineId) async {
    final db = await database;
    await db.delete(
      'outline_chapters',
      where: 'outline_id = ?',
      whereArgs: [outlineId],
    );
  }
}
