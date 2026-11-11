// 小说灵感 / 灵感导入事件选择器共用的黑白配色。
//
// 只改传给页面的 AppPalette，不动全局主题，也不影响其它功能（例如大纲编辑）。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

AppPalette monochromePalette(AppPalette base) {
  if (base.isDark) {
    return base.copyWith(
      background: const Color(0xFF0A0A0A),
      surface: const Color(0xFF141414),
      surfaceElevated: const Color(0xFF1C1C1C),
      surfaceMuted: const Color(0xFF101010),
      border: const Color(0xFF262626),
      borderStrong: const Color(0xFF3A3A3A),
      accent: const Color(0xFFF5F5F5),
      accentSoft: const Color(0xFF222222),
      onAccent: const Color(0xFF0A0A0A),
      bubbleUser: const Color(0xFFF5F5F5),
      bubbleUserText: const Color(0xFF0A0A0A),
      bubbleAssistant: const Color(0xFF141414),
      bubbleAssistantText: const Color(0xFFEDEDED),
      textPrimary: const Color(0xFFF5F5F5),
      textSecondary: const Color(0xFFA3A3A3),
      textTertiary: const Color(0xFF737373),
      danger: const Color(0xFFE5E5E5),
      dangerSoft: const Color(0xFF1C1C1C),
    );
  }
  return base.copyWith(
    background: const Color(0xFFF6F6F6),
    surface: const Color(0xFFFFFFFF),
    surfaceElevated: const Color(0xFFFFFFFF),
    surfaceMuted: const Color(0xFFF0F0F0),
    border: const Color(0xFFEAEAEA),
    borderStrong: const Color(0xFFD6D6D6),
    accent: const Color(0xFF111111),
    accentSoft: const Color(0xFFEFEFEF),
    onAccent: const Color(0xFFFFFFFF),
    bubbleUser: const Color(0xFF111111),
    bubbleUserText: const Color(0xFFFFFFFF),
    bubbleAssistant: const Color(0xFFFFFFFF),
    bubbleAssistantText: const Color(0xFF111111),
    textPrimary: const Color(0xFF111111),
    textSecondary: const Color(0xFF555555),
    textTertiary: const Color(0xFF999999),
    danger: const Color(0xFF111111),
    dangerSoft: const Color(0xFFF0F0F0),
  );
}
