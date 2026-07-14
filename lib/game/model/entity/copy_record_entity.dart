class CopyRecordEntity {
  int? id;
  int copyId;
  String? totalStory;
  int createTime;

  CopyRecordEntity({
    this.id,
    required this.copyId,
    this.totalStory,
    int? createTime,
  }) : createTime = createTime ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'copy_id': copyId,
    'total_story': totalStory,
    'create_time': createTime,
  };

  factory CopyRecordEntity.fromMap(Map<String, dynamic> map) =>
      CopyRecordEntity(
        id: map['id'] as int?,
        copyId: map['copy_id'] as int,
        totalStory: map['total_story'] as String?,
        createTime: map['create_time'] as int,
      );

  CopyRecordEntity copyWith({
    int? id,
    int? copyId,
    String? totalStory,
    int? createTime,
  }) => CopyRecordEntity(
    id: id ?? this.id,
    copyId: copyId ?? this.copyId,
    totalStory: totalStory ?? this.totalStory,
    createTime: createTime ?? this.createTime,
  );
}
