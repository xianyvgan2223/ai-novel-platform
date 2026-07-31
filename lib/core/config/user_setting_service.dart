/// lib/services/user_setting_service.dart
/// user_settings 表读写服务 — 全局配置单条记录的存取

import 'user_setting.dart';
import '../db/database_helper.dart';

class UserSettingService {
  /// 读取全局配置，无记录时返回默认值实体
  static Future<UserSetting> getSettings() async {
    final db = await DatabaseHelper.database;
    final results = await db.query('user_settings', limit: 1);
    if (results.isEmpty) return const UserSetting();
    return UserSetting.fromMap(results.first);
  }

  /// 保存全局配置（upsert 逻辑：有则更新，无则插入）
  static Future<void> saveSettings(UserSetting setting) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query('user_settings', limit: 1);

    if (existing.isEmpty) {
      await db.insert('user_settings', setting.toMap()..['id'] = 1);
    } else {
      final map = setting.toMap();
      map.remove('id'); // UPDATE 不允许修改主键
      await db.update('user_settings', map, where: 'id = ?', whereArgs: [1]);
    }
  }
}
