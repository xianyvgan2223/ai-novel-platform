import 'package:sqflite/sqflite.dart';
import '../../../../../core/db/database_helper.dart';

/// 大纲生成设置数据库操作
class OutlineDbHelper {
  static final OutlineDbHelper _instance = OutlineDbHelper._internal();
  factory OutlineDbHelper() => _instance;
  OutlineDbHelper._internal();

  Future<Database> get database => DatabaseHelper.database;

  /// 读取大纲设置
  Future<Map<String, dynamic>?> getSettings() async {
    final db = await database;
    final results = await db.query('outline_settings', limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  /// 保存大纲设置
  Future<void> saveSettings(Map<String, dynamic> settings) async {
    final db = await database;
    await db.update(
      'outline_settings',
      settings,
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  /// 读取章节写作设置（与大纲设置独立存储）
  Future<Map<String, dynamic>?> getChapterSettings() async {
    final db = await database;
    final results = await db.query('chapter_settings', limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  /// 保存章节写作设置
  Future<void> saveChapterSettings(Map<String, dynamic> settings) async {
    final db = await database;
    await db.update(
      'chapter_settings',
      settings,
      where: 'id = ?',
      whereArgs: [1],
    );
  }
}
