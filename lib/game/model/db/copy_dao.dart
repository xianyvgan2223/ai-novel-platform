import 'novel_db_helper.dart';
import '../entity/copy_entity.dart';

class CopyDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<CopyEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('copy_table', orderBy: 'id DESC');
    return maps.map((m) => CopyEntity.fromMap(m)).toList();
  }

  Future<CopyEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('copy_table', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CopyEntity.fromMap(maps.first);
  }

  Future<int> insert(CopyEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('copy_table', entity.toMap());
  }

  Future<int> update(CopyEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'copy_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('copy_table', where: 'id = ?', whereArgs: [id]);
  }

  /// 获取正在运行的副本列表
  Future<List<CopyEntity>> getRunningCopies() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'copy_table',
      where: 'is_running = ?',
      whereArgs: [1],
      orderBy: 'id DESC',
    );
    return maps.map((m) => CopyEntity.fromMap(m)).toList();
  }

  /// 获取有未读记录的副本列表
  Future<List<CopyEntity>> getUnreadCopies() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'copy_table',
      where: 'unread_record = ?',
      whereArgs: [1],
      orderBy: 'id DESC',
    );
    return maps.map((m) => CopyEntity.fromMap(m)).toList();
  }

  /// 将指定副本标记为已读
  Future<int> markAsRead(int id) async {
    final db = await _dbHelper.database;
    return await db.update(
      'copy_table',
      {'unread_record': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
