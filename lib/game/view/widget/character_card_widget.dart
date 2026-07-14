import 'package:flutter/material.dart';
import 'package:deepseekapp/game/model/entity/character_entity.dart';
import 'package:deepseekapp/game/view/page/character_edit_page.dart';

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
    final card = Opacity(
      opacity: isDragging ? 0.5 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          color: Colors.white,
          elevation: 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 8,
                  backgroundColor: const Color(0xFFE8E8E8),
                  child: Text(
                    character.charName.isNotEmpty ? character.charName[0] : '?',
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF666666),
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
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF333333),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((character.baseDesc ?? '').isNotEmpty)
                        Text(
                          character.baseDesc!,
                          style: const TextStyle(
                            fontSize: 7,
                            color: Color(0xFF999999),
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
                      color: const Color(0xFF4A90D9).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Icon(
                      Icons.chevron_right,
                      size: 12,
                      color: Color(0xFF4A90D9),
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
        child: SizedBox(
          width: 60,
          child: Card(
            color: Colors.white,
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
