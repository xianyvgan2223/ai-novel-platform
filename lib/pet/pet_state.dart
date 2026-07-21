/// 宠物状态标签枚举
enum PetMood {
  happy,
  tired,
  normal,
  low;

  String get label {
    switch (this) {
      case PetMood.happy:
        return '开心';
      case PetMood.tired:
        return '疲惫';
      case PetMood.normal:
        return '普通';
      case PetMood.low:
        return '低落';
    }
  }
}

/// AI事件类别
enum EventCategory {
  daily,
  fun,
  challenge,
  healing;

  String get label {
    switch (this) {
      case EventCategory.daily:
        return '日常';
      case EventCategory.fun:
        return '趣味';
      case EventCategory.challenge:
        return '挑战';
      case EventCategory.healing:
        return '治愈';
    }
  }
}

/// 宠物数据模型
class PetData {
  final String name;
  final int level;
  final int growthCurrent;
  final int growthMax;
  final int moodValue;
  final PetMood mood;
  final int activity;
  final int intimacy;

  const PetData({
    this.name = '小宠',
    this.level = 1,
    this.growthCurrent = 0,
    this.growthMax = 100,
    this.moodValue = 80,
    this.mood = PetMood.happy,
    this.activity = 50,
    this.intimacy = 30,
  });

  PetData copyWith({
    String? name,
    int? level,
    int? growthCurrent,
    int? growthMax,
    int? moodValue,
    PetMood? mood,
    int? activity,
    int? intimacy,
  }) {
    return PetData(
      name: name ?? this.name,
      level: level ?? this.level,
      growthCurrent: growthCurrent ?? this.growthCurrent,
      growthMax: growthMax ?? this.growthMax,
      moodValue: moodValue ?? this.moodValue,
      mood: mood ?? this.mood,
      activity: activity ?? this.activity,
      intimacy: intimacy ?? this.intimacy,
    );
  }

  double get growthProgress => growthMax > 0 ? growthCurrent / growthMax : 0.0;
}

/// AI事件模型
class AiEvent {
  final String title;
  final String description;
  final EventCategory category;
  final List<String> presetOptions;
  final DateTime timestamp;

  AiEvent({
    required this.title,
    required this.description,
    required this.category,
    required this.presetOptions,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 成长记录条目
class GrowthRecord {
  final String content;
  final int valueChange;
  final DateTime timestamp;

  GrowthRecord({
    required this.content,
    required this.valueChange,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
