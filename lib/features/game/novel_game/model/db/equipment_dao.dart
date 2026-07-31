import 'novel_db_helper.dart';
import '../entity/equipment_entity.dart';

class EquipmentDao {
  final NovelDbHelper _dbHelper = NovelDbHelper();

  Future<List<EquipmentEntity>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('equipment_table', orderBy: 'id DESC');
    return maps.map((m) => EquipmentEntity.fromMap(m)).toList();
  }

  Future<EquipmentEntity?> getById(int id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'equipment_table',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return EquipmentEntity.fromMap(maps.first);
  }

  Future<List<EquipmentEntity>> getByCharId(int charId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'equipment_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
    return maps.map((m) => EquipmentEntity.fromMap(m)).toList();
  }

  /// 根据副本ID获取所有装备
  Future<List<EquipmentEntity>> getByCopyId(int copyId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'equipment_table',
      where: 'source_copy_id = ?',
      whereArgs: [copyId],
    );
    return maps.map((m) => EquipmentEntity.fromMap(m)).toList();
  }

  Future<int> insert(EquipmentEntity entity) async {
    final db = await _dbHelper.database;
    return await db.insert('equipment_table', entity.toMap());
  }

  Future<int> update(EquipmentEntity entity) async {
    final db = await _dbHelper.database;
    return await db.update(
      'equipment_table',
      entity.toMap(),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _dbHelper.database;
    return await db.delete('equipment_table', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteByCharId(int charId) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'equipment_table',
      where: 'char_id = ?',
      whereArgs: [charId],
    );
  }

  /// 批量插入装备
  Future<List<int>> batchInsert(List<EquipmentEntity> entities) async {
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final entity in entities) {
      batch.insert('equipment_table', entity.toMap());
    }
    final results = await batch.commit(noResult: false);
    return results.cast<int>();
  }
}
