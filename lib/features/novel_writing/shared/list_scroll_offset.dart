import 'package:flutter/widgets.dart';

/// 「进入下级页面 → 返回后仍停在原来区域」用的一对工具。
///
/// 页面跳转本身不会丢滚动位置（被压住的路由仍在树上），真正会把位置清零的是
/// **返回后的刷新**：刷新时若把列表切成整页 loading，ListView / GridView 会被
/// 从树上拆掉，滚动位置随之丢失，返回时界面就跳回顶部了。约定三步走：
/// 1. 跳转前用 [captureScrollOffset] 记下位置；
/// 2. 返回后刷新数据时保留列表（`_load(showLoading: false)`，不切整页 loading）；
/// 3. 刷新完用 [restoreScrollOffset] 定位回原处（兜底，兼防列表确实被重建）。
///
/// 记下进入下级页面时的滚动位置（列表还没建好时按 0 处理）。
double captureScrollOffset(ScrollController controller) =>
    controller.hasClients ? controller.offset : 0.0;

/// 把列表滚回返回前的 [offset]。
///
/// 列表没被重建时位置本来就在，直接返回；位置被重建或内容变短而越界时，
/// 等本帧布局结束（可滚动范围已按新内容更新）再按范围钳制定位。
void restoreScrollOffset(ScrollController controller, double offset) {
  if (!controller.hasClients) return;
  if ((controller.offset - offset).abs() < 0.5) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final target = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((position.pixels - target).abs() > 0.5) controller.jumpTo(target);
  });
  // 调用方（刷新数据）不一定重建过界面，这里确保这一帧会发生，
  // 上面的帧后回调才会被执行
  WidgetsBinding.instance.ensureVisualUpdate();
}
