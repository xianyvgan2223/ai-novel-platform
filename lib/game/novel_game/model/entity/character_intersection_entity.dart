class CharacterIntersectionEntity {
  int? id;
  int charAId;
  int charBId;
  String intersectionDesc;
  int updateTime;

  CharacterIntersectionEntity({
    this.id,
    required this.charAId,
    required this.charBId,
    required this.intersectionDesc,
    int? updateTime,
  }) : updateTime = updateTime ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'char_a_id': charAId,
    'char_b_id': charBId,
    'intersection_desc': intersectionDesc,
    'update_time': updateTime,
  };

  factory CharacterIntersectionEntity.fromMap(Map<String, dynamic> map) =>
      CharacterIntersectionEntity(
        id: map['id'] as int?,
        charAId: map['char_a_id'] as int,
        charBId: map['char_b_id'] as int,
        intersectionDesc: map['intersection_desc'] as String,
        updateTime: map['update_time'] as int,
      );

  CharacterIntersectionEntity copyWith({
    int? id,
    int? charAId,
    int? charBId,
    String? intersectionDesc,
    int? updateTime,
  }) => CharacterIntersectionEntity(
    id: id ?? this.id,
    charAId: charAId ?? this.charAId,
    charBId: charBId ?? this.charBId,
    intersectionDesc: intersectionDesc ?? this.intersectionDesc,
    updateTime: updateTime ?? this.updateTime,
  );
}
