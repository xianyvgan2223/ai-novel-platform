import 'novel_db_helper.dart';
import '../entity/character_entity.dart';

class CharacterDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<CharacterEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('character_table', orderBy: 'id DESC');
    return maps.map((m) => CharacterEntity.fromMap(m)).toList();
  }

  Future<CharacterEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('character_table', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CharacterEntity.fromMap(maps.first);
  }

  Future<int> insert(CharacterEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('character_table', entity.toMap());
  }

  Future<int> update(CharacterEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update('character_table', entity.toMap(), where: 'id = ?', whereArgs: [entity.id]);
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('character_table', where: 'id = ?', whereArgs: [id]);
  }
}
