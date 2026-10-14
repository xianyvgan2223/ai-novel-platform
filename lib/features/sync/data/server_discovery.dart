/// lib/features/sync/data/server_discovery.dart
///
/// 找到「电脑上的同步服务」，并给出各种可用的连接通道。
///
/// 连接通道按可靠性排序：
///   1. **USB 隧道**（adb reverse）—— 手机插着数据线，访问 `http://127.0.0.1:3210`
///      就能到电脑。不看 Wi-Fi、不经过路由器、不受电脑防火墙影响，最稳。
///   2. **局域网直连** —— 电脑直连手机热点 / 手机 USB 共享时，网关就是电脑，
///      常用固定网段（192.168.43.x / 192.168.42.x / 192.168.137.x）先试一遍。
///   3. **局域网广播自报** —— UDP 广播一句「谁在？」，服务端回一句「我在」，
///      免去逐个 IP 扫 254 次。
///   4. **网段扫描** —— 最后兜底。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// 一条连接通道的种类
enum ChannelKind {
  /// USB 隧道（adb reverse）：手机上的 127.0.0.1 被转发到电脑
  usb,

  /// 局域网（Wi-Fi / 有线，两边同一个网段）
  lan,

  /// 电脑直连手机热点，或手机开了 USB 网络共享
  hotspot,

  /// 手动填的地址 / 历史地址
  manual,
}

extension ChannelKindLabel on ChannelKind {
  String get label {
    switch (this) {
      case ChannelKind.usb:
        return 'USB 隧道';
      case ChannelKind.lan:
        return '局域网 Wi-Fi';
      case ChannelKind.hotspot:
        return '热点 / USB 共享';
      case ChannelKind.manual:
        return '手动地址';
    }
  }
}

/// 找到的服务
class DiscoveredServer {
  final String baseUrl;
  final String service;
  final ChannelKind kind;

  const DiscoveredServer(this.baseUrl, this.service, {this.kind = ChannelKind.manual});

  @override
  String toString() => baseUrl;
}

/// 广播探测 / 逐个探活共用的轻量 HTTP 客户端
Dio buildProbeDio({Duration timeout = const Duration(milliseconds: 320), String? token}) {
  final headers = <String, dynamic>{};
  final trimmed = (token ?? '').trim();
  if (trimmed.isNotEmpty) headers['x-api-token'] = trimmed;
  return Dio(
    BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      sendTimeout: timeout,
      headers: headers,
    ),
  );
}

/// 单个地址探活：是同步服务就返回它的名字，否则 null
Future<String?> probeSyncService(String baseUrl, {Dio? dio, String? token}) async {
  final client = dio ?? buildProbeDio(token: token);
  try {
    final res = await client.get<dynamic>('$baseUrl/api/health');
    final body = res.data;
    if (body is Map && body['ok'] == true) {
      final data = body['data'];
      final service = (data is Map ? data['service']?.toString() : null) ?? '';
      // 只认自己的服务，避免把别的机器上的同号端口当成同步服务
      if (service.contains('deepseekapp')) return service;
    }
  } catch (_) {
    // 该地址没有服务，继续找下一个
  }
  return null;
}

class ServerDiscovery {
  static const int defaultPort = 3210;

  /// UDP 广播探测端口（服务端在 3211 上等这一句）
  static const int beaconPort = 3211;

  static const String _beaconAsk = 'deepseekapp-sync?';

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
    if (prefix.startsWith('192.168.43')) return 0; // Android 热点
    if (prefix.startsWith('192.168.42')) return 1; // 手机 USB 共享
    if (prefix.startsWith('192.168.137')) return 1; // Windows 移动热点
    if (prefix.startsWith('192.168.') || prefix.startsWith('10.')) return 2;
    if (prefix.startsWith('172.')) return 4;
    return 3;
  }

  /// 本机所有 IPv4 的 x.y.z 前缀 + 该网段的 x.y.z.1（网关），按优先级排好
  static Future<List<String>> gatewayCandidates() async {
    final prefixes = await localIpv4Prefixes();
    final out = <String>[];
    for (final prefix in prefixes) {
      out.add('$prefix.1');
      // 热点 / USB 共享时电脑常见地址，有时不是 .1
      out.add('$prefix.2');
      out.add('$prefix.129');
    }
    return out;
  }

  /// UDP 广播：问一句「谁在？」，等服务端自报地址。找不到返回 null。
  ///
  /// 这一步是「秒连」的关键 —— 广播包一发，服务端就知道该把自己的
  /// 局域网地址回给谁，不用扫 254 个 IP。
  static Future<DiscoveredServer?> broadcastProbe({
    int port = defaultPort,
    Duration timeout = const Duration(milliseconds: 700),
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在广播查找电脑…');
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<DiscoveredServer?>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        try {
          final payload = jsonDecode(utf8.decode(datagram.data));
          if (payload is! Map) return;
          if (payload['service']?.toString().contains('deepseekapp') != true) return;
          final port = payload['port'] ?? ServerDiscovery.defaultPort;
          // 回包来自哪台机器，就用那个源地址；服务端再附带自己认到的局域网地址
          final source = datagram.address.address;
          final url = 'http://$source:$port';
          if (!completer.isCompleted) {
            completer.complete(
              DiscoveredServer(url, payload['service'].toString(), kind: ChannelKind.lan),
            );
          }
        } catch (_) {
          // 不是我们的广播，忽略
        }
      });

      final bytes = utf8.encode(_beaconAsk);
      for (final target in <String>['255.255.255.255', ...await _subnetBroadcasts()]) {
        try {
          socket.send(bytes, InternetAddress(target), beaconPort);
        } catch (_) {
          // 该网段不允许广播，跳过
        }
      }

      final found = await completer.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      await subscription.cancel();
      return found;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  /// 各网段的定向广播地址（某些系统不转发 255.255.255.255）
  static Future<List<String>> _subnetBroadcasts() async {
    final out = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) out.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {
      // 忽略
    }
    return out;
  }

  /// 扫描并返回第一个响应正常的同步服务；找不到返回 null
  static Future<DiscoveredServer?> discover({
    int port = defaultPort,
    void Function(String message)? onProgress,
    Duration timeout = const Duration(milliseconds: 320),
    int concurrency = 64,
    String? token,
    /// 已经试过的地址，不再重复扫（省时间）
    Set<String> skip = const <String>{},
  }) async {
    final dio = buildProbeDio(timeout: timeout, token: token);

    // 先来一发广播，命中就省掉整轮扫描
    final beacon = await broadcastProbe(port: port, onProgress: onProgress);
    if (beacon != null && !skip.contains(beacon.baseUrl)) {
      final service = await probeSyncService(beacon.baseUrl, dio: dio);
      if (service != null) {
        return DiscoveredServer(beacon.baseUrl, service, kind: ChannelKind.lan);
      }
    }

    final prefixes = await localIpv4Prefixes();
    if (prefixes.isEmpty) {
      onProgress?.call('没有可用的局域网地址');
      return null;
    }

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
            if (skip.contains(base)) return null;
            final service = await probeSyncService(base, dio: dio);
            return service == null ? null : DiscoveredServer(base, service);
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
