// 小说灵感专属配色：黑白极简，只用灰阶区分层级，不使用彩色强调。
// 只包在本功能的子树里，不影响 App 其它页面。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../shared/monochrome_palette.dart';

AppPalette inspirationPalette(AppPalette base) => monochromePalette(base);

/// 把当前子树包成黑白配色；页面内部照常使用 `context.palette`。
class InspirationTheme extends StatelessWidget {
  const InspirationTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final palette = inspirationPalette(context.palette);
    return Theme(
      data: base.copyWith(
        extensions: <ThemeExtension<dynamic>>[palette],
        scaffoldBackgroundColor: palette.background,
        appBarTheme: AppBarTheme(
          backgroundColor: palette.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: palette.textPrimary),
          titleTextStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: palette.textPrimary,
          ),
        ),
      ),
      child: child,
    );
  }
}
