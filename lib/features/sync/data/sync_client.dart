/// lib/features/sync/data/sync_client.dart
///
/// 同步服务的 HTTP 客户端（基于已有的 dio，不引入新依赖）。
///
/// 协议细节见 web/docs/同步协议.md。
library;

import 'package:dio/dio.dart';

/// 同步过程中的可读异常，界面上直接展示 message
class SyncException implements Exception {
  final String message;
  SyncException(this.message);

  @override
  String toString() => message;
}

/// /api/health 返回的服务信息
class SyncHealth {
  final String service;
  final int apiVersion;
  final String node;
  final bool authRequired;

  SyncHealth({
    required this.service,
    required this.apiVersion,
    required this.node,
    required this.authRequired,
  });

  factory SyncHealth.fromJson(Map<String, dynamic> j) => SyncHealth(
        service: (j['service'] ?? '') as String,
        apiVersion: (j['apiVersion'] as num?)?.toInt() ?? 0,
        node: (j['node'] ?? '') as String,
        authRequired: j['authRequired'] == true,
      );
}

/// 一条服务端变更
class SyncChange {
  final int seq;
  final String db;
  final String table;
  final int pk;
  final String op; // upsert | delete
  final int rev;
  final String originDevice;
  final Map<String, dynamic>? row;

  SyncChange({
    required this.seq,
    required this.db,
    required this.table,
    required this.pk,
    required this.op,
    required this.rev,
    required this.originDevice,
    required this.row,
  });

  factory SyncChange.fromJson(Map<String, dynamic> j) => SyncChange(
        seq: (j['seq'] as num).toInt(),
        db: (j['db'] ?? '') as String,
        table: (j['table'] ?? '') as String,
        pk: (j['pk'] as num).toInt(),
        op: (j['op'] ?? 'upsert') as String,
        rev: (j['rev'] as num?)?.toInt() ?? 1,
        originDevice: (j['originDevice'] ?? '') as String,
        row: j['row'] == null
            ? null
            : Map<String, dynamic>.from(j['row'] as Map),
      );
}

/// 一次拉取的结果
class PullResult {
  final List<SyncChange> changes;
  final int lastSeq;
  final int serverSeq;
  final bool hasMore;

  PullResult({
    required this.changes,
    required this.lastSeq,
    required this.serverSeq,
    required this.hasMore,
  });
}

/// 推送单条变更的处理结果
class PushResultItem {
  final String db;
  final String table;
  final int pk;

  /// upsert | delete —— 删除的结果要和新增/更新分开处理
  final String op;
  final String status; // applied | unchanged | conflict | error
  final int rev;
  final Map<String, dynamic>? serverRow;
  final String? message;

  PushResultItem({
    required this.db,
    required this.table,
    required this.pk,
    required this.op,
    required this.status,
    required this.rev,
    required this.serverRow,
    required this.message,
  });

  factory PushResultItem.fromJson(Map<String, dynamic> j) => PushResultItem(
        db: (j['db'] ?? '') as String,
        table: (j['table'] ?? '') as String,
        pk: (j['pk'] as num?)?.toInt() ?? 0,
        op: (j['op'] ?? 'upsert') as String,
        status: (j['status'] ?? '') as String,
        // 冲突时服务端返回的是 serverRev（服务端当前版本号）
        rev: ((j['rev'] ?? j['serverRev']) as num?)?.toInt() ?? 0,
        serverRow: j['serverRow'] == null
            ? null
            : Map<String, dynamic>.from(j['serverRow'] as Map),
        message: j['message'] as String?,
      );
}

/// 网页发起的「请手机同步」待办
class SyncRequestInfo {
  final int id;
  final String status;
  final int requestedAt;

  SyncRequestInfo({required this.id, required this.status, required this.requestedAt});

  factory SyncRequestInfo.fromJson(Map<String, dynamic> j) => SyncRequestInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? '') as String,
        requestedAt: (j['requestedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 一次推送的汇总
class PushResult {
  final int accepted;
  final int skipped;
  final int conflicts;
  final int serverSeq;
  final List<PushResultItem> results;

  PushResult({
    required this.accepted,
    required this.skipped,
    required this.conflicts,
    required this.serverSeq,
    required this.results,
  });
}

/// 同步服务客户端
class SyncClient {
  final String baseUrl;
  final String deviceId;
  final Dio _dio;

  SyncClient({
    required this.baseUrl,
    required this.deviceId,
    String? token,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _normalize(baseUrl),
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
              headers: _buildHeaders(token),
            ));

  /// 只有真正填了令牌才带请求头
  static Map<String, dynamic> _buildHeaders(String? token) {
    final trimmed = token?.trim() ?? '';
    if (trimmed.isEmpty) return <String, dynamic>{};
    return <String, dynamic>{'x-api-token': trimmed};
  }

  /// 容错：用户可能只填了 IP，或者多打了斜杠
  static String _normalize(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 把 dio 的异常翻译成人话
  Never _fail(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.connectionError:
          throw SyncException(
            '连不上同步服务：${_dio.options.baseUrl}\n'
            '请确认：① 电脑上的服务已启动（npm start）'
            '② 手机与电脑连同一个 Wi-Fi / 热点 '
            '③ Windows 防火墙已放行 ${Uri.parse(_dio.options.baseUrl).port} 端口',
          );
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          throw SyncException('同步超时，数据量可能较大，请重试');
        case DioExceptionType.badResponse:
          final code = error.response?.statusCode;
          final body = error.response?.data;
          var detail = '';
          if (body is Map && body['error'] != null) {
            detail = '：${body['error']}';
          }
          if (code == 401) {
            throw SyncException('接口令牌不正确，请检查「访问令牌」设置');
          }
          throw SyncException('服务端返回错误 ${code ?? ''}$detail');
        default:
          throw SyncException('网络异常：${error.message ?? error}');
      }
    }
    throw SyncException('同步失败：$error');
  }

  /// 取出 {ok:true, data:...} 里的 data
  Map<String, dynamic> _unwrap(Response<dynamic> res) {
    final body = res.data;
    if (body is! Map) {
      throw SyncException('服务端返回了非预期内容（请确认地址指向同步服务）');
    }
    if (body['ok'] != true) {
      throw SyncException((body['error'] ?? '接口返回失败').toString());
    }
    final data = body['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{'value': data};
  }

  /// 探活；不需要令牌
  Future<SyncHealth> health() async {
    try {
      final res = await _dio.get<dynamic>('/api/health');
      return SyncHealth.fromJson(_unwrap(res));
    } catch (e) {
      _fail(e);
    }
  }

  /// 领取网页发起的「请同步」待办；没有待办返回 null
  Future<SyncRequestInfo?> claimPendingRequest() async {
    try {
      final res = await _dio.get<dynamic>('/api/sync/pending', queryParameters: <String, dynamic>{
        'deviceId': deviceId,
      });
      final body = res.data;
      if (body is! Map || body['ok'] != true) return null;
      final data = body['data'];
      if (data is! Map) return null;
      return SyncRequestInfo.fromJson(Map<String, dynamic>.from(data));
    } catch (e) {
      _fail(e);
    }
  }

  /// 上报同步进度（给网页显示进度条用）。失败静默 —— 进度丢了不影响同步本身
  Future<void> reportProgress(
    int requestId, {
    String message = '',
    int? current,
    int? total,
  }) async {
    try {
      await _dio.post<dynamic>('/api/sync/progress', data: <String, dynamic>{
        'requestId': requestId,
        'message': message,
        'current': current,
        'total': total,
      });
    } catch (_) {
      // 忽略
    }
  }

  /// 回报待办执行结果
  Future<void> completeRequest(int id, {String status = 'done', String result = ''}) async {
    try {
      await _dio.post<dynamic>(
        '/api/sync/request/$id/complete',
        data: <String, dynamic>{'status': status, 'result': result},
      );
    } catch (e) {
      _fail(e);
    }
  }

  /// 注册设备（幂等，重复注册只是刷新名称与心跳）
  Future<void> registerDevice({String name = '', String platform = 'android'}) async {
    try {
      await _dio.post<dynamic>('/api/sync/devices', data: <String, dynamic>{
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
        'idBase': 1,
      });
    } catch (e) {
      _fail(e);
    }
  }

  /// 增量拉取
  Future<PullResult> pull({required int since, int limit = 500, String? db}) async {
    try {
      final res = await _dio.get<dynamic>('/api/sync/pull', queryParameters: <String, dynamic>{
        'since': since,
        'limit': limit,
        'deviceId': deviceId,
        'db': ?db,
      });
      final data = _unwrap(res);
      final list = (data['changes'] as List? ?? const <dynamic>[])
          .map((e) => SyncChange.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      return PullResult(
        changes: list,
        lastSeq: (data['lastSeq'] as num?)?.toInt() ?? since,
        serverSeq: (data['serverSeq'] as num?)?.toInt() ?? since,
        hasMore: data['hasMore'] == true,
      );
    } catch (e) {
      _fail(e);
    }
  }

  /// 推送一批变更
  Future<PushResult> push(
    List<Map<String, dynamic>> changes, {
    String strategy = 'server-wins',
  }) async {
    try {
      final res = await _dio.post<dynamic>('/api/sync/push', data: <String, dynamic>{
        'deviceId': deviceId,
        'strategy': strategy,
        'changes': changes,
      });
      final data = _unwrap(res);
      final items = (data['results'] as List? ?? const <dynamic>[])
          .map((e) => PushResultItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      return PushResult(
        accepted: (data['accepted'] as num?)?.toInt() ?? 0,
        skipped: (data['skipped'] as num?)?.toInt() ?? 0,
        conflicts: (data['conflicts'] as num?)?.toInt() ?? 0,
        serverSeq: (data['serverSeq'] as num?)?.toInt() ?? 0,
        results: items,
      );
    } catch (e) {
      _fail(e);
    }
  }
}
