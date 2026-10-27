// lib/core/theme/app_palette.dart
// 全 App 的语义色板：页面 / 卡片 / 文字 / 边框 / 强调色 / 聊天气泡。
//
// 设计原则（夜间模式）：
// - 不用纯黑、纯白，避免 OLED 上的「硬边」和刺眼对比；
// - 背景、卡片、输入框只差一档亮度，靠 1px 发丝边框分层，而不是重投影；
// - 强调色在深色下降饱和、提亮，保持克制；
// - 所有页面都通过 context.palette 取色，不再直接写死浅色值。

import 'package:flutter/material.dart';

@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceMuted,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.danger,
    required this.dangerSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.shadow,
    required this.overlay,
    required this.switchInactive,
    required this.bubbleUser,
    required this.bubbleUserText,
    required this.bubbleAssistant,
    required this.bubbleAssistantText,
    required this.isDark,
  });

  /// 页面底色（Scaffold / 列表底）。
  final Color background;

  /// 卡片 / 面板底色。
  final Color surface;

  /// 弹窗 / 菜单 / BottomSheet 等浮层底色。
  final Color surfaceElevated;

  /// 输入框填充、chip、次级块。
  final Color surfaceMuted;

  /// 分隔线 / 发丝边框。
  final Color border;

  /// 更强的边框（输入框聚焦前的描边、选中态）。
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 全 App 唯一强调色。
  final Color accent;

  /// 强调色的浅底（图标 chip / 提示卡）。
  final Color accentSoft;

  /// 强调色上的文字 / 图标。
  final Color onAccent;

  final Color danger;
  final Color dangerSoft;
  final Color success;
  final Color successSoft;
  final Color warning;

  /// 卡片投影；深色下接近透明，主要靠边框分层。
  final Color shadow;

  /// 弹窗遮罩。
  final Color overlay;

  /// 关闭态开关轨道。
  final Color switchInactive;

  final Color bubbleUser;
  final Color bubbleUserText;
  final Color bubbleAssistant;
  final Color bubbleAssistantText;

  final bool isDark;

  static const AppPalette light = AppPalette(
    background: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF7F8FA),
    border: Color(0xFFF1F2F6),
    borderStrong: Color(0xFFE3E6ED),
    textPrimary: Color(0xFF14161A),
    textSecondary: Color(0xFF5A6474),
    textTertiary: Color(0xFF8A93A5),
    accent: Color(0xFF4D6BFE),
    accentSoft: Color(0xFFEEF2FF),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFF04A45),
    dangerSoft: Color(0xFFFEF1F0),
    success: Color(0xFF2E9E55),
    successSoft: Color(0xFFEAF7EF),
    warning: Color(0xFFE0A21A),
    shadow: Color(0x0F101828),
    overlay: Color(0x66000000),
    switchInactive: Color(0xFFE3E6ED),
    bubbleUser: Color(0xFF4D6BFE),
    bubbleUserText: Color(0xFFFFFFFF),
    bubbleAssistant: Color(0xFFFFFFFF),
    bubbleAssistantText: Color(0xFF14161A),
    isDark: false,
  );

  static const AppPalette dark = AppPalette(
    background: Color(0xFF0E1014),
    surface: Color(0xFF15181E),
    surfaceElevated: Color(0xFF1B1F27),
    surfaceMuted: Color(0xFF111419),
    border: Color(0xFF242932),
    borderStrong: Color(0xFF303642),
    textPrimary: Color(0xFFF1F3F7),
    textSecondary: Color(0xFFA6AEBB),
    textTertiary: Color(0xFF737B89),
    accent: Color(0xFF8EA1FF),
    accentSoft: Color(0xFF1A2236),
    onAccent: Color(0xFF0B0E14),
    danger: Color(0xFFFF6B66),
    dangerSoft: Color(0xFF2A1A1B),
    success: Color(0xFF4ED08A),
    successSoft: Color(0xFF14251C),
    warning: Color(0xFFE5B45A),
    shadow: Color(0x66000000),
    overlay: Color(0x99000000),
    switchInactive: Color(0xFF2A303A),
    bubbleUser: Color(0xFF26324E),
    bubbleUserText: Color(0xFFE7ECFF),
    bubbleAssistant: Color(0xFF15181E),
    bubbleAssistantText: Color(0xFFE6E9EF),
    isDark: true,
  );

  @override
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceMuted,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentSoft,
    Color? onAccent,
    Color? danger,
    Color? dangerSoft,
    Color? success,
    Color? successSoft,
    Color? warning,
    Color? shadow,
    Color? overlay,
    Color? switchInactive,
    Color? bubbleUser,
    Color? bubbleUserText,
    Color? bubbleAssistant,
    Color? bubbleAssistantText,
    bool? isDark,
  }) {
    return AppPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      success: success ?? this.success,
      successSoft: successSoft ?? this.successSoft,
      warning: warning ?? this.warning,
      shadow: shadow ?? this.shadow,
      overlay: overlay ?? this.overlay,
      switchInactive: switchInactive ?? this.switchInactive,
      bubbleUser: bubbleUser ?? this.bubbleUser,
      bubbleUserText: bubbleUserText ?? this.bubbleUserText,
      bubbleAssistant: bubbleAssistant ?? this.bubbleAssistant,
      bubbleAssistantText: bubbleAssistantText ?? this.bubbleAssistantText,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    return AppPalette(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceElevated: mix(surfaceElevated, other.surfaceElevated),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      danger: mix(danger, other.danger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      success: mix(success, other.success),
      successSoft: mix(successSoft, other.successSoft),
      warning: mix(warning, other.warning),
      shadow: mix(shadow, other.shadow),
      overlay: mix(overlay, other.overlay),
      switchInactive: mix(switchInactive, other.switchInactive),
      bubbleUser: mix(bubbleUser, other.bubbleUser),
      bubbleUserText: mix(bubbleUserText, other.bubbleUserText),
      bubbleAssistant: mix(bubbleAssistant, other.bubbleAssistant),
      bubbleAssistantText: mix(
        bubbleAssistantText,
        other.bubbleAssistantText,
      ),
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}
