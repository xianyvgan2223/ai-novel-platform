import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

class RedDotBadgeWidget extends StatelessWidget {
  final Widget child;
  final int count;

  const RedDotBadgeWidget({
    super.key,
    required this.child,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (count > 0)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: p.danger,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              child: Text(
                count > 99 ? '99+' : '$count',
                style: TextStyle(
                  color: p.onAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
