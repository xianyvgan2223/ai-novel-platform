// lib/services/memo_service.dart
// 备忘录数据服务 — memos 表 CRUD

import '../models/memo.dart';
import 'database_helper.dart';

class MemoService {
  /// 查询全部备忘录（按创建时间倒序）
  static Future<List<Memo>> getAll() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('memos', orderBy: 'created_at DESC');
    return rows.map((r) => Memo.fromMap(r)).toList();
  }

  /// 按分类查询
  static Future<List<Memo>> getByCategory(String category) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'memos',
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => Memo.fromMap(r)).toList();
  }

  /// 查询未完成的备忘录
  static Future<List<Memo>> getActive() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'memos',
      where: 'is_completed = 0',
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => Memo.fromMap(r)).toList();
  }

  /// 新增备忘录
  static Future<int> insert(Memo memo) async {
    final db = await DatabaseHelper.database;
    return db.insert('memos', memo.toMap());
  }

  /// 更新备忘录
  static Future<void> update(Memo memo) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'memos',
      memo.toMap(),
      where: 'id = ?',
      whereArgs: [memo.id],
    );
  }

  /// 切换完成状态
  static Future<void> toggleCompletion(int id, bool isCompleted) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'memos',
      {
        'is_completed': isCompleted ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除备忘录
  static Future<void> delete(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete('memos', where: 'id = ?', whereArgs: [id]);
  }

  /// 批量删除
  static Future<void> deleteAll(List<int> ids) async {
    final db = await DatabaseHelper.database;
    final placeholders = ids.map((_) => '?').join(',');
    await db.delete('memos', where: 'id IN ($placeholders)', whereArgs: ids);
  }
}
