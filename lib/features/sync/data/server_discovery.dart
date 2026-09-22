/// lib/features/sync/data/server_discovery.dart
///
/// 局域网自动发现同步服务：扫描本机所在网段，找到跑着同步服务的电脑。
/// 目的是免去手工输入 IP —— 尤其是手机热点场景，电脑的地址每次可能都不一样。
library;

import 'dart:io';

import 'package:dio/dio.dart';

/// 找到的服务
class DiscoveredServer {
  final String baseUrl;
  final String service;

  DiscoveredServer(this.baseUrl, this.service);

  @override
  String toString() => baseUrl;
}

class ServerDiscovery {
  static const int defaultPort = 3210;

  /// 取本机所有非回环 IPv4 所在的 /24 网段前缀（形如 "192.168.43"）
  static Future<List<String>> localIpv4Prefixes() async {
    final prefixes = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
          }
        }
      }
    } catch (_) {
      // 拿不到网卡信息时按空处理，交由调用方提示
    }
    // 家用 / 热点网段优先，避免先扫 172.x 这类虚拟网卡
    final list = prefixes.toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    return list;
  }

  static int _rank(String prefix) {
    if (prefix.startsWith('192.168.')) return 0;
    if (prefix.startsWith('10.')) return 1;
    if (prefix.startsWith('172.')) return 2;
    return 3;
  }

  /// 扫描并返回第一个响应正常的同步服务；找不到返回 null
  static Future<DiscoveredServer?> discover({
    int port = defaultPort,
    void Function(String message)? onProgress,
    Duration timeout = const Duration(milliseconds: 320),
    int concurrency = 64,
  }) async {
    final prefixes = await localIpv4Prefixes();
    if (prefixes.isEmpty) {
      onProgress?.call('没有可用的局域网地址');
      return null;
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );

    for (var p = 0; p < prefixes.length; p++) {
      final prefix = prefixes[p];
      onProgress?.call('正在扫描 $prefix.x …');

      final queue = <String>[
        for (var i = 1; i <= 254; i++) '$prefix.$i',
      ];

      while (queue.isNotEmpty) {
        final batch = queue.take(concurrency).toList();
        queue.removeRange(0, batch.length);

        final hits = await Future.wait(
          batch.map((ip) async {
            final base = 'http://$ip:$port';
            try {
              final res = await dio.get<dynamic>('$base/api/health');
              final body = res.data;
              if (body is Map && body['ok'] == true) {
                final data = body['data'];
                final service =
                    (data is Map ? data['service']?.toString() : null) ?? '';
                // 只认自己的服务，避免把别的机器上的 3210 端口当成同步服务
                if (service.contains('deepseekapp')) {
                  return DiscoveredServer(base, service);
                }
              }
            } catch (_) {
              // 该地址没有服务，继续
            }
            return null;
          }),
        );

        for (final hit in hits) {
          if (hit != null) return hit;
        }
      }
    }
    return null;
  }
}
