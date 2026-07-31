import 'package:sqflite/sqflite.dart';
import '../../../../../core/db/database_helper.dart';

/// 大纲生成记录数据库操作
class OutlineRecordDbHelper {
  static final OutlineRecordDbHelper _instance = OutlineRecordDbHelper._internal();
  factory OutlineRecordDbHelper() => _instance;
  OutlineRecordDbHelper._internal();

  Future<Database> get database => DatabaseHelper.database;

  /// 插入一条大纲记录
  Future<int> insert(Map<String, dynamic> record) async {
    final db = await database;
    return db.insert('outline_records', record);
  }

  /// 获取所有大纲记录（按时间倒序）
  Future<List<Map<String, dynamic>>> getAll() async {
    final db = await database;
    return db.query('outline_records', orderBy: 'created_at DESC');
  }

  /// 获取单条大纲记录
  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await database;
    final results = await db.query(
      'outline_records',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// 更新大纲记录内容
  Future<void> update(int id, Map<String, dynamic> record) async {
    final db = await database;
    await db.update('outline_records', record, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除大纲记录
  Future<void> delete(int id) async {
    final db = await database;
    await db.delete('outline_records', where: 'id = ?', whereArgs: [id]);
  }
}
