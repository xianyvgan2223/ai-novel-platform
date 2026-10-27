// lib/core/theme/app_theme.dart
// 亮色 / 夜间两套 ThemeData。夜间不是简单反色，而是一套独立的低对比色板：
// 近黑页面底 + 一档更亮的卡片 + 发丝边框 + 降饱和的强调色。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';

class AppTheme {
  const AppTheme._();

  static const Color seed = Color(0xFF4D6BFE);

  static ThemeData light() => _build(AppPalette.light);

  static ThemeData dark() => _build(AppPalette.dark);

  static ThemeData _build(AppPalette p) {
    final brightness = p.isDark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.accentSoft,
      onPrimaryContainer: p.textPrimary,
      secondary: p.textSecondary,
      onSecondary: p.surface,
      surface: p.surface,
      onSurface: p.textPrimary,
      surfaceContainerHighest: p.surfaceElevated,
      outline: p.borderStrong,
      error: p.danger,
      onError: p.onAccent,
    );

    final baseOverlay = p.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      cardColor: p.surface,
      dividerColor: p.border,
      extensions: <ThemeExtension<dynamic>>[p],
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: baseOverlay.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: p.background,
          systemNavigationBarIconBrightness: p.isDark
              ? Brightness.light
              : Brightness.dark,
        ),
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: p.textPrimary),
      ),
      iconTheme: IconThemeData(color: p.textSecondary),
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: p.isDark ? 0 : 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: p.isDark ? p.border : Colors.transparent,
          ),
        ),
        textStyle: TextStyle(color: p.textPrimary, fontSize: 13.5),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surfaceElevated,
        modalBackgroundColor: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: p.overlay,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceElevated,
        contentTextStyle: TextStyle(color: p.textPrimary),
        actionTextColor: p.accent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: p.surfaceMuted,
        hintStyle: TextStyle(color: p.textTertiary),
        labelStyle: TextStyle(color: p.textSecondary),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: 0.24),
        selectionHandleColor: p.accent,
      ),
      textTheme: ThemeData(
        brightness: brightness,
      ).textTheme.apply(bodyColor: p.textPrimary, displayColor: p.textPrimary),
    );
  }
}
