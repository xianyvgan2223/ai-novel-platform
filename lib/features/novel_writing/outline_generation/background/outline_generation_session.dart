/// 「一键生成大纲」的进程级生成会话。
///
/// 背景：生成状态（Dio 流式请求、解析、断点草稿、进度气泡）原本由页面 State
/// 持有的 [OutlineController] 管理，页面一 pop 就 dispose，正在跑的请求被
/// cancel —— 用户中途退出或切到后台就前功尽弃。把 controller 提升为会话后：
/// - 页面只是「视图」：关闭时只 detach 监听，生成继续跑；
/// - 重新进入页面（从菜单 / 历史 / 点通知栏通知）时 attach 回同一个 controller，
///   进度条、流式气泡、检查点卡片、滚动位置都还是原来的；
/// - 生成真正结束且用户关掉页面后才 dispose，避免常驻内存。
///
/// 生命周期约定：
/// - [acquireForPage]：`preferExisting: false` 用于「从历史大纲重新生成 / 继续生成」
///   这类必须全新实例的入口；默认 true 优先复用现有会话（包括已完成但还没看过结果的）；
/// - [detachFromPage]：生成中 / 检查点等待中 → 保留（这正是「后台生成」的关键）；
///   空闲（完成 / 取消 / 失败）→ dispose 并清空。
library;

import 'package:flutter/foundation.dart';

import '../controller/outline_controller.dart';

/// [acquireForPage] 的返回：页面需要知道拿到的是不是已有会话，
/// 已有会话时不能再用 `initialRecord` 覆盖输入框，也不能重复触发局部重新生成。
typedef OutlineSessionAttach = ({
  OutlineController controller,
  bool attachedExisting,
});

class OutlineGenerationSession {
  OutlineGenerationSession._();

  static final OutlineGenerationSession instance = OutlineGenerationSession._();

  OutlineController? _controller;

  /// 当前会话里的控制器（没有则为 null；主要给测试和调试用）。
  OutlineController? get current => _controller;

  /// 是否有一个「生成中 / 检查点等待中」的会话需要在页面关闭后继续保留。
  bool get isBusy => _controller?.isRunning ?? false;

  /// 页面打开时取 controller。
  ///
  /// [preferExisting] 为 false 且现有 controller 空闲时，会先销毁旧的再新建，
  /// 保证「历史大纲重新生成 / 继续生成」不会串进上一份临时状态。
  ///
  /// [debugControllerFactory] 仅供单测注入带假通知器的 controller，
  /// 生产调用不要传。
  OutlineSessionAttach acquireForPage({
    bool preferExisting = true,
    @visibleForTesting OutlineController Function()? debugControllerFactory,
  }) {
    final existing = _controller;
    if (existing != null && (preferExisting || existing.isRunning)) {
      return (controller: existing, attachedExisting: true);
    }
    existing?.dispose();
    final created = debugControllerFactory?.call() ?? OutlineController();
    _controller = created;
    return (controller: created, attachedExisting: false);
  }

  /// 页面关闭时归还 controller：生成中 / 检查点等待中保留，空闲销毁。
  void detachFromPage(OutlineController controller) {
    if (!identical(_controller, controller)) return;
    if (controller.isRunning) return;
    _controller = null;
    controller.dispose();
  }

  /// 测试用：强制清空会话（正常流程不要调用）。
  @visibleForTesting
  void resetForTest() {
    _controller?.dispose();
    _controller = null;
  }
}
