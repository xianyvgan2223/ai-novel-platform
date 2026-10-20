import 'package:flutter/material.dart';

/// 事件类型标签：「大事件57」/「小事件2」。
///
/// 「大纲编辑」的选择事件页与编辑页共用这一处实现，保证两个页面上的类型标签
/// 与序号写法一致——序号就是大纲正文里的写法：
/// - 大事件全篇只数大事件，从 1 连续（`══ 大事件N：`）；
/// - 小事件在**所属大事件内部**从 1 重新计数（`○ 小事件N：`）。
///
/// 两者的序号都由 `majorEventNumbers` / `minorEventNumbers`
/// （shared/domain/outline_chapter.dart）算好传进来，**不要**在这里拿
/// `eventIndex` 现算：它是所有事件（含大事件）的连续序号，小事件会跳号，
/// 与正文里的「○ 小事件1」对不上。
///
/// 小事件原先显示「章节」、后来显示「事件」：前者与卡片上的「N 个事件」用词
/// 不一致，后者又看不出这是小事件；现在统一成「小事件」，有编号时紧跟在后面。
class EventTypeTag extends StatelessWidget {
  final bool isMajor;

  /// 大事件序号（全篇只数大事件）；为 null 时只显示「大事件」
  /// （全篇章节还没读出来时）
  final int? majorNumber;

  /// 小事件序号（在所属大事件内部从 1 重新计数）；为 null 时只显示「小事件」
  final int? minorNumber;

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
    this.minorNumber,
    this.numberColor,
  });

  @override
  Widget build(BuildContext context) {
    final number = isMajor ? majorNumber : minorNumber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: isMajor ? '大事件' : '小事件'),
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
