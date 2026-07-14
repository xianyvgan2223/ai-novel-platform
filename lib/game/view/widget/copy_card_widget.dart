import 'package:flutter/material.dart';
import 'package:deepseekapp/game/model/entity/copy_entity.dart';
import 'package:deepseekapp/game/model/entity/character_entity.dart';

class CopyCardWidget extends StatelessWidget {
  final CopyEntity copy;
  final List<CharacterEntity> characters;
  final VoidCallback? onStart;
  final VoidCallback? onSetting;
  final ValueChanged<int>? onCharacterTap;
  final ValueChanged<int>? onCharacterDropped;

  const CopyCardWidget({
    super.key,
    required this.copy,
    required this.characters,
    this.onStart,
    this.onSetting,
    this.onCharacterTap,
    this.onCharacterDropped,
  });

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Map<String, String> _parseModelConfig(String? json) {
    if (json == null || json.isEmpty) return {};
    try {
      final map = <String, String>{};
      final cleaned = json.trim();
      if (cleaned.startsWith('{') && cleaned.endsWith('}')) {
        final inner = cleaned.substring(1, cleaned.length - 1);
        final parts = _splitJsonParts(inner);
        for (final part in parts) {
          final colonIdx = part.indexOf(':');
          if (colonIdx > 0) {
            final key = part.substring(0, colonIdx).trim().replaceAll('"', '');
            final value = part
                .substring(colonIdx + 1)
                .trim()
                .replaceAll('"', '');
            if (key.isNotEmpty) map[key] = value;
          }
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  List<String> _splitJsonParts(String s) {
    final parts = <String>[];
    int depth = 0;
    int start = 0;
    for (int i = 0; i < s.length; i++) {
      if (s[i] == '{') depth++;
      if (s[i] == '}') depth--;
      if (s[i] == ',' && depth == 0) {
        parts.add(s.substring(start, i));
        start = i + 1;
      }
    }
    if (start < s.length) parts.add(s.substring(start));
    return parts;
  }

  @override
  Widget build(BuildContext context) {
    final config = _parseModelConfig(copy.modelConfig);
    final background = config['background'];
    final style = config['style'];

    final content = Card(
      color: Colors.white,
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    copy.copyName,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
                if (copy.isRunning == 1)
                  const Padding(
                    padding: EdgeInsets.only(right: 3),
                    child: SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(strokeWidth: 1.2),
                    ),
                  ),
                if (onSetting != null)
                  GestureDetector(
                    onTap: onSetting,
                    child: const Icon(
                      Icons.settings,
                      size: 12,
                      color: Color(0xFF999999),
                    ),
                  ),
              ],
            ),
            if (background != null && background.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  background,
                  style: const TextStyle(fontSize: 8, color: Color(0xFF888888)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (style != null && style.isNotEmpty && style != '默认')
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  style,
                  style: const TextStyle(fontSize: 8, color: Color(0xFF888888)),
                ),
              ),
            const SizedBox(height: 3),
            Text(
              _formatTime(copy.createTime),
              style: const TextStyle(fontSize: 8, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 4),
            if (characters.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '拖拽人物到此',
                  style: TextStyle(color: Color(0xFFCCCCCC), fontSize: 9),
                ),
              )
            else
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: characters
                    .map(
                      (char) => GestureDetector(
                        onTap: () => onCharacterTap?.call(char.id ?? 0),
                        child: CircleAvatar(
                          radius: 10,
                          backgroundColor: const Color(0xFFE8E8E8),
                          child: Text(
                            char.charName.isNotEmpty ? char.charName[0] : '?',
                            style: const TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF666666),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 22,
              child: ElevatedButton(
                onPressed: copy.isRunning == 1 ? null : onStart,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A90D9),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFCCCCCC),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                child: Text(
                  copy.isRunning == 1 ? '运行中...' : '开始',
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return DragTarget<int>(
      onAcceptWithDetails: (details) {
        onCharacterDropped?.call(details.data);
      },
      onWillAcceptWithDetails: (details) => true,
      builder: (context, candidateData, rejectedData) {
        return Stack(
          children: [
            Opacity(
              opacity: candidateData.isNotEmpty ? 0.8 : 1.0,
              child: content,
            ),
            if (copy.isRunning == 1)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
