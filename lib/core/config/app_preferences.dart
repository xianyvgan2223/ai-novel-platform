// lib/core/config/app_preferences.dart
// 设备本地偏好（不参与同步）：目前用于夜间模式。
// 复用 sync_kv 这张键值表，避免为单个 UI 偏好做数据库版本迁移。

import 'package:sqflite/sqflite.dart';

import '../db/database_helper.dart';

class AppPreferences {
  const AppPreferences._();

  static const String themeModeKey = 'theme_mode';

  /// 上一次已经看过更新公告的 releaseId（如 5.2.1+6）。
  static const String updateAnnouncementKey = 'last_seen_update_release';

  static Future<String?> get(String key) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'sync_kv',
      columns: const <String>['v'],
      where: 'k = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['v'] as String?;
  }

  static Future<void> set(String key, String value) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'sync_kv',
      <String, Object?>{'k': key, 'v': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
