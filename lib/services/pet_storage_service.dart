// lib/services/pet_storage_service.dart
// 宠物数据持久化服务 — 读写 pet_data 表，单条记录 id=1

import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../services/database_helper.dart';
import '../pet/pet_state.dart';

class PetStorageService {
  /// 保存宠物数据到数据库
  static Future<void> savePet(PetData pet, List<GrowthRecord> records) async {
    final db = await DatabaseHelper.database;
    final recordsJson = jsonEncode(
      records
          .map(
            (r) => {
              'content': r.content,
              'value_change': r.valueChange,
              'timestamp': r.timestamp.toIso8601String(),
            },
          )
          .toList(),
    );

    await db.insert('pet_data', {
      'id': 1,
      'name': pet.name,
      'level': pet.level,
      'growth_current': pet.growthCurrent,
      'growth_max': pet.growthMax,
      'mood_value': pet.moodValue,
      'mood': pet.mood.name,
      'activity': pet.activity,
      'intimacy': pet.intimacy,
      'records': recordsJson,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 从数据库加载宠物数据，无记录返回默认值
  static Future<(PetData, List<GrowthRecord>)> loadPet() async {
    final db = await DatabaseHelper.database;
    final results = await db.query('pet_data', where: 'id = ?', whereArgs: [1]);

    if (results.isEmpty) {
      return (const PetData(), <GrowthRecord>[]);
    }

    final row = results.first;
    final pet = PetData(
      name: row['name'] as String? ?? '小宠',
      level: row['level'] as int? ?? 1,
      growthCurrent: row['growth_current'] as int? ?? 0,
      growthMax: row['growth_max'] as int? ?? 100,
      moodValue: row['mood_value'] as int? ?? 80,
      mood: PetMood.values.firstWhere(
        (m) => m.name == (row['mood'] as String? ?? 'happy'),
        orElse: () => PetMood.happy,
      ),
      activity: row['activity'] as int? ?? 50,
      intimacy: row['intimacy'] as int? ?? 30,
    );

    final recordsJson = row['records'] as String? ?? '[]';
    final recordsList = jsonDecode(recordsJson) as List<dynamic>;
    final List<GrowthRecord> records = recordsList.map<GrowthRecord>((r) {
      final map = r as Map<String, dynamic>;
      return GrowthRecord(
        content: map['content'] as String? ?? '',
        valueChange: map['value_change'] as int? ?? 0,
        timestamp: DateTime.tryParse(map['timestamp'] as String? ?? ''),
      );
    }).toList();

    return (pet, records);
  }
}
