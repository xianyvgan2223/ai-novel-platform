/// lib/features/sync/data/address_resolver.dart
///
/// 「怎么连上电脑」的统一入口：按可靠性从高到低逐级尝试，谁先通就用谁。
///
/// 顺序（每一步都比下一步更可靠 / 更快）：
///   1. 上次用过的地址（命中率最高，一次探活就结束）
///   2. **USB 隧道** `http://127.0.0.1:<port>` —— 电脑上跑着 Java 后端
///      （默认自动建 adb reverse）时直接可通，不看 Wi-Fi、不怕防火墙
///   3. 历史网段里的已知地址（换过网络后仍能秒连）
///   4. 本机所在网段的网关地址（电脑直连手机热点 / 手机开了 USB 共享）
///   5. UDP 广播自报（服务端回一句「我在」）
///   6. 整个 /24 网段扫描（兜底）
///
/// 找到的地址会记进 `sync_kv`，下次直接走第 1 步。
library;

import 'dart:io';

import 'server_discovery.dart';

/// 一次解析的结果
class ResolvedAddress {
  final String baseUrl;
  final ChannelKind kind;
  final String service;

  /// 这一轮是按第几步找到的（1 起），用于界面提示与排查
  final int step;

  const ResolvedAddress({
    required this.baseUrl,
    required this.kind,
    required this.service,
    required this.step,
  });

  @override
  String toString() => '${kind.label} · $baseUrl';
}

/// 地址解析器：只管「找出一个能用的地址」，不碰业务接口。
class AddressResolver {
  /// 同步服务默认端口
  static const int defaultPort = ServerDiscovery.defaultPort;

  /// USB 隧道地址（adb reverse 建立后手机上的 127.0.0.1 就是电脑）
  static String usbTunnelUrl([int port = defaultPort]) => 'http://127.0.0.1:$port';

  /// 逐级找出一个可用地址；全都不行返回 null。
  ///
  /// [savedUrl]     上次用的地址（可为空）
  /// [knownUrls]    历史上用过的其他地址
  /// [token]        接口令牌（服务端开了鉴权时需要）
  /// [usbUrl]       本轮是否要试 USB 隧道地址（默认试）
  static Future<ResolvedAddress?> resolve({
    String? savedUrl,
    List<String> knownUrls = const <String>[],
    String? token,
    void Function(String message)? onProgress,
    bool tryUsb = true,
    bool allowScan = true,
    int port = defaultPort,
  }) async {
    final dio = buildProbeDio(token: token);
    final tried = <String>{};
    var step = 0;

    Future<ResolvedAddress?> attempt(
      String url,
      ChannelKind kind,
      String logMessage, {
      bool announce = true,
    }) async {
      final normalized = normalizeBaseUrl(url, port: port);
      if (normalized.isEmpty || !tried.add(normalized)) return null;
      step += 1;
      if (announce) onProgress?.call(logMessage);
      final service = await probeSyncService(normalized, dio: dio);
      if (service == null) return null;
      return ResolvedAddress(baseUrl: normalized, kind: kind, service: service, step: step);
    }

    // 1) 上次用过的地址
    final saved = (savedUrl ?? '').trim();
    if (saved.isNotEmpty) {
      final hit = await attempt(saved, _guessKind(saved), '正在连接上次的地址…');
      if (hit != null) return hit;
    }

    // 2) USB 隧道：手机上的 127.0.0.1 被 adb reverse 转发到电脑
    //
    //    先做一次「本机有没有在监听」的 TCP 连接探测：没建隧道时它会立刻失败，
    //    比等 HTTP 超时快得多（adb reverse 会把连接瞬间重置）。
    if (tryUsb && await _portOpen('127.0.0.1', port)) {
      final hit = await attempt(usbTunnelUrl(port), ChannelKind.usb, '检测到 USB 隧道，正在连接…');
      if (hit != null) return hit;
    }

    // 3) 历史地址（换过网络后仍可能有效，比如回到公司 Wi-Fi）
    for (final url in knownUrls) {
      final hit = await attempt(url, _guessKind(url), '正在试历史地址 $url …', announce: false);
      if (hit != null) return hit;
    }

    // 4) 网关地址：电脑直连手机热点 / 手机开 USB 共享时，网关就是电脑
    final gateways = await ServerDiscovery.gatewayCandidates();
    for (final ip in gateways) {
      final hit = await attempt('http://$ip:$port', ChannelKind.hotspot, '正在试 $ip（热点 / USB 共享）…');
      if (hit != null) return hit;
    }

    if (!allowScan) return null;

    // 5) UDP 广播自报
    final beacon = await ServerDiscovery.broadcastProbe(port: port, onProgress: onProgress);
    if (beacon != null) {
      final hit = await attempt(beacon.baseUrl, ChannelKind.lan, '广播找到 ${beacon.baseUrl}');
      if (hit != null) return hit;
    }

    // 6) 整段扫描（兜底，最慢）
    final scanned = await ServerDiscovery.discover(
      port: port,
      onProgress: onProgress,
      token: token,
      skip: tried,
    );
    if (scanned != null) {
      final hit = await attempt(scanned.baseUrl, ChannelKind.lan, '扫描到 ${scanned.baseUrl}');
      if (hit != null) return hit;
    }

    return null;
  }

  /// 判断某个地址大概是哪种通道（用于界面显示）
  static ChannelKind guessKind(String url) => _guessKind(url);

  static ChannelKind _guessKind(String url) {
    final host = _hostOf(url);
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return ChannelKind.usb;
    if (host.isEmpty) return ChannelKind.manual;
    // 手机热点 / USB 共享的常见网关网段
    if (host.startsWith('192.168.43.') ||
        host.startsWith('192.168.42.') ||
        host.startsWith('192.168.137.') ||
        host.startsWith('172.20.10.')) {
      return ChannelKind.hotspot;
    }
    return ChannelKind.lan;
  }

  /// 补齐协议头与端口，去掉多余斜杠；空串原样返回
  static String normalizeBaseUrl(String raw, {int port = defaultPort}) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) return url;
    // 没写端口就补默认端口（http 的默认 80 显然不是我们要的）
    if (!parsed.hasPort) url = '$url:$port';
    return url;
  }

  static String _hostOf(String url) {
    final parsed = Uri.tryParse(url.contains('://') ? url : 'http://$url');
    return parsed?.host ?? '';
  }

  /// 本机回环端口有没有在监听（adb reverse 建好后为 true）
  static Future<bool> _portOpen(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 250),
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 快速判断 USB 隧道是否已经可用（给界面显示通道状态用）
  static Future<bool> usbTunnelReady({String? token, int port = defaultPort}) async {
    if (!await _portOpen('127.0.0.1', port)) return false;
    return await probeSyncService(usbTunnelUrl(port), token: token) != null;
  }
}
