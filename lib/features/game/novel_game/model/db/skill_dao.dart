import 'novel_db_helper.dart';
import '../entity/skill_entity.dart';

class SkillDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<SkillEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('skill_table', orderBy: 'id DESC');
    return maps.map((m) => SkillEntity.fromMap(m)).toList();
  }

  Future<SkillEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'skill_table',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return SkillEntity.fromMap(maps.first);
  }

  Future<List<SkillEntity>> getByCharId(int charId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'skill_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
    return maps.map((m) => SkillEntity.fromMap(m)).toList();
  }

  /// 根据副本ID获取所有技能
  Future<List<SkillEntity>> getByCopyId(int copyId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'skill_table',
      where: 'source_copy_id = ?',
      whereArgs: [copyId],
    );
    return maps.map((m) => SkillEntity.fromMap(m)).toList();
  }

  Future<int> insert(SkillEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('skill_table', entity.toMap());
  }

  Future<int> update(SkillEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'skill_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('skill_table', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteByCharId(int charId) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'skill_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
  }

  /// 批量插入技能
  Future<List<int>> batchInsert(List<SkillEntity> entities) async {
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final entity in entities) {
      batch.insert('skill_table', entity.toMap());
    }
    final results = await batch.commit(noResult: false);
    return results.cast<int>();
  }
}
