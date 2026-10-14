/// lib/core/widgets/keyboard_inset_padding.dart
///
/// 键盘升起时把内容顶上去，但**不重建内容**。
///
/// 背景：输入法弹出动画期间，引擎每帧都会派发一次窗口 metrics 变化
/// （Flutter 框架 editable_text.dart 里 `_EditableTextState.didChangeMetrics`
/// 的注释原文：`Because the metrics change signal from engine will come here
/// every frame (on both iOS and Android)`），`MediaQuery.viewInsets.bottom`
/// 因此逐帧变化。
///
/// 常见的写法是：
/// ```dart
/// builder: (ctx) => Padding(
///   padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
///   child: MyDialog(),        // ← 闭包每帧重跑，内容每帧重建
/// ),
/// ```
/// 这里读 viewInsets 的是 `builder` 所在的那个 Element，它每帧被标记重建，
/// 于是 `MyDialog` 每帧重新构造、整棵子树跟着重建。
///
/// 正确做法是把「读 viewInsets」收进一个只包一层 Padding 的小组件，
/// 内容作为 `child` 传进来——**而且这个 child 必须在不会每帧重跑的
/// build 里构造**（例如 showDialog 之前先构造好，或放在外层 build 里），
/// 否则每帧仍然会 new 出一个新实例，Flutter 就无法跳过它的 rebuild。
library;

import 'package:flutter/widgets.dart';

/// 把 [child] 按键盘高度顶起；[child] 自身不会因为键盘动画被重建。
///
/// 用法（注意 child 要提前构造好，不要写在会每帧重跑的闭包里）：
/// ```dart
/// final content = _WordCountDialog(initialWords: words);   // 只构造一次
/// showDialog<int>(
///   context: context,
///   builder: (_) => KeyboardInsetPadding(child: content),
/// );
/// ```
class KeyboardInsetPadding extends StatelessWidget {
  const KeyboardInsetPadding({super.key, required this.child});

  /// 需要跟着键盘上移的内容。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: child,
    );
  }
}
