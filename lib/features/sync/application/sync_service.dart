/// lib/features/sync/application/sync_service.dart
///
/// 同步编排：
///   1. 拉取服务端增量变更并落库
///   2. 把本机全部业务数据推送给服务端（内容没变的行会被服务端自动忽略）
///
/// 为什么是「全量推送」：App 没有脏标记机制，而服务端按内容哈希判重，
/// 没变的行既不会写日志也不会涨版本号，所以全量推送的成本很低。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/db/database_helper.dart';
import '../../game/novel_game/model/db/novel_db_helper.dart';
import '../data/address_resolver.dart';
import '../data/server_discovery.dart';
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

/// 处理「电脑请求同步」的结果
class PendingSyncOutcome {
  /// 是否真的执行了一次同步（false = 没有待办 / 连接不通）
  final bool handled;
  final String summary;
  final String? error;

  const PendingSyncOutcome({
    required this.handled,
    required this.summary,
    required this.error,
  });

  const PendingSyncOutcome.idle()
      : handled = false,
        summary = '',
        error = null;
}

class SyncService {
  /// 服务地址与令牌存在本地，默认值指向常见的局域网地址写法
  static const String kBaseUrlKey = 'server_base_url';
  static const String kTokenKey = 'server_token';
  static const String kDeviceIdKey = 'device_id';
  static const String kLastPullSeqKey = 'last_pull_seq';
  static const String kLastSyncAtKey = 'last_sync_at';
  static const String kLastSyncSummaryKey = 'last_sync_summary';
  /// 历史可用地址（换网络后仍能秒连），一行一个
  static const String kKnownUrlsKey = 'known_base_urls';
  /// 当前通道种类（usb / lan / hotspot / manual），给界面显示用
  static const String kChannelKindKey = 'channel_kind';

  /// 刚解析出的地址在这么久内直接复用，避免每轮轮询都重走一遍解析链
  static const Duration _resolveCacheTtl = Duration(seconds: 45);
  static String _cachedUrl = '';
  static DateTime? _cachedAt;
  static ChannelKind _cachedKind = ChannelKind.manual;

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

  /// 记下地址：既当「上次用的地址」，也进历史列表
  static Future<void> setBaseUrl(String url) async {
    final normalized = AddressResolver.normalizeBaseUrl(url);
    if (normalized.isEmpty) return;
    await SyncStore.setValue(kBaseUrlKey, normalized);
    await rememberUrl(normalized);
  }

  /// 记下当前通道的种类（界面据此显示「USB 隧道」/「局域网」）
  static Future<void> setChannelKind(ChannelKind kind) =>
      SyncStore.setValue(kChannelKindKey, kind.name);

  static Future<String> getChannelKindRaw() async =>
      (await SyncStore.getValue(kChannelKindKey)) ?? '';

  /// 历史上成功用过的地址（最多留 6 个，最近用的排前面）
  static Future<List<String>> knownUrls() async {
    final raw = await SyncStore.getValue(kKnownUrlsKey);
    if (raw == null || raw.isEmpty) return <String>[];
    return raw
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static Future<void> rememberUrl(String url) async {
    final normalized = AddressResolver.normalizeBaseUrl(url);
    if (normalized.isEmpty) return;
    final list = await knownUrls();
    list.removeWhere((u) => u == normalized);
    list.insert(0, normalized);
    await SyncStore.setValue(kKnownUrlsKey, list.take(6).join('\n'));
  }

  /// 最近一次解析出来的地址（界面显示用）
  static String get cachedUrl => _cachedUrl;

  /// 最近一次解析出的通道种类
  static ChannelKind get cachedKind => _cachedKind;

  /// 主动忘掉缓存（用户手动改地址、或点了「重新找电脑」时调）
  static void clearResolveCache() {
    _cachedUrl = '';
    _cachedAt = null;
    _cachedKind = ChannelKind.manual;
  }

  /// 让后续请求走这个地址（界面手动选通道时用），并把它记成「上次用的地址」
  static Future<ResolvedAddress> useUrl(String url, {ChannelKind? kind}) async {
    final normalized = AddressResolver.normalizeBaseUrl(url);
    final service = await probeSyncService(normalized, token: await getToken()) ?? '';
    final resolved = ResolvedAddress(
      baseUrl: normalized,
      kind: kind ?? AddressResolver.guessKind(normalized),
      service: service,
      step: 0,
    );
    _cachedUrl = normalized;
    _cachedAt = DateTime.now();
    _cachedKind = resolved.kind;
    await setBaseUrl(normalized);
    await setChannelKind(resolved.kind);
    return resolved;
  }

  /// 逐级找出一个能用的地址（USB 隧道 → 历史地址 → 网关 → 广播 → 扫描）
  ///
  /// [force] 为 true 时忽略缓存，重新走一遍解析链（用户点「重新找电脑」）。
  static Future<ResolvedAddress?> resolveAddress({
    bool force = false,
    void Function(String message, {int? current, int? total})? onProgress,
    bool allowScan = true,
  }) async {
    if (!force &&
        _cachedUrl.isNotEmpty &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _resolveCacheTtl) {
      return ResolvedAddress(
        baseUrl: _cachedUrl,
        kind: _cachedKind,
        service: '',
        step: 0,
      );
    }

    final saved = await getBaseUrl();
    final known = await knownUrls();
    final token = await getToken();

    final resolved = await AddressResolver.resolve(
      savedUrl: saved,
      knownUrls: known.where((u) => u != saved).toList(),
      token: token,
      onProgress: (m) => onProgress?.call(m),
      allowScan: allowScan,
    );

    if (resolved == null) {
      clearResolveCache();
      return null;
    }

    _cachedUrl = resolved.baseUrl;
    _cachedAt = DateTime.now();
    _cachedKind = resolved.kind;
    await setBaseUrl(resolved.baseUrl);
    await setChannelKind(resolved.kind);
    return resolved;
  }

  /// 通道状态（同步设置页显示）：USB 隧道是否已就绪 + 当前通道
  static Future<({bool usbReady, String currentUrl, ChannelKind kind})> channelStatus() async {
    final token = await getToken();
    final usbReady = await AddressResolver.usbTunnelReady(token: token);
    final raw = await getChannelKindRaw();
    var kind = _cachedKind;
    for (final candidate in ChannelKind.values) {
      if (candidate.name == raw) kind = candidate;
    }
    return (usbReady: usbReady, currentUrl: await getBaseUrl(), kind: kind);
  }

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
    // 能把地址测通就记住它（顺便标出这是哪种通道）
    _cachedUrl = AddressResolver.normalizeBaseUrl(baseUrl);
    _cachedAt = DateTime.now();
    _cachedKind = AddressResolver.guessKind(baseUrl);
    return '连接成功 · ${health.service} · Node ${health.node}'
        '${health.authRequired ? ' · 已开启鉴权' : ''}';
  }

  /// 把异常压成适合弹提示的一行字。
  /// 数据库异常原文动辄几百字，直接塞进 SnackBar 会占满整个屏幕。
  static String describeError(Object error) {
    if (error is SyncException) return error.message;
    final raw = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return raw.length <= 140 ? raw : '${raw.substring(0, 140)}…';
  }

  /// 在局域网 / USB 隧道里找一台同步服务；找到会记下地址并返回
  static Future<String?> autoDiscover({
    void Function(String message, {int? current, int? total})? onProgress,
    bool force = true,
  }) async {
    clearResolveCache();
    final resolved = await resolveAddress(force: force, onProgress: onProgress);
    return resolved?.baseUrl;
  }

  /// 检查电脑（网页）有没有发起「请同步」待办；有就执行并回报。
  ///
  /// 返回值 handled=false 表示这次什么都没做（没配过地址 / 网络不通 / 没有待办），
  /// 轮询方据此决定要不要提示用户 —— 网络抖动不应该每 5 秒弹一次错误。
  static Future<PendingSyncOutcome> handlePendingRequest({
    void Function(String message, {int? current, int? total})? onProgress,
  }) async {
    final url = await getBaseUrl();
    // 之前完全没连过：先按通道链找一次（含 USB 隧道），找不到就安静地跳过
    if (url.isEmpty) {
      final resolved = await resolveAddress(onProgress: onProgress);
      if (resolved == null) return PendingSyncOutcome.idle();
    }

    // 用缓存/解析出的地址；最近连过就不再重复解析
    final resolved = await resolveAddress(onProgress: onProgress);
    if (resolved == null) return PendingSyncOutcome.idle();

    final deviceId = await ensureDeviceId();
    final token = await getToken();
    final client = SyncClient(baseUrl: resolved.baseUrl, deviceId: deviceId, token: token);

    SyncRequestInfo? claimed;
    try {
      claimed = await client.claimPendingRequest();
    } catch (_) {
      // 连接问题：让下一次轮询重新解析地址（可能换了网络或拔了数据线）
      clearResolveCache();
      return PendingSyncOutcome.idle();
    }
    if (claimed == null) return PendingSyncOutcome.idle();

    final request = claimed; // 提升为非空局部变量，闭包里才能安全引用
    onProgress?.call('收到电脑的同步请求…');
    final runUrl = resolved.baseUrl;

    // 进度一边给本机界面，一边回传服务端（网页那边就能显示实时进度）。
    // 节流到约 0.7 秒一次，免得把接口刷爆。
    var lastReportAt = 0;
    void report(String message, {int? current, int? total}) {
      onProgress?.call(message, current: current, total: total);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastReportAt < 700) return;
      lastReportAt = nowMs;
      unawaited(
        client.reportProgress(request.id, message: message, current: current, total: total),
      );
    }

    try {
      report('开始同步…');
      final report0 = await run(
        baseUrl: runUrl,
        token: token,
        deviceName: '我的手机',
        onProgress: report,
      );
      await client.completeRequest(request.id, status: 'done', result: report0.summary);
      return PendingSyncOutcome(handled: true, summary: report0.summary, error: null);
    } catch (e) {
      final message = e is SyncException ? e.message : e.toString();
      try {
        await client.completeRequest(request.id, status: 'failed', result: message);
      } catch (_) {
        // 回报失败也无所谓，网页那边会超时提示
      }
      return PendingSyncOutcome(handled: true, summary: '', error: message);
    }
  }

  /// 一键同步（主界面按钮用）：
  ///   1. 按通道顺序找电脑：上次的地址 → USB 隧道 → 历史地址 → 网关 → 广播 → 扫描
  ///   2. 找不到时给出可操作的提示，而不是丢一句「网络异常」
  ///   3. 地址失效（换了 Wi-Fi、拔了数据线）时自动重新解析一次再同步
  static Future<SyncReport> quickSync({
    String? preferredUrl,
    String deviceName = '',
    void Function(String message, {int? current, int? total})? onProgress,
  }) async {
    ResolvedAddress? resolved;
    final preferred = (preferredUrl ?? '').trim();

    if (preferred.isNotEmpty) {
      resolved = await useUrl(preferred);
    } else {
      onProgress?.call('正在找电脑…');
      resolved = await resolveAddress(force: true, onProgress: onProgress);
    }

    if (resolved == null) {
      throw SyncException(
        '没有找到电脑上的同步服务。\n'
        '最省事的方式（USB 数据线）：\n'
        '  ① 电脑上另开一个窗口执行  npm run usb\n'
        '  ② 手机 App「设置 → 数据同步」里服务地址填 http://127.0.0.1:3210\n'
        '走 Wi-Fi 时请确认：手机与电脑连同一个 Wi-Fi（或电脑连手机热点）、'
        '电脑上服务已启动、Windows 防火墙已放行 3210 端口。',
      );
    }

    onProgress?.call('已连上（${resolved.kind.label}）${resolved.baseUrl}');
    final token = await getToken();

    try {
      return await run(
        baseUrl: resolved.baseUrl,
        token: token,
        deviceName: deviceName,
        onProgress: onProgress,
      );
    } catch (e) {
      final retriable = e is SyncException &&
          (e.message.contains('连不上') || e.message.contains('超时'));
      if (!retriable) rethrow;

      // 地址可能在同步过程中失效（拔线 / 换网），清缓存重新解析一次
      onProgress?.call('原地址连不上，正在重新找电脑…');
      clearResolveCache();
      final again = await resolveAddress(force: true, onProgress: onProgress);
      if (again == null || again.baseUrl == resolved.baseUrl) rethrow;

      onProgress?.call('改用 ${again.kind.label} ${again.baseUrl}');
      return run(
        baseUrl: again.baseUrl,
        token: token,
        deviceName: deviceName,
        onProgress: onProgress,
      );
    }
  }

  /// 执行一次完整同步
  static Future<SyncReport> run({
    required String baseUrl,
    String token = '',
    String deviceName = '',
    void Function(String message, {int? current, int? total})? onProgress,
  }) async {
    void log(String m, {int? current, int? total}) =>
        onProgress?.call(m, current: current, total: total);

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

    // 3) 增量推送本机数据。
    //    推送前先在本机比对内容指纹（存在 sync_state.hash 里）：
    //    没变过的行**根本不发**，网络传输量只跟「这次改了多少」有关。
    log('正在对比本机数据…', current: 0, total: kSyncTargets.length);
    var done = 0;
    for (final target in kSyncTargets) {
      done++;
      log('检查（$done/${kSyncTargets.length}）${target.label}',
          current: done, total: kSyncTargets.length);

      final Database db = await _openDb(target.db);
      final List<Map<String, Object?>> rows;
      try {
        rows = await db.query(target.table);
      } catch (e) {
        // 该表在本机不存在（例如老版本还没建），或整表读取失败——跳过。
        // 不要静默：像 outline_records 里有单行超过 Android CursorWindow 2 MB 上限时，
        // 整张表会悄悄停止同步，这里把原因打出来。
        debugPrint('[sync] 跳过表 ${target.db}.${target.table}：$e');
        report.skippedTables++;
        continue;
      }

      final revs = await SyncStore.revsOf(target.db, target.table);
      final hashes = await SyncStore.hashesOf(target.db, target.table);
      final sensitive = sensitiveColumnsOf(target.table).toSet();

      final changes = <Map<String, dynamic>>[];
      // 推送成功后才写回的簿记：pk → 新版本号 + 这次的内容指纹
      final pendingStates = <int, RowSyncState>{};
      final localPks = <int>{};
      final deletedPks = <int>{};

      for (final row in rows) {
        final pk = row['id'];
        if (pk is! int) continue;
        localPks.add(pk);

        final clean = Map<String, dynamic>.from(row)
          ..removeWhere((k, v) => sensitive.contains(k));
        final fingerprint = rowFingerprint(clean);

        if (hashes[pk] == fingerprint) {
          report.unchanged++; // 内容与上次同步时一致，跳过不传
          continue;
        }

        final nextRev = (revs[pk] ?? 0) + 1;
        changes.add(<String, dynamic>{
          'db': target.db,
          'table': target.table,
          'pk': pk,
          'op': 'upsert',
          'rev': nextRev,
          'row': clean,
        });
        pendingStates[pk] = RowSyncState(nextRev, fingerprint);
      }

      // 簿记里有、本机数据里没有 → 用户在本机删掉了，通知服务端一起删。
      // （这一步以前是缺失的：手机上删掉的会话在服务端会一直留着）
      for (final pk in revs.keys) {
        if (localPks.contains(pk)) continue;
        deletedPks.add(pk);
        changes.add(<String, dynamic>{
          'db': target.db,
          'table': target.table,
          'pk': pk,
          'op': 'delete',
          'rev': (revs[pk] ?? 0) + 1,
        });
      }

      if (changes.isEmpty) continue;

      log('上传（$done/${kSyncTargets.length}）${target.label} · ${changes.length} 行',
          current: done, total: kSyncTargets.length);

      for (final batch in _chunk(changes, 200)) {
        final result = await client.push(batch);
        report.pushed += result.accepted;
        report.unchanged += result.skipped;
        report.conflicts += result.conflicts;

        final stateUpdates = <int, RowSyncState>{};
        final stateRemovals = <int>{};

        for (final item in result.results) {
          final isDelete = item.op == 'delete';

          switch (item.status) {
            case 'applied':
              if (isDelete) {
                // 服务端也删了，本机簿记一并清掉，
                // 否则下次推送又会把它当成「本地删除」再推一遍
                stateRemovals.add(item.pk);
              } else if (item.rev > 0) {
                stateUpdates[item.pk] = RowSyncState(
                  item.rev,
                  pendingStates[item.pk]?.hash ?? '',
                );
              }
              break;

            case 'unchanged':
              if (item.rev > 0) {
                stateUpdates[item.pk] = RowSyncState(
                  item.rev,
                  pendingStates[item.pk]?.hash ?? '',
                );
              }
              break;

            case 'conflict':
              if (item.serverRow != null) {
                // 服务端版本获胜：用服务端整行覆盖本机，并按实际落库内容重算指纹
                final applied = await _overwriteLocalRow(
                  target.db,
                  target.table,
                  item.serverRow!,
                );
                stateUpdates[item.pk] = RowSyncState(
                  item.rev,
                  applied == null ? '' : rowFingerprint(applied),
                );
              } else if (item.rev > 0) {
                // 删除撞上服务端更新：接受服务端版本号，避免每次都重推
                stateUpdates[item.pk] = RowSyncState(item.rev, '');
              }
              break;

            default:
              if (item.message != null) {
                report.errors.add('${target.label}：${item.message!}');
              }
          }
        }

        await SyncStore.setStates(target.db, target.table, stateUpdates);
        for (final pk in stateRemovals) {
          await SyncStore.removeState(target.db, target.table, pk);
        }
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
            // 清掉簿记：留着的话下次推送会把「服务端删的」当成「本机删的」再推回去
            await SyncStore.removeState(
              dbName,
              change.table,
              change.pk,
              executor: txn,
            );
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
          // 记下服务端版本号 + 这次落库内容的指纹，
          // 这样接下来的增量推送就能认出「这行已经和服务端一致了」
          await SyncStore.setStates(
            dbName,
            change.table,
            <int, RowSyncState>{
              change.pk: RowSyncState(
                change.rev,
                rowFingerprint(data.cast<String, Object?>()),
              ),
            },
            executor: txn,
          );
        }
      });
    }

    return (inserted, updated, deleted);
  }

  /// 冲突时用服务端的整行覆盖本机（同样走「有则更新、无则插入」）。
  /// 返回实际落库的内容，调用方据此计算指纹 —— 必须与库里真正的内容一致。
  static Future<Map<String, Object?>?> _overwriteLocalRow(
    String dbName,
    String table,
    Map<String, dynamic> row,
  ) async {
    final db = await _openDb(dbName);
    final cols = await _columnsOf(db, table);
    if (cols == null) return null;

    final data = <String, dynamic>{};
    row.forEach((k, v) {
      if (cols.contains(k)) data[k] = v;
    });
    final pk = data['id'];
    if (pk is! int) return null;

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
    return data.cast<String, Object?>();
  }

  static Iterable<List<T>> _chunk<T>(List<T> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, i + size > list.length ? list.length : i + size);
    }
  }
}
