// lib/core/theme/theme_mode_controller.dart
// 夜间模式的选择：跟随系统 / 浅色 / 深色。
// 偏好只存在本机（sync_kv），不参与数据同步。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_preferences.dart';

class ThemeModeController extends ChangeNotifier {
  ThemeModeController({String? initialRaw}) {
    _mode = parse(initialRaw);
    _loaded = true;
  }

  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  /// 首次启动时从本地读一次；读不到就用「跟随系统」。
  Future<void> load() async {
    try {
      final raw = await AppPreferences.get(AppPreferences.themeModeKey);
      _mode = parse(raw);
    } catch (_) {
      _mode = ThemeMode.system;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await AppPreferences.set(
        AppPreferences.themeModeKey,
        encode(mode),
      );
    } catch (_) {
      // 本机存储不可用时，本次运行仍然生效
    }
  }

  static ThemeMode parse(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static String label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }
}

final themeModeProvider = ChangeNotifierProvider<ThemeModeController>(
  (ref) => ThemeModeController()..load(),
);
