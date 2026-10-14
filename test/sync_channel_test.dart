/// test/sync_channel_test.dart —— 连接通道解析（地址归一化 / 通道识别 / 逐级解析）
///
/// 纯逻辑部分（前两组）始终运行；「能连上电脑」的部分需要电脑上跑着同步服务，
/// 没有服务时会自动跳过，不会让 `flutter test` 变红。
///
/// 想完整验证（含 USB 隧道）：
///   cd web/server; npm start          # 另开一个窗口
///   npm run usb                       # 建 USB 隧道（可选）
///   flutter test test/sync_channel_test.dart
library;

import 'package:deepseekapp/features/sync/data/address_resolver.dart';
import 'package:deepseekapp/features/sync/data/server_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('地址归一化', () {
    test('只填 IP / 缺端口 / 多打斜杠都能补全', () {
      expect(AddressResolver.normalizeBaseUrl('192.168.1.5'), 'http://192.168.1.5:3210');
      expect(AddressResolver.normalizeBaseUrl('192.168.1.5:3210/'), 'http://192.168.1.5:3210');
      expect(AddressResolver.normalizeBaseUrl('http://127.0.0.1:3210'), 'http://127.0.0.1:3210');
      expect(AddressResolver.normalizeBaseUrl('  http://10.0.0.2:8080//  '), 'http://10.0.0.2:8080');
      expect(AddressResolver.normalizeBaseUrl(''), '');
    });

    test('USB 隧道地址就是回环地址', () {
      expect(AddressResolver.usbTunnelUrl(), 'http://127.0.0.1:3210');
      expect(AddressResolver.usbTunnelUrl(4000), 'http://127.0.0.1:4000');
    });
  });

  group('通道识别', () {
    test('回环 = USB 隧道，热点网段 = 热点，其余 = 局域网', () {
      expect(AddressResolver.guessKind('http://127.0.0.1:3210'), ChannelKind.usb);
      expect(AddressResolver.guessKind('http://localhost:3210'), ChannelKind.usb);
      expect(AddressResolver.guessKind('http://192.168.43.5:3210'), ChannelKind.hotspot);
      expect(AddressResolver.guessKind('http://192.168.42.1:3210'), ChannelKind.hotspot);
      expect(AddressResolver.guessKind('http://192.168.137.1:3210'), ChannelKind.hotspot);
      expect(AddressResolver.guessKind('http://172.20.10.1:3210'), ChannelKind.hotspot);
      expect(AddressResolver.guessKind('http://10.33.66.104:3210'), ChannelKind.lan);
    });

    test('通道名称可读', () {
      expect(ChannelKind.usb.label, 'USB 隧道');
      expect(ChannelKind.lan.label, '局域网 Wi-Fi');
    });
  });

  // 下面这组需要电脑上真的跑着同步服务；没有就跳过。
  group('解析链（需要电脑上的服务）', () {
    late bool serverUp;

    setUpAll(() async {
      serverUp = await probeSyncService(AddressResolver.usbTunnelUrl()) != null;
      if (!serverUp) {
        // 回环不通时再试一次局域网（本机跑测试时两种情况都可能）
        serverUp = await probeSyncService('http://localhost:3210') != null;
      }
    });

    test('回环地址能认出同步服务', () async {
      if (!serverUp) {
        markTestSkipped('电脑上没跑同步服务（web/server 执行 npm start 后重跑）');
        return;
      }
      final service = await probeSyncService(AddressResolver.usbTunnelUrl());
      expect(service, contains('deepseekapp'));
    });

    test('解析链优先命中 USB 隧道地址', () async {
      if (!serverUp) {
        markTestSkipped('电脑上没跑同步服务');
        return;
      }
      final resolved = await AddressResolver.resolve(
        savedUrl: 'http://10.255.255.1:3210', // 故意给一个不存在的地址
        allowScan: false, // 只走到隧道那一步，别让扫描拖慢测试
      );
      expect(resolved, isNotNull);
      expect(resolved!.baseUrl, 'http://127.0.0.1:3210');
      expect(resolved.service, contains('deepseekapp'));
    });
  });
}
