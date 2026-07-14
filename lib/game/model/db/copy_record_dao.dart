import 'novel_db_helper.dart';
import '../entity/copy_record_entity.dart';

class CopyRecordDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<CopyRecordEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('copy_record_table', orderBy: 'id DESC');
    return maps.map((m) => CopyRecordEntity.fromMap(m)).toList();
  }

  Future<CopyRecordEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'copy_record_table',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return CopyRecordEntity.fromMap(maps.first);
  }

  Future<List<CopyRecordEntity>> getByCopyId(int copyId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'copy_record_table',
      where: 'copy_id = ?',
      whereArgs: [copyId],
    );
    return maps.map((m) => CopyRecordEntity.fromMap(m)).toList();
  }

  /// 获取指定副本的最新一条记录
  Future<CopyRecordEntity?> getLatestByCopyId(int copyId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'copy_record_table',
      where: 'copy_id = ?',
      whereArgs: [copyId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return CopyRecordEntity.fromMap(maps.first);
  }

  Future<int> insert(CopyRecordEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('copy_record_table', entity.toMap());
  }

  Future<int> update(CopyRecordEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'copy_record_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'copy_record_table',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
