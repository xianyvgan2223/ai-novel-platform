// lib/core/widgets/settings_kit.dart
// 功能页设置界面的共用组件库（纯 UI，不依赖 Riverpod / 数据层）。
//
// 来源：主设置页 v2（lib/features/chat/presentation/settings_page.dart）里
// 已验收的视觉语言在这里「原样」抽出并公开化，供会话设置 / 大纲生成设置 /
// 章节写作设置 / 战斗设置等功能页复用，避免 5 个页面各写一套。
//
// 设计语言（改这里之前先想清楚，所有功能页会一起变）：
// - 页面浅灰底 + 白色圆角卡片（16dp 圆角 + 柔和投影，不描边）；
//   卡片只承担「内容块」，区块标题在卡外：26dp 图标 chip + 14sp 标题
//   + 11.5sp 副标题；
// - 每行统一「左标签 + 右值」：值一律右对齐，下拉 = 值 + 小箭头、开关贴右，
//   所有右边缘都落在卡片 16dp 内边距这条线上；
// - 文本参数是「无框右对齐输入」，聚焦时才出现一条 1px 主色下划线；
//   只有「焦点输入」（API Key / 提示词这类）才用填充式输入框；
// - 窄屏或大字号下，长标签放不下时自动把「左标签 + 右控件」改成两行堆叠，
//   判定基于真实字体测量（见 _useStackedRow），不按字号阈值猜。
//
// 用法示例：
// ```dart
// Scaffold(
//   backgroundColor: kSettingsPageBg,
//   appBar: SettingsAppBar(title: '会话设置', onSave: _onSave),
//   body: ListView(
//     padding: EdgeInsets.only(
//       top: 2,
//       left: kSettingsCardMarginH,
//       right: kSettingsCardMarginH,
//       bottom: 40 + MediaQuery.paddingOf(context).bottom,
//     ),
//     children: [
//       const SettingsSectionHeader(
//         icon: Icons.chat_rounded,
//         title: '会话参数',
//         subtitle: '只影响当前会话',
//         isFirst: true,
//       ),
//       SettingsCard(children: [
//         SettingsSwitchRow(
//           label: 'stream',
//           subtitle: '逐字返回',
//           initialValue: true,
//           onChanged: (v) {},
//         ),
//       ]),
//     ],
//   ),
// )
// ```

import 'package:flutter/material.dart';

// ─── 视觉令牌：整页只从这里取色取尺寸，功能页不要在行内写新的魔法数字 ───

/// 全页唯一强调色（选中值 / 图标 chip / 保存按钮 / 聚焦线 / 滑杆）。
const Color kSettingsPrimary = Color(0xFF4D6BFE);

/// 图标 chip 的浅色底（分区标题、动作行、焦点卡共用）。
const Color kSettingsPrimarySoft = Color(0xFFEEF2FF);

const Color kSettingsPageBg = Color(0xFFF4F5F7);
const Color kSettingsCardBg = Color(0xFFFFFFFF);

/// 分区标题 / 卡片标题。
const Color kSettingsTitle = Color(0xFF14161A);

/// 行标签。
const Color kSettingsLabel = Color(0xFF1F2329);

/// 右侧值（以及无框输入框里的文字）。
const Color kSettingsValue = Color(0xFF5A6474);

/// 分区副标题 / 行说明。
const Color kSettingsSubtitle = Color(0xFF8A93A5);

/// 输入提示文字：白卡上对比度约 3.08:1（不要再调浅，无障碍不达标）。
/// 与 [kSettingsSubtitle] 同色，视觉上仍明显浅于值文本。
const Color kSettingsHint = Color(0xFF8A93A5);

const Color kSettingsDivider = Color(0xFFF1F2F6);
const Color kSettingsChevron = Color(0xFFC2C8D4);
const Color kSettingsDanger = Color(0xFFF04A45);
const Color kSettingsDangerSoft = Color(0xFFFEF1F0);
const Color kSettingsSuccess = Color(0xFF2E9E55);
const Color kSettingsSuccessSoft = Color(0xFFEAF7EF);

/// AppBar 底部分隔线（白 AppBar 与浅灰页面之间的那条硬边界）。
const Color kSettingsAppBarDivider = Color(0xFFF0F1F4);

/// 填充式输入框（焦点输入）的静态描边 / 底色。
const Color kSettingsFieldBorder = Color(0xFFEEF0F5);
const Color kSettingsFieldBg = Color(0xFFF7F8FA);

/// 中性小徽标（未配置状态）的底色。
const Color kSettingsChipBg = Color(0xFFF1F3F7);

/// 开关关闭态轨道色。
const Color kSettingsSwitchInactive = Color(0xFFE3E6ED);

/// 页脚版本号等「整页最弱」信息的文字色。
const Color kSettingsFooterText = Color(0xFFB8BFCC);

// ─── 几何令牌 ───

const double kSettingsCardRadius = 16; // 卡片圆角
const double kSettingsCardMarginH = 16; // 卡片左右外边距（= ListView 左右 padding）
const double kSettingsCardPadH = 16; // 卡片内容左右内边距
const double kSettingsRowMinHeight = 52; // 普通行（文本 / 下拉 / 开关）最小高度
const double kSettingsRowPadV = 8; // 普通行上下内边距（有副标题的行自然变高）
const double kSettingsSectionGapTop = 26; // 分区标题距上一张卡
const double kSettingsSectionGapBot = 10; // 分区标题距本卡

/// 卡片投影：柔和、不带描边。offset 向下 2dp，避免卡片像「浮在页面上」。
const BoxShadow kSettingsCardShadow = BoxShadow(
  color: Color(0x0F101828),
  blurRadius: 12,
  offset: Offset(0, 2),
);

/// 行标签的字体样式：`SettingsLabel` 渲染与 `_measureLabelWidth` 测量共用，
/// 保证"量出来的宽度"和"画出来的宽度"一定是同一套字号/字重/行高。
const TextStyle kSettingsRowLabelStyle = TextStyle(
  fontSize: 13.5,
  fontWeight: FontWeight.w500,
  height: 1.25,
);

// ─── 内部工具 ───

/// 标签自然宽度的缓存。
///
/// 测量要新建 TextPainter 并 layout，是「一行」里最贵的一步；而同一组
/// （文案 / 字体样式 / 系统字号）在整页生命周期里会被反复测量：每次重建、
/// 每次 LayoutBuilder 布局都会走一遍。设置项的文案集合是固定的，缓存后
/// 只在首次出现时算一次，滚动 / 重建 / 转场时零开销。
///
/// key 用 (label, textScaler, style) 而不是只按文案：系统字号或主题字体变了，
/// 量出来的宽度也会变，必须重新测量。
final Map<({String label, TextScaler textScaler, TextStyle style}), double>
    _labelWidthCache =
    <({String label, TextScaler textScaler, TextStyle style}), double>{};

/// 用真实字体测量单行标签的自然宽度（含当前系统字号缩放）。
///
/// 为什么不按 textScale 阈值猜：真机系统 font_scale=1.15 时恰好卡在
/// 阈值边缘上（这之前真机就出现过 frequency_penalty 被截成
/// `frequency_penal…` 的事故）。TextPainter 用 DefaultTextStyle 合并
/// 标签样式，保证和真实渲染同一套字体 / fallback / 缩放，
/// 任何字体、任何系统字号下都不会截断。
double _measureLabelWidth(BuildContext context, String label) {
  final style = DefaultTextStyle.of(context).style.merge(kSettingsRowLabelStyle);
  final key = (
    label: label,
    textScaler: MediaQuery.textScalerOf(context),
    style: style,
  );
  final cached = _labelWidthCache[key];
  if (cached != null) return cached;

  final painter = TextPainter(
    text: TextSpan(
      text: label,
      // Text 渲染时会把自身 style 合并到 DefaultTextStyle 上，这里做同样的合并，
      // 才能拿到正确的字体族 / fontFamilyFallback（截图测试环境尤其重要）。
      style: style,
    ),
    textDirection: Directionality.of(context),
    textScaler: key.textScaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();

  // 设置项文案是固定的一小撮，超过上限只可能是字号 / 主题在变化，
  // 整体清空即可，避免缓存无界增长。
  if (_labelWidthCache.length >= 200) _labelWidthCache.clear();
  _labelWidthCache[key] = width;
  return width;
}

/// 是否把「左标签 + 右控件」改成两行堆叠。触发条件（任一）：
/// 1. 卡片内容宽 < 280dp（320dp 窄屏，横向两栏必然放不下）；
/// 2. 标签自然宽度超过横向布局里标签列能分到的宽度
///    （内容宽 - 12dp 间距后的 6/11，即文本行 flex 6:5 的标签列）。
bool _useStackedRow(BuildContext context, double contentWidth, String label) {
  if (contentWidth < 280) return true;
  final labelSlot = (contentWidth - 12) * 6 / 11;
  return _measureLabelWidth(context, label) > labelSlot;
}

/// 关闭当前弹窗：仅当该路由仍是栈顶时 pop，避免「确定」被快速连点两次时
/// 第二次 pop 把下层页面一起弹掉（并触发框架断言）。
/// 返回 true 表示本次调用实际执行了关闭。
bool _closeDialogSafely(BuildContext ctx, {Object? result}) {
  final route = ModalRoute.of(ctx);
  if (route == null || !route.isCurrent) return false;
  Navigator.of(ctx).pop(result);
  return true;
}

/// 延迟释放弹窗内的临时 controller：弹窗退场动画（约 150~250ms）结束后再
/// dispose，避免仍挂载的 TextField 使用已释放的 controller 引发框架异常。
void _scheduleControllerDispose(
  TextEditingController ctrl, {
  Duration delay = const Duration(milliseconds: 400),
}) {
  Future<void>.delayed(delay, ctrl.dispose);
}

/// 滑杆右侧数值的默认格式：整数步长显示整数，小数步长按需保留 1~2 位。
String _formatSliderValue(
  double value,
  double min,
  double max,
  int? divisions,
) {
  final step = divisions == null ? null : (max - min) / divisions;
  if (step != null && step >= 1) return value.round().toString();
  if (step != null && step >= 0.1) return value.toStringAsFixed(1);
  return value.toStringAsFixed(2);
}

// ─── 分区标题 ───

/// 分区标题：26dp 图标 chip + 标题 +（可选）副标题。
///
/// 标题放在卡片外面而不是卡片里：卡片负责「内容块」，标题负责「导航」。
/// 各功能页建议每个区块都带副标题，这样每个标题块高度一致，滚动节拍均匀。
class SettingsSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// 是否是页面第一组：首组上方不需要再留 26dp，让首屏多露一点内容。
  final bool isFirst;

  const SettingsSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        4,
        isFirst ? 14 : kSettingsSectionGapTop,
        4,
        kSettingsSectionGapBot,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: kSettingsPrimarySoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 15, color: kSettingsPrimary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: kSettingsTitle,
                    height: 1.25,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: kSettingsSubtitle,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 卡片 ───

/// 白色圆角卡片：白底 + 柔和投影（不描边），直接子项之间自动插 1px 分隔线。
///
/// 用 AnimatedSize 包住内容列，让条件行（例如搜索设置里的条件项）
/// 显示或隐藏时卡片高度平滑变化，而不是"跳一下"。
/// 内层 Material 只负责给 InkWell 提供水波纹载体（transparent 不遮挡白底）。
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSettingsCardBg,
        borderRadius: BorderRadius.circular(kSettingsCardRadius),
        boxShadow: const [kSettingsCardShadow],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: kSettingsDivider,
                    indent: kSettingsCardPadH,
                    endIndent: kSettingsCardPadH,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 标签 ───

/// 「左标签 + 右值」共用的标签部分（可选第二行 11sp 说明）。
///
/// 标签与值共享宽度、最多一行，长了就省略号——不给固定标签列，
/// 短标签不会在后面留一个巨洞。传了 [onTap] 时整块标签区域可点，
/// 通常用来聚焦同一行的输入框（输入框无边框、只有一条下划线，单点文字不好点中）。
class SettingsLabel extends StatelessWidget {
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  const SettingsLabel(this.label, {super.key, this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 与 _measureLabelWidth 共用同一份字体样式，测量/渲染不会漂移。
          style: kSettingsRowLabelStyle.copyWith(color: kSettingsLabel),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: kSettingsSubtitle,
              height: 1.25,
            ),
          ),
        ],
      ],
    );
    if (onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}

// ─── 行类型 ───

/// 文本 / 数字参数行：无框、右对齐输入，聚焦时才出现一条主色下划线。
///
/// 这是整个 kit 唯一的"裸输入"：不要再给每个参数包一个浅灰填充框，
/// 否则又会回到"灰框墙"。需要填充式输入的场景用 [SettingsPromptCard]。
class SettingsTextRow extends StatefulWidget {
  final String label;
  final String hint;
  final String initialValue;
  final ValueChanged<String> onChanged;

  /// 输入格式化器：用户输入后调用，返回与显示同步的值（如裁剪数字范围）
  final String? Function(String input)? formatter;

  /// 数值参数用数字键盘，文本 / JSON 参数用默认文本键盘。
  final TextInputType keyboardType;

  const SettingsTextRow({
    super.key,
    required this.label,
    required this.hint,
    required this.initialValue,
    required this.onChanged,
    this.formatter,
    this.keyboardType = TextInputType.text,
  });

  @override
  State<SettingsTextRow> createState() => _SettingsTextRowState();
}

class _SettingsTextRowState extends State<SettingsTextRow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    widget.onChanged(v);
    final formatted = widget.formatter?.call(v);
    if (formatted != null && formatted != v && _controller.text == v) {
      _controller.text = formatted;

      // 将光标移到末尾
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: formatted.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = _useStackedRow(
          context,
          constraints.maxWidth - 2 * kSettingsCardPadH,
          widget.label,
        );
        final label = SettingsLabel(
          widget.label,
          onTap: () => _focusNode.requestFocus(),
        );
        final field = TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          textAlign: TextAlign.right,
          textInputAction: TextInputAction.done,
          keyboardType: widget.keyboardType,
          cursorColor: kSettingsPrimary,
          style: const TextStyle(fontSize: 13.5, color: kSettingsValue),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            hintText: widget.hint,
            hintStyle: const TextStyle(fontSize: 12.5, color: kSettingsHint),
            // 平时完全透明，聚焦时只有底部一条主色线：
            // 输入框与只读值在视觉上是同一种文字，不再是两套控件。
            border: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.transparent, width: 1),
            ),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.transparent, width: 1),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: kSettingsPrimary, width: 1),
            ),
          ),
        );
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kSettingsRowMinHeight),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: kSettingsCardPadH,
              // 堆叠时标签和输入框分两行，上下留白要跟着多一点
              vertical: stacked ? 10 : kSettingsRowPadV,
            ),
            child: stacked
                // 窄屏 / 大字号：标签独占一行，输入框整行宽、内容仍右对齐。
                // 这样 frequency_penalty 这类长参数名永远不会被省略号截断。
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      label,
                      const SizedBox(height: 2),
                      field,
                    ],
                  )
                : Row(
                    children: [
                      // 左右都用 Expanded（Flexible 的紧约束版）：Flexible 的松约束下，
                      // 标签只占自然宽度、剩余空间会堆在行尾，值就跟着"贴不齐最右边"。
                      // Expanded 强制标签占满 6/11、值占满 5/11，右侧值的右边缘
                      // 才永远落在卡片 16dp 内边距这条线上。
                      // 标签给 6/11 而不是 5/11：真机 font_scale=1.15 时
                      // frequency_penalty 实测约 131dp，5/11（129dp）正好放不下。
                      Expanded(flex: 6, child: label),
                      const SizedBox(width: 12),
                      Expanded(flex: 5, child: field),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// 下拉框的一个选项。
///
/// [label] 是菜单里的完整文案，[shortLabel] 是收起状态显示在行尾的
/// 短文案——长文案在窄屏上会被截成「DeepSeek 官…」，
/// 所以收起态可以给一个更短的名字。
class SettingsSelectOption {
  final String value;
  final String label;
  final String? shortLabel;
  const SettingsSelectOption(this.value, this.label, {this.shortLabel});

  String get displayLabel => shortLabel ?? label;
}

/// 下拉行：整行可点，右侧是「当前值 + 小箭头」；点开是带勾的菜单。
///
/// 不用 DropdownButton 的原因：它的按钮高度跟随文字，想要整行热区得自己
/// 套 InkWell；PopupMenuButton 可以直接把整行当 child，热区天然对齐。
class SettingsSelectRow extends StatelessWidget {
  final String label;
  final String value;
  final List<SettingsSelectOption> options;
  final ValueChanged<String> onChanged;

  const SettingsSelectRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = options.firstWhere(
      (o) => o.value == value,
      orElse: () => options.first,
    );
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: Colors.white,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<String>(
            value: option.value,
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: option.value == value
                          ? kSettingsPrimary
                          : kSettingsLabel,
                      fontWeight: option.value == value
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (option.value == value)
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: kSettingsPrimary,
                  ),
              ],
            ),
          ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 下拉行保持 5:6；标签都很短，只有 320dp 窄屏才会触发堆叠。
          final stacked = _useStackedRow(
            context,
            constraints.maxWidth - 2 * kSettingsCardPadH,
            label,
          );
          final labelText = Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kSettingsRowLabelStyle.copyWith(color: kSettingsLabel),
          );
          // 「当前值 + 小箭头」：箭头永远贴最右，值右对齐在箭头左侧。
          final valueRow = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  current.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13.5, color: kSettingsValue),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: kSettingsChevron,
              ),
            ],
          );
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kSettingsRowMinHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: kSettingsCardPadH,
                // 堆叠时标签和值分两行，上下留白要跟着多一点
                vertical: stacked ? 10 : kSettingsRowPadV,
              ),
              child: stacked
                  // 窄屏 / 大字号：标签独占一行，值 + 箭头右对齐放下一行。
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        labelText,
                        const SizedBox(height: 2),
                        Align(
                          alignment: Alignment.centerRight,
                          child: valueRow,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        // 与 SettingsTextRow 同理：Expanded 才能把行尾剩余空间吃掉，
                        // 让下拉箭头（= 值的右边缘）压在同一条 16dp 线上。
                        // 下拉标签都很短，保持 5:6 给值留更宽的位置。
                        Expanded(flex: 5, child: labelText),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 6,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: valueRow,
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// 开关行：整行可点，开关贴卡片最右，视觉右边缘与文本值对齐。
///
/// Flutter M3 Switch 的布局是 52×40（52 宽轨道 + 40dp 最小点击区），
/// 比一行文字高 8dp。这里用 SizedBox(height: 32) 把布局高度压到文字行以内，
/// 行高才不会从 52 被撑到 60。
/// 宽度方向：Switch 左右各带 4dp 内边距（默认 padding），去掉后 52dp 的轨道
/// 正好填满 52dp 的布局盒；再做 0.9 缩放并以 centerRight 为锚点，
/// 缩放后的轨道右边缘仍然压在卡片 16dp 内边距线上。
class SettingsSwitchRow extends StatefulWidget {
  final String label;
  final String? subtitle;
  final bool initialValue;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.subtitle,
  });

  @override
  State<SettingsSwitchRow> createState() => _SettingsSwitchRowState();
}

class _SettingsSwitchRowState extends State<SettingsSwitchRow> {
  late bool _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  void _toggle() {
    setState(() => _value = !_value);
    widget.onChanged(_value);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _toggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kSettingsRowMinHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSettingsCardPadH,
            10,
            kSettingsCardPadH,
            10,
          ),
          child: Row(
            children: [
              Expanded(
                child: SettingsLabel(widget.label, subtitle: widget.subtitle),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 32,
                child: Transform.scale(
                  scale: 0.9,
                  alignment: Alignment.centerRight,
                  child: Switch(
                    value: _value,
                    onChanged: (_) => _toggle(),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeTrackColor: kSettingsPrimary,
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: kSettingsSwitchInactive,
                    inactiveThumbColor: Colors.white,
                    // M3 默认的开关描边在浅色卡片上显得很"重"，去掉后更干净。
                    trackOutlineColor:
                        const WidgetStatePropertyAll<Color?>(
                      Colors.transparent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 滑杆行（新）：上排「标签 + 右侧主色数值」，下排整行宽 Slider。
///
/// 用于 temperature / top_p / 上下文轮数这类"连续数值"参数：
/// 滑杆比输入框更直观，数值实时显示在右上角（主色，和选中值同一层级）。
/// [valueLabel] 可以自定义数值格式；不传时按步长自动取整或保留 1~2 位小数。
class SettingsSliderRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  /// 右上角数值的显示文案；不传则用默认格式（见 [_formatSliderValue]）。
  final String Function(double value)? valueLabel;

  const SettingsSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.subtitle,
    this.divisions,
    this.valueLabel,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max).toDouble();
    final valueText =
        valueLabel?.call(clamped) ??
        _formatSliderValue(clamped, min, max, divisions);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kSettingsCardPadH,
        _kSliderRowPadTop,
        kSettingsCardPadH,
        _kSliderRowPadBottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Row(
              children: [
                Expanded(child: SettingsLabel(label, subtitle: subtitle)),
                const SizedBox(width: 12),
                Text(
                  valueText,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: kSettingsPrimary,
                  ),
                ),
              ],
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: kSettingsPrimary,
              inactiveTrackColor: kSettingsSwitchInactive,
              thumbColor: kSettingsPrimary,
              overlayColor: kSettingsPrimary.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: clamped,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

const double _kSliderRowPadTop = 10;
const double _kSliderRowPadBottom = 2;

/// 动作行：图标 chip + 标题 + 说明 + 右箭头（导出 / 同步 / 跳转等）。
///
/// 危险动作用 [titleColor] 传红色（例如导入会覆盖数据），
/// 图标 chip 用 [softColor] 表达语义（主色底 / 危险色底），不要整行铺色。
class SettingsActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color softColor;
  final String title;
  final String subtitle;

  /// 危险动作用红色标题（导入会覆盖数据）。
  final Color? titleColor;
  final VoidCallback onTap;

  const SettingsActionRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.softColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSettingsCardPadH,
            12,
            kSettingsCardPadH,
            12,
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: softColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: titleColor ?? kSettingsLabel,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: kSettingsSubtitle,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: kSettingsChevron,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 焦点输入卡 ───

/// 提示词焦点卡（新）：功能页里的「大段文本」输入，一次解决三件事：
/// 1. 用填充式输入框 + 聚焦主色描边，和主设置页的 API Key 卡是同一套语言；
/// 2. 右上角可放状态 chip（例如「已启用 / 默认」），让"这段文案有没有配"
///    一眼可见；
/// 3. 底部左侧写一句辅助说明、右侧「放大编辑」把长文本丢进大弹窗
///    （配合 [showSettingsPromptDialog]），卡片本身只露出几行。
///
/// [controller] 由调用方持有并负责最终 dispose（本组件不接管生命周期），
/// 这样页面切换 / 保存时能直接拿到最新文本。
class SettingsPromptCard extends StatefulWidget {
  final String title;

  /// 图标 chip 的图标；默认是一页笔记（提示词 / 说明类文本）。
  final IconData icon;

  final TextEditingController controller;
  final String? hintText;

  /// 输入框最少 / 最多显示行数（超出后输入框内部滚动）。
  final int minLines;
  final int? maxLines;

  /// 右上角可选状态 chip（例如「已启用」）。传 null 不显示。
  final String? statusText;
  final Color? statusColor;
  final Color? statusBackground;

  /// 底部左侧辅助说明（11.5sp）；传 null 不显示。
  final String? footerHint;

  /// 底部右侧「放大编辑」回调；传 null 不显示该按钮。
  final VoidCallback? onExpand;
  final String expandLabel;

  final ValueChanged<String>? onChanged;

  const SettingsPromptCard({
    super.key,
    required this.title,
    required this.controller,
    this.icon = Icons.edit_note_rounded,
    this.hintText,
    this.minLines = 3,
    this.maxLines = 6,
    this.statusText,
    this.statusColor,
    this.statusBackground,
    this.footerHint,
    this.onExpand,
    this.expandLabel = '放大编辑',
    this.onChanged,
  });

  @override
  State<SettingsPromptCard> createState() => _SettingsPromptCardState();
}

class _SettingsPromptCardState extends State<SettingsPromptCard> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(kSettingsCardPadH),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: kSettingsPrimarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(widget.icon, size: 17, color: kSettingsPrimary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: kSettingsTitle,
                  ),
                ),
              ),
              if (widget.statusText != null)
                _SettingsStatusChip(
                  text: widget.statusText!,
                  color: widget.statusColor ?? kSettingsSuccess,
                  background: widget.statusBackground ?? kSettingsSuccessSoft,
                ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: kSettingsFieldBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? kSettingsPrimary : kSettingsFieldBorder,
                width: _focused ? 1.2 : 1,
              ),
            ),
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              cursorColor: kSettingsPrimary,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: kSettingsValue,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: const TextStyle(
                  fontSize: 12.5,
                  color: kSettingsHint,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (widget.footerHint != null || widget.onExpand != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: widget.footerHint == null
                      ? const SizedBox.shrink()
                      : Text(
                          widget.footerHint!,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: kSettingsSubtitle,
                            height: 1.3,
                          ),
                        ),
                ),
                if (widget.onExpand != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: widget.onExpand,
                    style: TextButton.styleFrom(
                      foregroundColor: kSettingsPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_in_full_rounded, size: 15),
                        const SizedBox(width: 4),
                        Text(
                          widget.expandLabel,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 小状态徽标：圆点 + 文字。用于「已启用 / 未配置」这类二态提示。
class _SettingsStatusChip extends StatelessWidget {
  final String text;
  final Color color;
  final Color background;

  const _SettingsStatusChip({
    required this.text,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 白卡内的说明文字（新）：12.5sp 次要文字、行高 1.5，卡片外观与
/// [SettingsCard] 完全一致。
///
/// 适用于"这一组设置是干什么的"这类一整段解释——比塞进区块副标题
/// 更能放长句，又不会破坏「标题在卡外」的层级。
class SettingsNote extends StatelessWidget {
  final String text;

  const SettingsNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSettingsCardPadH,
            12,
            kSettingsCardPadH,
            12,
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              color: kSettingsSubtitle,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── AppBar / 保存按钮 ───

/// 主色胶囊保存按钮（AppBar 右侧）。
///
/// 字号 / 字重放在 Text 上而不是 TextButton.styleFrom 的 textStyle 里：
/// 后者会整体替换按钮默认的 labelLarge 样式（连字体族一起丢掉），
/// 在不同字体环境下文字容易渲染成豆腐块。
class SettingsSaveButton extends StatelessWidget {
  final VoidCallback? onPressed;

  /// 是否可点；false 时按钮变灰（例如没有改动时）。
  final bool enabled;
  final String label;

  const SettingsSaveButton({
    super.key,
    required this.onPressed,
    this.enabled = true,
    this.label = '保存',
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TextButton(
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          backgroundColor: kSettingsPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: kSettingsSwitchInactive,
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const StadiumBorder(),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 功能页统一 AppBar：白底、无阴影、1px 底边、居中标题、返回箭头、
/// 右侧可选保存胶囊（通过 [onSave]）。
///
/// 其他页面需要额外动作时可用 [actions] 完全接管右侧区域
/// （此时忽略 [onSave]/[saveEnabled]/[saveLabel]）。
class SettingsAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;

  /// 右侧保存按钮的回调；传 null 表示本页没有保存动作。
  final VoidCallback? onSave;
  final bool saveEnabled;
  final String saveLabel;

  /// 完全自定义右侧动作（会替代默认的保存胶囊）。
  final List<Widget>? actions;

  /// 返回按钮回调；不传则默认 `Navigator.pop`。
  final VoidCallback? onBack;

  const SettingsAppBar({
    super.key,
    required this.title,
    this.onSave,
    this.saveEnabled = true,
    this.saveLabel = '保存',
    this.actions,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 1);

  @override
  Widget build(BuildContext context) {
    final actionWidgets = actions ??
        <Widget>[
          if (onSave != null)
            SettingsSaveButton(
              onPressed: onSave,
              enabled: saveEnabled,
              label: saveLabel,
            ),
        ];
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 22, color: kSettingsTitle),
        tooltip: '返回',
        onPressed: onBack ?? () => Navigator.of(context).pop(),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: kSettingsTitle,
        ),
      ),
      actions: actionWidgets.isEmpty
          ? null
          : [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: actionWidgets.length == 1
                      ? actionWidgets.single
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: actionWidgets,
                        ),
                ),
              ),
            ],
      // 1px 底部分隔线：白色 AppBar 与浅灰页面之间需要一条硬边界，
      // 但不要阴影（阴影会让头部看起来是悬浮的）。
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(
          height: 1,
          thickness: 1,
          color: kSettingsAppBarDivider,
        ),
      ),
    );
  }
}

// ─── 大编辑弹窗 ───

/// v2 风格的大段文本编辑弹窗：白底 20 圆角、标题 16sp w600、
/// 填充式多行输入、底部「取消」文字按钮 +「确定」主色胶囊。
///
/// 语义（与功能页原有的弹窗工具保持一致，但 kit 保持自包含、不 import
/// features，避免 core 反向依赖业务层）：
/// - 打开时拷贝 [controller] 的当前文本到弹窗内的临时 controller，
///   取消 / 点遮罩关闭不改动原 controller；
/// - 点「确定」才把文本写回 [controller]；
/// - 弹窗内的临时 controller 等退场动画结束后再释放，避免框架异常；
/// - 按钮用"仍是栈顶才 pop"的判定，快速连点不会把下层页面一起弹掉。
///
/// 典型用法：配合 [SettingsPromptCard] 的「放大编辑」按钮。
Future<void> showSettingsPromptDialog(
  BuildContext context, {
  required String title,
  required TextEditingController controller,
  String? hint,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  int minLines = 8,
  int maxLines = 12,
}) async {
  final editController = TextEditingController(text: controller.text);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: kSettingsTitle,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: editController,
                autofocus: true,
                minLines: minLines,
                maxLines: maxLines,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: kSettingsPrimary,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: kSettingsValue,
                ),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    fontSize: 12.5,
                    color: kSettingsHint,
                  ),
                  filled: true,
                  fillColor: kSettingsFieldBg,
                  isDense: true,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kSettingsFieldBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kSettingsFieldBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: kSettingsPrimary,
                      width: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _closeDialogSafely(dialogContext),
                    style: TextButton.styleFrom(
                      foregroundColor: kSettingsValue,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      cancelLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SettingsSaveButton(
                    onPressed: () => _closeDialogSafely(
                      dialogContext,
                      result: editController.text,
                    ),
                    label: confirmLabel,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  // 取消 / 点遮罩关闭时 result 为 null，原 controller 保持不动。
  if (result != null && context.mounted) {
    controller.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }
  _scheduleControllerDispose(editController);
}
