import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/view/page/character_edit_page.dart';

class CharacterCardWidget extends StatelessWidget {
  final CharacterEntity character;
  final VoidCallback? onTap;
  final bool isDragging;

  const CharacterCardWidget({
    super.key,
    required this.character,
    this.onTap,
    this.isDragging = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final card = Opacity(
      opacity: isDragging ? 0.5 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          color: p.surface,
          elevation: p.isDark ? 0 : 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
              color: p.isDark ? p.border : Colors.transparent,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 8,
                  backgroundColor: p.surfaceMuted,
                  child: Text(
                    character.charName.isNotEmpty ? character.charName[0] : '?',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        character.charName,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: p.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((character.baseDesc ?? '').isNotEmpty)
                        Text(
                          character.baseDesc!,
                          style: TextStyle(
                            fontSize: 7,
                            color: p.textTertiary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CharacterEditPage(character: character),
                      ),
                    );
                  },
                  child: Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Icon(
                      Icons.chevron_right,
                      size: 12,
                      color: p.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Draggable<int>(
      data: character.id ?? 0,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(4),
        color: p.surfaceElevated,
        child: SizedBox(
          width: 60,
          child: Card(
            color: p.surfaceElevated,
            elevation: 4,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                character.charName,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }
}
