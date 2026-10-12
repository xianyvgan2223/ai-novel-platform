import 'package:flutter/material.dart';

/// 事件类型标签：「大事件57」/「事件」。
///
/// 「大纲编辑」的选择事件页与编辑页共用这一处实现，保证两个页面上的类型标签
/// 与序号写法一致——序号是该大事件在正文里的「大事件N」（见
/// outline_event_syntax.dart 的 normalizeOutlineText：大事件全篇从 1 连续编号）。
///
/// 小事件原先显示「章节」，与卡片上的「N 个事件」「已选 N 个事件」用词不一致
/// （同一屏里一会儿叫章、一会儿叫事件），统一成「事件」。
class EventTypeTag extends StatelessWidget {
  final bool isMajor;

  /// 大事件序号；为 null 时只显示「大事件」（全篇章节还没读出来时）
  final int? majorNumber;

  final Color background;
  final Color foreground;

  /// 序号颜色；默认与 [foreground] 同色（靠加粗区分）
  final Color? numberColor;

  const EventTypeTag({
    super.key,
    required this.isMajor,
    required this.background,
    required this.foreground,
    this.majorNumber,
    this.numberColor,
  });

  @override
  Widget build(BuildContext context) {
    final number = isMajor ? majorNumber : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: isMajor ? '大事件' : '事件'),
            if (number != null)
              TextSpan(
                text: '$number',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: numberColor ?? foreground,
                ),
              ),
          ],
        ),
        style: TextStyle(fontSize: 10, color: foreground),
      ),
    );
  }
}
