/// 「听大纲」的进程级朗读会话。
///
/// 背景：朗读状态（TTS 引擎、当前事件 / 句子、播放计划、通知进度）原本由页面
/// State 持有的 [OutlineListenController] 管理，页面一 pop 就 dispose，朗读随之
/// 停止——而「听大纲」最重要的使用场景恰恰是**放下手机继续听**。把 controller
/// 提升为进程级会话后：
/// - 页面只是「视图」：关闭时只 detach 监听，朗读继续（由 Android 前台服务保活）；
/// - 通知点击回来（或从小说列表重新进入同一条大纲）时，挂回同一个 controller，
///   当前事件、当前句、高亮、句子进度都还在；
/// - 用户停止朗读 / 整篇听完且页面已关闭后，会话自动释放，不常驻内存。
///
/// 通知栏上的「上一个 / 暂停继续 / 停止」也由这里转给当前 controller
/// （见 [handleNotificationAction]）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../shared/domain/outline_chapter.dart';
import '../../shared/domain/outline_record.dart';
import '../controller/outline_listen_controller.dart';

/// [acquire] 的返回：页面需要知道拿到的是不是已有会话
/// （已有会话时不能再 init/load，否则会把正在朗读的位置冲掉）。
typedef OutlineListenSessionAttach = ({
  OutlineListenController controller,
  bool attachedExisting,
});

class OutlineListenSession {
  OutlineListenSession._();

  static final OutlineListenSession instance = OutlineListenSession._();

  OutlineListenController? _controller;

  /// 当前会话对应的大纲记录（通知点击时要靠它重新打开朗读页）
  OutlineRecord? _record;

  /// 打开页面时带进来的章节快照（仅做兜底；controller 自己会按库校正）
  List<OutlineChapter>? _chapters;

  /// 当前挂着的页面数（页面 acquire 时 +1，detachPage 时 -1）
  int _attachedPages = 0;

  bool _disposeScheduled = false;

  /// 当前朗读中的 controller（没有会话时为 null）
  OutlineListenController? get controller => _controller;

  /// 当前会话的大纲记录（通知点击导航用；没有会话时为 null）
  OutlineRecord? get activeRecord => _controller == null ? null : _record;

  bool get hasActiveSession => _controller != null;

  /// 页面打开时取 controller。
  ///
  /// [preferExisting] 为 true 且是**同一条大纲**时挂回原来的 controller：
  /// 后台朗读中 / 暂停中从通知点回来、或从列表重新点进同一条，位置都不丢。
  /// 不是同一条大纲（或没有会话）时释放旧的、按传入数据新建。
  OutlineListenSessionAttach acquire(
    OutlineRecord outline,
    List<OutlineChapter>? chapters, {
    bool preferExisting = true,
  }) {
    final existing = _controller;
    final sameOutline =
        existing != null && _record?.id != null && _record!.id == outline.id;
    if (existing != null &&
        sameOutline &&
        preferExisting &&
        existing.isSessionNeeded) {
      _attachedPages++;
      return (controller: existing, attachedExisting: true);
    }
    _disposeCurrent();
    final created = OutlineListenController(outline);
    _controller = created;
    _record = outline;
    _chapters = chapters;
    _attachedPages = 1;
    created.addListener(_onControllerChanged);
    return (controller: created, attachedExisting: false);
  }

  /// 页面关闭时归还 controller：
  /// - 还在朗读 / 暂停在某个位置 → 保留（后台继续，通知还在）；
  /// - 已经停止 / 整篇听完 → 没有保留价值，直接释放
  ///   （「听完」保留到用户看过页面为止：页面关闭时才算看完）。
  void detachPage(OutlineListenController controller) {
    if (!identical(_controller, controller)) return;
    if (_attachedPages > 0) _attachedPages--;
    if (_attachedPages > 0) return;
    if (controller.isSessionNeeded && !controller.finished) return;
    _disposeCurrent();
  }

  /// controller 状态变化：页面已关闭且已经没有朗读位置（停止 / 听完）时自动释放。
  ///
  /// 不能在 notifyListeners 的同一帧里 dispose（监听者还在遍历），
  /// 用微任务推迟到本轮通知结束之后。
  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null) return;
    if (_attachedPages > 0) return;
    if (controller.isSessionNeeded) return;
    _scheduleDispose();
  }

  void _scheduleDispose() {
    if (_disposeScheduled) return;
    _disposeScheduled = true;
    scheduleMicrotask(() {
      _disposeScheduled = false;
      final controller = _controller;
      if (controller == null) return;
      if (_attachedPages > 0) return;
      if (controller.isSessionNeeded) return;
      _disposeCurrent();
    });
  }

  /// 通知栏操作按钮：上一个事件 / 暂停继续 / 停止；以及媒体通知系统控制
  /// 可能回传的 play / pause / next。
  ///
  /// 返回是否真的处理了（没有会话时返回 false，调用方可以忽略）。
  Future<bool> handleNotificationAction(String action) async {
    final controller = _controller;
    if (controller == null) return false;
    switch (action) {
      case 'prev':
        await controller.previous();
        return true;
      case 'next':
        await controller.next();
        return true;
      case 'toggle':
        await controller.toggle();
        return true;
      case 'play':
        // 系统媒体面板/锁屏播放键可能在已播放时也发 play：重复调 play() 会把
        // 当前句从头再读一遍，这里按「真的没在播才播」过滤（pause 自带幂等）。
        if (!controller.playing) await controller.play();
        return true;
      case 'pause':
        await controller.pause();
        return true;
      case 'rewind':
        // 通知展开视图的「退 3 句」：只在当前事件内相对跳
        await controller.seekBy(-3);
        return true;
      case 'forward':
        await controller.seekBy(3);
        return true;
      case 'stop':
        await controller.stop();
        return true;
      default:
        return false;
    }
  }

  /// 媒体通知 seekbar 拖动松手：按当前事件内相对进度跳句。
  ///
  /// 返回是否处理（没有会话时 false；拖动事件有时效性，排队等会话恢复反而怪）。
  Future<bool> seekToFraction(double fraction) async {
    final controller = _controller;
    if (controller == null) return false;
    await controller.seekToFraction(fraction);
    return true;
  }

  void _disposeCurrent() {
    final old = _controller;
    _controller = null;
    _record = null;
    _chapters = null;
    _attachedPages = 0;
    if (old != null) {
      old.removeListener(_onControllerChanged);
      old.dispose();
    }
  }

  /// 测试用：强制清空会话（正常流程不要调用）。
  @visibleForTesting
  void resetForTest() {
    _disposeCurrent();
    _disposeScheduled = false;
  }

  /// 测试用：当前会话的章节快照（不为空时页面可跳过读库，仓库里暂无调用方）。
  List<OutlineChapter>? get chapters => _chapters;
}
