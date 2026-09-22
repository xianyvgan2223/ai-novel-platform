/// lib/features/sync/data/sync_store.dart
///
/// 本地同步簿记：sync_state（每行的服务端版本号）与 sync_kv（同步游标等键值）。
/// 两张表由 DatabaseHelper 在 v33 迁移里创建，属于本机专用，不参与同步。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../../../core/db/database_helper.dart';

/// 一行的同步簿记：同步到哪个版本 + 当时的内容指纹
class RowSyncState {
  final int rev;
  final String hash;

  const RowSyncState(this.rev, this.hash);
}

/// 行内容指纹（FNV-1a 64 位）。
///
/// 刻意不用 Object.hash：Dart 对字符串的 Object.hash 带每个 isolate 的随机种子，
/// 重启后同一个内容会算出不同的值，那样每次同步都会误判成「变了」。
String rowFingerprint(Map<String, Object?> row) {
  final keys = row.keys.toList()..sort();
  final buf = StringBuffer();
  for (final key in keys) {
    buf
      ..write(key)
      ..write('\u0001')
      ..write(row[key]?.toString() ?? '\u0000')
      ..write('\u0002');
  }
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(buf.toString())) {
    hash = (hash ^ byte) * 0x100000001b3; // 64 位溢出回绕即取模，正是想要的效果
  }
  // Dart 的 int 是 64 位有符号，toUnsigned(64) 对负数无效（结果仍是负的），
  // 于是会出现 "-4f43..." 这种带负号的指纹。拆成高低 32 位分别转十六进制。
  final high = (hash >> 32) & 0xFFFFFFFF;
  final low = hash & 0xFFFFFFFF;
  return high.toRadixString(16).padLeft(8, '0') +
      low.toRadixString(16).padLeft(8, '0');
}

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

  /// 取某表所有行的内容指纹：pk → hash
  static Future<Map<int, String>> hashesOf(String dbName, String table) async {
    final db = await _db;
    final rows = await db.query(
      'sync_state',
      columns: <String>['pk', 'hash'],
      where: 'db_name = ? AND table_name = ?',
      whereArgs: <Object?>[dbName, table],
    );
    final out = <int, String>{};
    for (final row in rows) {
      final pk = row['pk'];
      if (pk is num) out[pk.toInt()] = (row['hash'] as String?) ?? '';
    }
    return out;
  }

  /// 写入若干行的同步簿记（版本号 + 内容指纹）。
  ///
  /// 写入方式：先 UPDATE，没有命中再 INSERT。
  ///
  /// 为什么不用 SQLite 的 UPSERT（`ON CONFLICT ... DO UPDATE`）：
  /// 那个语法要 SQLite 3.24+（2018 年），而 Android 自带的 SQLite 版本
  /// 跟着系统走，老设备上会直接抛 `near "ON": syntax error`。
  ///
  /// 也不能用 INSERT OR REPLACE：它是先删后插，会把这次没提供的列
  /// （比如 hash）重置成默认值。
  ///
  /// 两条语句都放进同一个 batch，顺序执行；`INSERT ... SELECT ... WHERE NOT EXISTS`
  /// 这种写法从很老的 SQLite 就一直支持。
  ///
  /// [executor] 传入事务对象即可在事务内调用 —— sqflite 规定
  /// 事务进行中不能再用外层 db 连接操作，否则会卡死。
  static Future<void> setStates(
    String dbName,
    String table,
    Map<int, RowSyncState> states, {
    DatabaseExecutor? executor,
  }) async {
    if (states.isEmpty) return;
    final exec = executor ?? await _db;
    final batch = exec.batch();

    states.forEach((pk, state) {
      batch.rawUpdate(
        'UPDATE sync_state SET rev = ?, hash = ? '
        'WHERE db_name = ? AND table_name = ? AND pk = ?',
        <Object?>[state.rev, state.hash, dbName, table, pk],
      );
      batch.rawInsert(
        'INSERT INTO sync_state (db_name, table_name, pk, rev, hash) '
        'SELECT ?, ?, ?, ?, ? WHERE NOT EXISTS ('
        'SELECT 1 FROM sync_state WHERE db_name = ? AND table_name = ? AND pk = ?)',
        <Object?>[dbName, table, pk, state.rev, state.hash, dbName, table, pk],
      );
    });

    await batch.commit(noResult: true);
  }

  /// 删掉一行的簿记。
  /// 服务端删除同步下来时必须调用，否则下次推送会把它当成「本地删除」又推回去。
  static Future<void> removeState(
    String dbName,
    String table,
    int pk, {
    DatabaseExecutor? executor,
  }) async {
    final exec = executor ?? await _db;
    await exec.delete(
      'sync_state',
      where: 'db_name = ? AND table_name = ? AND pk = ?',
      whereArgs: <Object?>[dbName, table, pk],
    );
  }

  /// 清空同步簿记（重置同步状态用；不会动业务数据）
  static Future<void> reset() async {
    final db = await _db;
    await db.delete('sync_state');
    await db.delete('sync_kv');
  }
}
