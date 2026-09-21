/// lib/features/sync/application/sync_service.dart
///
/// 同步编排：
///   1. 拉取服务端增量变更并落库
///   2. 把本机全部业务数据推送给服务端（内容没变的行会被服务端自动忽略）
///
/// 为什么是「全量推送」：App 没有脏标记机制，而服务端按内容哈希判重，
/// 没变的行既不会写日志也不会涨版本号，所以全量推送的成本很低。
library;

import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../../../core/db/database_helper.dart';
import '../../game/novel_game/model/db/novel_db_helper.dart';
import '../data/sync_client.dart';
import '../data/sync_store.dart';
import '../data/sync_targets.dart';

/// 一次同步的结果
class SyncReport {
  int pulled = 0;
  int applied = 0;
  int newRows = 0;
  int updatedRows = 0;
  int deletedRows = 0;
  int pushed = 0;
  int unchanged = 0;
  int conflicts = 0;
  int skippedTables = 0;

  int sinceBefore = 0;
  int sinceAfter = 0;
  int serverSeq = 0;

  String deviceId = '';
  String serverInfo = '';
  DateTime? finishedAt;
  final List<String> errors = <String>[];

  bool get hasError => errors.isNotEmpty;

  /// 给界面用的一句话总结
  String get summary {
    final parts = <String>[];
    if (pulled > 0) {
      parts.add('拉取 $pulled 条（新增 $newRows / 更新 $updatedRows / 删除 $deletedRows）');
    } else {
      parts.add('没有需要拉取的变更');
    }
    parts.add('上传 $pushed 条');
    if (unchanged > 0) parts.add('内容未变 $unchanged 条');
    if (conflicts > 0) parts.add('冲突 $conflicts 条');
    return parts.join('，');
  }
}

class SyncService {
  /// 服务地址与令牌存在本地，默认值指向常见的局域网地址写法
  static const String kBaseUrlKey = 'server_base_url';
  static const String kTokenKey = 'server_token';
  static const String kDeviceIdKey = 'device_id';
  static const String kLastPullSeqKey = 'last_pull_seq';
  static const String kLastSyncAtKey = 'last_sync_at';
  static const String kLastSyncSummaryKey = 'last_sync_summary';

  /// 取（必要时生成并持久化）本机设备号
  static Future<String> ensureDeviceId() async {
    var id = await SyncStore.getValue(kDeviceIdKey);
    if (id == null || id.isEmpty) {
      final rnd = Random.secure();
      final buf = StringBuffer('phone-');
      for (var i = 0; i < 8; i++) {
        buf.write(rnd.nextInt(16).toRadixString(16));
      }
      id = buf.toString();
      await SyncStore.setValue(kDeviceIdKey, id);
    }
    return id;
  }

  static Future<String> getBaseUrl() async =>
      (await SyncStore.getValue(kBaseUrlKey)) ?? '';

  static Future<void> setBaseUrl(String url) =>
      SyncStore.setValue(kBaseUrlKey, url.trim());

  static Future<String> getToken() async =>
      (await SyncStore.getValue(kTokenKey)) ?? '';

  static Future<void> setToken(String token) =>
      SyncStore.setValue(kTokenKey, token.trim());

  /// 测试连接：返回服务端信息
  static Future<String> testConnection({
    required String baseUrl,
    String token = '',
  }) async {
    final deviceId = await ensureDeviceId();
    final client = SyncClient(baseUrl: baseUrl, deviceId: deviceId, token: token);
    final health = await client.health();
    return '连接成功 · ${health.service} · Node ${health.node}'
        '${health.authRequired ? ' · 已开启鉴权' : ''}';
  }

  /// 执行一次完整同步
  static Future<SyncReport> run({
    required String baseUrl,
    String token = '',
    String deviceName = '',
    void Function(String message)? onProgress,
  }) async {
    void log(String m) => onProgress?.call(m);

    final report = SyncReport();
    final deviceId = await ensureDeviceId();
    report.deviceId = deviceId;
    final client = SyncClient(baseUrl: baseUrl, deviceId: deviceId, token: token);

    // 1) 探活 + 注册设备
    log('正在连接同步服务…');
    final health = await client.health();
    report.serverInfo = '${health.service} · API v${health.apiVersion}';
    log('已连接（${report.serverInfo}）');
    await client.registerDevice(name: deviceName);

    // 2) 增量拉取
    var since = await SyncStore.getInt(kLastPullSeqKey);
    report.sinceBefore = since;
    report.serverSeq = since;
    log('正在拉取服务端变更…');

    var rounds = 0;
    while (true) {
      final result = await client.pull(since: since, limit: 500);
      report.pulled += result.changes.length;
      if (result.changes.isNotEmpty) {
        final applied = await _applyChanges(result.changes);
        report.newRows += applied.$1;
        report.updatedRows += applied.$2;
        report.deletedRows += applied.$3;
        report.applied += result.changes.length;
        log('已应用 ${result.changes.length} 条变更');
      }

      since = result.lastSeq;
      report.serverSeq = result.serverSeq;
      // 关键：即使是空批次也要保存游标，否则下次会重复拉同一段
      await SyncStore.setInt(kLastPullSeqKey, since);

      if (!result.hasMore) break;
      rounds++;
      if (rounds > 500) {
        report.errors.add('拉取轮次过多，已中断（请检查服务端日志）');
        break;
      }
    }
    report.sinceAfter = since;

    // 3) 全量推送本机数据
    log('正在上传本机数据…');
    var done = 0;
    for (final target in kSyncTargets) {
      done++;
      log('上传中（$done/${kSyncTargets.length}）${target.label}');

      final Database db = await _openDb(target.db);
      final List<Map<String, Object?>> rows;
      try {
        rows = await db.query(target.table);
      } catch (e) {
        // 该表在本机不存在（例如老版本还没建）——跳过
        report.skippedTables++;
        continue;
      }
      if (rows.isEmpty) continue;

      final revs = await SyncStore.revsOf(target.db, target.table);
      final sensitive = sensitiveColumnsOf(target.table).toSet();

      final changes = <Map<String, dynamic>>[];
      for (final row in rows) {
        final pk = row['id'];
        if (pk is! int) continue;
        final clean = Map<String, dynamic>.from(row)
          ..removeWhere((k, v) => sensitive.contains(k));
        changes.add(<String, dynamic>{
          'db': target.db,
          'table': target.table,
          'pk': pk,
          'op': 'upsert',
          'rev': (revs[pk] ?? 0) + 1,
          'row': clean,
        });
      }

      for (final batch in _chunk(changes, 200)) {
        final result = await client.push(batch);
        report.pushed += result.accepted;
        report.unchanged += result.skipped;
        report.conflicts += result.conflicts;

        final revUpdates = <int, int>{};
        for (final item in result.results) {
          switch (item.status) {
            case 'applied':
            case 'unchanged':
              if (item.rev > 0) revUpdates[item.pk] = item.rev;
              break;
            case 'conflict':
              // 服务端版本获胜：用服务端整行覆盖本机，避免两边长期不一致
              if (item.serverRow != null) {
                await _overwriteLocalRow(target.db, target.table, item.serverRow!);
              }
              if (item.rev > 0) revUpdates[item.pk] = item.rev;
              break;
            default:
              if (item.message != null) {
                report.errors.add('${target.label}：${item.message!}');
              }
          }
        }
        await SyncStore.setRevs(target.db, target.table, revUpdates);
      }
    }

    report.finishedAt = DateTime.now();
    await SyncStore.setInt(kLastSyncAtKey, report.finishedAt!.millisecondsSinceEpoch);
    await SyncStore.setValue(kLastSyncSummaryKey, report.summary);
    log('同步完成');
    return report;
  }

  // ─────────────────────────── 内部实现 ───────────────────────────

  static Future<Database> _openDb(String dbName) {
    if (dbName == 'novel') return NovelDbHelper().database;
    return DatabaseHelper.database;
  }

  static Future<Set<String>?> _columnsOf(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    if (rows.isEmpty) return null; // 表不存在
    return rows.map((r) => r['name'] as String).toSet();
  }

  /// 应用服务端下发的变更，返回 (新增, 更新, 删除) 计数
  static Future<(int, int, int)> _applyChanges(List<SyncChange> changes) async {
    // 按「父表在前」排序，避免子表先落库触发外键错误
    final sorted = List<SyncChange>.from(changes)
      ..sort((a, b) =>
          syncRankOf(a.db, a.table).compareTo(syncRankOf(b.db, b.table)));

    var inserted = 0;
    var updated = 0;
    var deleted = 0;

    for (final dbName in const <String>['deepseek', 'novel']) {
      final group = sorted.where((c) => c.db == dbName).toList();
      if (group.isEmpty) continue;

      final db = await _openDb(dbName);
      final columnCache = <String, Set<String>?>{};

      await db.transaction((txn) async {
        // 事务内延迟外键校验：一批变更里父子顺序不保证时也不会中途失败
        await txn.execute('PRAGMA defer_foreign_keys = ON');

        for (final change in group) {
          final cols = columnCache[change.table] ??=
              await _columnsOf(txn, change.table);
          if (cols == null) continue; // 本机没有这张表，跳过

          if (change.op == 'delete') {
            final n = await txn.delete(
              change.table,
              where: 'id = ?',
              whereArgs: <Object?>[change.pk],
            );
            deleted += n;
            await SyncStore.setRev(dbName, change.table, change.pk, change.rev);
            continue;
          }

          final row = change.row;
          if (row == null) continue;

          final sensitive = sensitiveColumnsOf(change.table).toSet();
          final data = <String, dynamic>{};
          row.forEach((k, v) {
            if (cols.contains(k) && !sensitive.contains(k)) data[k] = v;
          });
          data['id'] = change.pk;
          if (data.length <= 1) continue;

          // 刻意不用 INSERT OR REPLACE：REPLACE 会先删后插，
          // 既会触发 ON DELETE CASCADE 删掉子表数据，也会让未提供的列（如 API Key）被重置为默认值
          final exists = await txn.query(
            change.table,
            columns: const <String>['id'],
            where: 'id = ?',
            whereArgs: <Object?>[change.pk],
            limit: 1,
          );

          if (exists.isEmpty) {
            await txn.insert(change.table, data);
            inserted++;
          } else {
            final patch = Map<String, dynamic>.from(data)..remove('id');
            if (patch.isNotEmpty) {
              await txn.update(
                change.table,
                patch,
                where: 'id = ?',
                whereArgs: <Object?>[change.pk],
              );
              updated++;
            }
          }
          await SyncStore.setRev(dbName, change.table, change.pk, change.rev);
        }
      });
    }

    return (inserted, updated, deleted);
  }

  /// 冲突时用服务端的整行覆盖本机（同样走「有则更新、无则插入」）
  static Future<void> _overwriteLocalRow(
    String dbName,
    String table,
    Map<String, dynamic> row,
  ) async {
    final db = await _openDb(dbName);
    final cols = await _columnsOf(db, table);
    if (cols == null) return;

    final data = <String, dynamic>{};
    row.forEach((k, v) {
      if (cols.contains(k)) data[k] = v;
    });
    final pk = data['id'];
    if (pk is! int) return;

    final exists = await db.query(
      table,
      columns: const <String>['id'],
      where: 'id = ?',
      whereArgs: <Object?>[pk],
      limit: 1,
    );

    if (exists.isEmpty) {
      await db.insert(table, data);
    } else {
      final patch = Map<String, dynamic>.from(data)..remove('id');
      if (patch.isNotEmpty) {
        await db.update(table, patch, where: 'id = ?', whereArgs: <Object?>[pk]);
      }
    }
  }

  static Iterable<List<T>> _chunk<T>(List<T> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, i + size > list.length ? list.length : i + size);
    }
  }
}
