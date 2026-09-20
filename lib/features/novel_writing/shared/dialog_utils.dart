import 'package:flutter/material.dart';

/// 弹窗安全关闭与临时控制器释放工具。
///
/// 背景：弹窗内「确定/取消」按钮若快速连点，会执行两次 `Navigator.pop`——
/// 第一次关闭弹窗，第二次会把**下层页面**一起弹掉；弹窗退场动画尚未结束时
/// 元素树被连带停用，会触发框架断言
/// （framework.dart `_dependents.isEmpty`: is not true）。
///
/// 另外，弹窗内的临时 TextEditingController 若在弹窗退场动画完成前 dispose，
/// 仍挂载的 TextField 会使用已释放的控制器，同样引发框架异常。
///
/// 用法：
/// ```dart
/// onPressed: () {
///   if (!closeDialogSafely(ctx)) return; // 已在关闭中则忽略本次点击
///   scheduleControllerDispose(editCtrl); // 退场后再释放
/// }
/// ```

/// 安全关闭当前弹窗：仅当该路由仍是栈顶（未被关闭/未在退场）时执行 pop，
/// 避免快速连点导致的重复 pop 连带关闭下层页面。
/// 返回 true 表示本次点击实际执行了关闭。
bool closeDialogSafely(BuildContext ctx, {Object? result}) {
  final route = ModalRoute.of(ctx);
  if (route == null || !route.isCurrent) return false; // 弹窗已在关闭中
  Navigator.of(ctx).pop(result);
  return true;
}

/// 延迟释放弹窗内的临时控制器：等弹窗退场动画（约 150-250ms）结束后再 dispose，
/// 避免在仍挂载的 TextField 上释放控制器引发框架异常。
void scheduleControllerDispose(
  TextEditingController ctrl, {
  Duration delay = const Duration(milliseconds: 400),
}) {
  Future<void>.delayed(delay, ctrl.dispose);
}
