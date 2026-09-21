/// lib/features/sync/data/sync_store.dart
///
/// 本地同步簿记：sync_state（每行的服务端版本号）与 sync_kv（同步游标等键值）。
/// 两张表由 DatabaseHelper 在 v33 迁移里创建，属于本机专用，不参与同步。
library;

import 'package:sqflite/sqflite.dart';
import '../../../core/db/database_helper.dart';

class SyncStore {
  static Future<Database> get _db => DatabaseHelper.database;

  // ───────────────────────── 键值（游标 / 设备号 / 地址） ─────────────────────────

  static Future<String?> getValue(String key) async {
    final db = await _db;
    final rows = await db.query(
      'sync_kv',
      columns: <String>['v'],
      where: 'k = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['v'] as String?;
  }

  static Future<void> setValue(String key, String value) async {
    final db = await _db;
    await db.insert(
      'sync_kv',
      <String, Object?>{'k': key, 'v': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<int> getInt(String key, {int fallback = 0}) async {
    final raw = await getValue(key);
    return int.tryParse(raw ?? '') ?? fallback;
  }

  static Future<void> setInt(String key, int value) =>
      setValue(key, value.toString());

  // ───────────────────────── 行版本 ─────────────────────────

  /// 取某表所有行的已知版本号：pk → rev
  static Future<Map<int, int>> revsOf(String dbName, String table) async {
    final db = await _db;
    final rows = await db.query(
      'sync_state',
      columns: <String>['pk', 'rev'],
      where: 'db_name = ? AND table_name = ?',
      whereArgs: <Object?>[dbName, table],
    );
    final out = <int, int>{};
    for (final row in rows) {
      final pk = row['pk'];
      final rev = row['rev'];
      if (pk is num && rev is num) out[pk.toInt()] = rev.toInt();
    }
    return out;
  }

  static Future<void> setRev(String dbName, String table, int pk, int rev) async {
    final db = await _db;
    await db.insert(
      'sync_state',
      <String, Object?>{
        'db_name': dbName,
        'table_name': table,
        'pk': pk,
        'rev': rev,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量写入版本号（同一事务，减少 IO）
  static Future<void> setRevs(
    String dbName,
    String table,
    Map<int, int> revs,
  ) async {
    if (revs.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    revs.forEach((pk, rev) {
      batch.insert(
        'sync_state',
        <String, Object?>{
          'db_name': dbName,
          'table_name': table,
          'pk': pk,
          'rev': rev,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  /// 清空同步簿记（重置同步状态用；不会动业务数据）
  static Future<void> reset() async {
    final db = await _db;
    await db.delete('sync_state');
    await db.delete('sync_kv');
  }
}
