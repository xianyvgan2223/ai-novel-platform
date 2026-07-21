import 'package:flutter/material.dart';

class AiLoadingWidget extends StatelessWidget {
  final String? message;

  const AiLoadingWidget({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.white,
            ),
          ),
          if (message != null) ...[
            const SizedBox(width: 8),
            Text(
              message!,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
