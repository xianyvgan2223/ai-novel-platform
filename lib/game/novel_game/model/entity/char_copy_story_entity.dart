class CharCopyStoryEntity {
  int? id;
  int copyId;
  int charId;
  String? singleStory;

  CharCopyStoryEntity({
    this.id,
    required this.copyId,
    required this.charId,
    this.singleStory,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'copy_id': copyId,
    'char_id': charId,
    'single_story': singleStory,
  };

  factory CharCopyStoryEntity.fromMap(Map<String, dynamic> map) =>
      CharCopyStoryEntity(
        id: map['id'] as int?,
        copyId: map['copy_id'] as int,
        charId: map['char_id'] as int,
        singleStory: map['single_story'] as String?,
      );

  CharCopyStoryEntity copyWith({
    int? id,
    int? copyId,
    int? charId,
    String? singleStory,
  }) => CharCopyStoryEntity(
    id: id ?? this.id,
    copyId: copyId ?? this.copyId,
    charId: charId ?? this.charId,
    singleStory: singleStory ?? this.singleStory,
  );
}
