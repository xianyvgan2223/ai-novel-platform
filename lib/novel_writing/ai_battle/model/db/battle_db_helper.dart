import 'package:sqflite/sqflite.dart';
import '../../../../services/database_helper.dart';

/// 写小说模块数据库 — 管理战斗场景数据（数据存储在 deepseek.db 中）
class BattleDbHelper {
  static final BattleDbHelper _instance = BattleDbHelper._internal();
  factory BattleDbHelper() => _instance;
  BattleDbHelper._internal();

  Future<Database> get database => DatabaseHelper.database;

  // ═══════════════════════════════════════════
  //  战斗场景 CRUD
  // ═══════════════════════════════════════════

  /// 保存一条战斗场景（插入）
  Future<int> insertScene(Map<String, dynamic> scene) async {
    final db = await database;
    return db.insert('battle_scenes', scene);
  }

  /// 更新 AI 生成结果
  Future<void> updateResult(
    int id,
    String aiResult, {
    String status = 'completed',
  }) async {
    final db = await database;
    await db.update(
      'battle_scenes',
      {'ai_result': aiResult, 'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新整个战斗场景（编辑用）
  Future<void> updateScene(int id, Map<String, dynamic> data) async {
    final db = await database;
    await db.update('battle_scenes', data, where: 'id = ?', whereArgs: [id]);
  }

  /// 获取所有战斗场景（按时间倒序）
  Future<List<Map<String, dynamic>>> getAllScenes() async {
    final db = await database;
    return db.query('battle_scenes', orderBy: 'created_at DESC');
  }

  /// 获取单条战斗场景
  Future<Map<String, dynamic>?> getScene(int id) async {
    final db = await database;
    final results = await db.query(
      'battle_scenes',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// 删除战斗场景
  Future<void> deleteScene(int id) async {
    final db = await database;
    await db.delete('battle_scenes', where: 'id = ?', whereArgs: [id]);
  }

  // ═══════════════════════════════════════════
  //  战斗设置
  // ═══════════════════════════════════════════

  /// 读取战斗设置
  Future<Map<String, dynamic>?> getSettings() async {
    final db = await database;
    final results = await db.query('battle_settings', limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  /// 保存战斗设置
  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final db = await database;
    await db.update(
      'battle_settings',
      settings,
      where: 'id = ?',
      whereArgs: [1],
    );
  }
}
