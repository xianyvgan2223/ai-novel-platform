class CopyEntity {
  int? id;
  String copyName;
  String? modelConfig; // JSON string of model config
  int createTime;
  int isRunning; // 0/1
  int unreadRecord; // 0/1

  CopyEntity({
    this.id,
    required this.copyName,
    this.modelConfig,
    int? createTime,
    this.isRunning = 0,
    this.unreadRecord = 0,
  }) : createTime = createTime ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'copy_name': copyName,
    'model_config': modelConfig,
    'create_time': createTime,
    'is_running': isRunning,
    'unread_record': unreadRecord,
  };

  factory CopyEntity.fromMap(Map<String, dynamic> map) => CopyEntity(
    id: map['id'] as int?,
    copyName: map['copy_name'] as String,
    modelConfig: map['model_config'] as String?,
    createTime: map['create_time'] as int,
    isRunning: map['is_running'] as int? ?? 0,
    unreadRecord: map['unread_record'] as int? ?? 0,
  );

  CopyEntity copyWith({
    int? id,
    String? copyName,
    String? modelConfig,
    int? createTime,
    int? isRunning,
    int? unreadRecord,
  }) => CopyEntity(
    id: id ?? this.id,
    copyName: copyName ?? this.copyName,
    modelConfig: modelConfig ?? this.modelConfig,
    createTime: createTime ?? this.createTime,
    isRunning: isRunning ?? this.isRunning,
    unreadRecord: unreadRecord ?? this.unreadRecord,
  );
}
