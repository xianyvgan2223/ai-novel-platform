/// lib/features/sync/application/sync_poller.dart
///
/// 前台轮询：电脑（网页）点了「同步手机」之后，手机会收到一条待办。
/// **不会自动执行** —— 先弹窗询问用户是否同意，同意后才做整库同步。
///
/// 生命周期策略：
///   App 回到前台 → 每 5 秒问一次服务端有没有待办
///   App 退到后台 → 停止轮询（省电，也避免被系统限制）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'sync_service.dart';

class SyncPoller with WidgetsBindingObserver {
  SyncPoller._();

  static final SyncPoller instance = SyncPoller._();

  /// 轮询间隔
  static const Duration interval = Duration(seconds: 5);

  /// 挂到 MaterialApp 上，方便在任意位置弹提示
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// 询问用户的回调，由 main.dart 注入（用全局 navigatorKey 弹窗）。
  /// 返回 true = 同意，false = 拒绝，null = 当前无法询问（界面未就绪），下轮再试。
  Future<bool?> Function(PendingSyncCandidate candidate)? confirmHandler;

  Timer? _timer;
  bool _busy = false;
  bool _started = false;

  /// 在 main() 里调用一次
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _restartTimer();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _started = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restartTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy) return;

    final candidate = await SyncService.peekPendingRequest();
    if (candidate == null) return; // 没有待办或连不通，安静跳过

    final handler = confirmHandler;
    if (handler == null) return; // 界面还没接上：宁可等，也不擅自改数据

    _busy = true;
    try {
      final decision = await handler(candidate);
      if (decision == null) return; // 暂时问不了，下一轮再试

      if (!decision) {
        await SyncService.rejectPendingCandidate(candidate);
        _notify('已拒绝电脑发起的同步请求', warning: true);
        return;
      }

      final outcome = await SyncService.executePendingCandidate(candidate);
      if (!outcome.handled) return;
      if (outcome.error != null) {
        _notify('电脑请求的整库同步失败：${SyncService.describeError(outcome.error!)}', isError: true);
      } else {
        _notify('电脑请求的整库同步已完成：${outcome.summary}');
      }
    } catch (_) {
      // 轮询本身不该打扰用户
    } finally {
      _busy = false;
    }
  }

  void _notify(String message, {bool isError = false, bool warning = false}) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        backgroundColor: isError
            ? const Color(0xFFFF4D4F)
            : warning
                ? const Color(0xFFF59E0B)
                : const Color(0xFF10B981),
      ),
    );
  }
}
