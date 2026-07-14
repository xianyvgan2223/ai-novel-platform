import 'novel_db_helper.dart';
import '../entity/char_copy_story_entity.dart';

class CharCopyStoryDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<CharCopyStoryEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('char_copy_story_table', orderBy: 'id DESC');
    return maps.map((m) => CharCopyStoryEntity.fromMap(m)).toList();
  }

  Future<CharCopyStoryEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'char_copy_story_table',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return CharCopyStoryEntity.fromMap(maps.first);
  }

  Future<List<CharCopyStoryEntity>> getByCopyId(int copyId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'char_copy_story_table',
      where: 'copy_id = ?',
      whereArgs: [copyId],
    );
    return maps.map((m) => CharCopyStoryEntity.fromMap(m)).toList();
  }

  Future<List<CharCopyStoryEntity>> getByCharId(int charId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'char_copy_story_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
    return maps.map((m) => CharCopyStoryEntity.fromMap(m)).toList();
  }

  /// 根据角色ID和副本ID获取单人故事
  Future<CharCopyStoryEntity?> getByCharIdAndCopyId(
    int charId,
    int copyId,
  ) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'char_copy_story_table',
      where: 'char_id = ? AND copy_id = ?',
      whereArgs: [charId, copyId],
    );
    if (maps.isEmpty) return null;
    return CharCopyStoryEntity.fromMap(maps.first);
  }

  Future<int> insert(CharCopyStoryEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('char_copy_story_table', entity.toMap());
  }

  Future<int> update(CharCopyStoryEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'char_copy_story_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'char_copy_story_table',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteByCharId(int charId) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'char_copy_story_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
  }
}
