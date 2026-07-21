import 'novel_db_helper.dart';
import '../entity/character_intersection_entity.dart';

class IntersectionDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<CharacterIntersectionEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'character_intersection_table',
      orderBy: 'id DESC',
    );
    return maps.map((m) => CharacterIntersectionEntity.fromMap(m)).toList();
  }

  Future<CharacterIntersectionEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'character_intersection_table',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return CharacterIntersectionEntity.fromMap(maps.first);
  }

  /// 获取两个角色之间的交集
  Future<CharacterIntersectionEntity?> getByCharPair(
    int charAId,
    int charBId,
  ) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'character_intersection_table',
      where:
          '(char_a_id = ? AND char_b_id = ?) OR (char_a_id = ? AND char_b_id = ?)',
      whereArgs: [charAId, charBId, charBId, charAId],
    );
    if (maps.isEmpty) return null;
    return CharacterIntersectionEntity.fromMap(maps.first);
  }

  /// 获取与指定角色相关的所有交集
  Future<List<CharacterIntersectionEntity>> getIntersectionsForChar(
    int charId,
  ) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'character_intersection_table',
      where: 'char_a_id = ? OR char_b_id = ?',
      whereArgs: [charId, charId],
    );
    return maps.map((m) => CharacterIntersectionEntity.fromMap(m)).toList();
  }

  Future<int> insert(CharacterIntersectionEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('character_intersection_table', entity.toMap());
  }

  Future<int> update(CharacterIntersectionEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'character_intersection_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'character_intersection_table',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteByCharId(int charId) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'character_intersection_table',
      where: 'char_a_id = ? OR char_b_id = ?',
      whereArgs: [charId, charId],
    );
  }

  /// 插入或更新两个角色之间的交集描述
  Future<int> upsert(CharacterIntersectionEntity entity) async {
    final existing = await getByCharPair(entity.charAId, entity.charBId);
    if (existing != null) {
      existing.intersectionDesc = entity.intersectionDesc;
      existing.updateTime = DateTime.now().millisecondsSinceEpoch;
      return await update(existing);
    } else {
      return await insert(entity);
    }
  }
}
