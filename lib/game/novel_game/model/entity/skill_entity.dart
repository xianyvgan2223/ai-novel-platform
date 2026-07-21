class SkillEntity {
  int? id;
  int charId;
  String skillName;
  String? skillDesc;
  int? sourceCopyId;

  SkillEntity({
    this.id,
    required this.charId,
    required this.skillName,
    this.skillDesc,
    this.sourceCopyId,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'char_id': charId,
    'skill_name': skillName,
    'skill_desc': skillDesc,
    'source_copy_id': sourceCopyId,
  };

  factory SkillEntity.fromMap(Map<String, dynamic> map) => SkillEntity(
    id: map['id'] as int?,
    charId: map['char_id'] as int,
    skillName: map['skill_name'] as String,
    skillDesc: map['skill_desc'] as String?,
    sourceCopyId: map['source_copy_id'] as int?,
  );

  SkillEntity copyWith({
    int? id,
    int? charId,
    String? skillName,
    String? skillDesc,
    int? sourceCopyId,
  }) => SkillEntity(
    id: id ?? this.id,
    charId: charId ?? this.charId,
    skillName: skillName ?? this.skillName,
    skillDesc: skillDesc ?? this.skillDesc,
    sourceCopyId: sourceCopyId ?? this.sourceCopyId,
  );
}
