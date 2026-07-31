class EquipmentEntity {
  int? id;
  int charId;
  String equipName;
  String? equipAttr;
  int? sourceCopyId;

  EquipmentEntity({
    this.id,
    required this.charId,
    required this.equipName,
    this.equipAttr,
    this.sourceCopyId,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'char_id': charId,
    'equip_name': equipName,
    'equip_attr': equipAttr,
    'source_copy_id': sourceCopyId,
  };

  factory EquipmentEntity.fromMap(Map<String, dynamic> map) => EquipmentEntity(
    id: map['id'] as int?,
    charId: map['char_id'] as int,
    equipName: map['equip_name'] as String,
    equipAttr: map['equip_attr'] as String?,
    sourceCopyId: map['source_copy_id'] as int?,
  );

  EquipmentEntity copyWith({
    int? id,
    int? charId,
    String? equipName,
    String? equipAttr,
    int? sourceCopyId,
  }) => EquipmentEntity(
    id: id ?? this.id,
    charId: charId ?? this.charId,
    equipName: equipName ?? this.equipName,
    equipAttr: equipAttr ?? this.equipAttr,
    sourceCopyId: sourceCopyId ?? this.sourceCopyId,
  );
}
