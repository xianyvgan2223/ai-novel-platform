import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

class AiLoadingWidget extends StatelessWidget {
  final String? message;

  const AiLoadingWidget({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final foreground = p.isDark ? p.textPrimary : Colors.white;
    return Container(
      color: p.isDark ? p.surfaceElevated : Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: foreground,
            ),
          ),
          if (message != null) ...[
            const SizedBox(width: 8),
            Text(
              message!,
              style: TextStyle(color: foreground, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
