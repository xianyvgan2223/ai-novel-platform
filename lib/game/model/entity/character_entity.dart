class CharacterEntity {
  int? id;
  String charName;
  String? baseDesc;
  int createTime;

  CharacterEntity({
    this.id,
    required this.charName,
    this.baseDesc,
    int? createTime,
  }) : createTime = createTime ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'char_name': charName,
    'base_desc': baseDesc,
    'create_time': createTime,
  };

  factory CharacterEntity.fromMap(Map<String, dynamic> map) => CharacterEntity(
    id: map['id'] as int?,
    charName: map['char_name'] as String,
    baseDesc: map['base_desc'] as String?,
    createTime: map['create_time'] as int,
  );

  CharacterEntity copyWith({
    int? id,
    String? charName,
    String? baseDesc,
    int? createTime,
  }) => CharacterEntity(
    id: id ?? this.id,
    charName: charName ?? this.charName,
    baseDesc: baseDesc ?? this.baseDesc,
    createTime: createTime ?? this.createTime,
  );
}
