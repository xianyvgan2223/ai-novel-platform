import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../pet_state.dart';
import '../../services/pet_storage_service.dart';

/// 宠物核心状态管理（带数据库持久化）
class PetController extends ChangeNotifier {
  PetData _pet = const PetData();
  AiEvent? _currentEvent;
  final List<GrowthRecord> _records = [];
  int _eventIndex = 0;
  bool _loaded = false;

  PetData get pet => _pet;
  AiEvent? get currentEvent => _currentEvent;
  List<GrowthRecord> get records => List.unmodifiable(_records);
  bool get hasActiveEvent => _currentEvent != null;

  /// 从数据库加载宠物数据
  Future<void> loadFromDb() async {
    if (_loaded) return;
    final (pet, records) = await PetStorageService.loadPet();
    _pet = pet;
    _records
      ..clear()
      ..addAll(records);
    _loaded = true;
    notifyListeners();
  }

  /// 保存到数据库
  Future<void> _saveToDb() async {
    await PetStorageService.savePet(_pet, _records);
  }

  // ========== 宠物状态操作 ==========

  /// 更新心情值（带状态标签联动）
  void updateMood(int delta) {
    final newValue = (_pet.moodValue + delta).clamp(0, 100);
    PetMood newMood;
    if (newValue >= 70) {
      newMood = PetMood.happy;
    } else if (newValue >= 50) {
      newMood = PetMood.normal;
    } else if (newValue >= 25) {
      newMood = PetMood.tired;
    } else {
      newMood = PetMood.low;
    }
    _pet = _pet.copyWith(moodValue: newValue, mood: newMood);
    notifyListeners();
    _saveToDb();
  }

  /// 增加成长值（带升级检测）
  void addGrowth(int value) {
    final total = _pet.growthCurrent + value;
    if (total >= _pet.growthMax) {
      final remainder = total - _pet.growthMax;
      _pet = _pet.copyWith(
        level: _pet.level + 1,
        growthCurrent: remainder,
        growthMax: (_pet.growthMax * 1.3).round(),
      );
      addRecord('升级！当前等级 ${_pet.level}', 0);
    } else {
      _pet = _pet.copyWith(growthCurrent: total);
    }
    notifyListeners();
    _saveToDb();
  }

  /// 更新活跃度
  void updateActivity(int delta) {
    _pet = _pet.copyWith(activity: (_pet.activity + delta).clamp(0, 100));
    notifyListeners();
    _saveToDb();
  }

  /// 更新亲密度
  void updateIntimacy(int delta) {
    _pet = _pet.copyWith(intimacy: (_pet.intimacy + delta).clamp(0, 100));
    notifyListeners();
    _saveToDb();
  }

  /// 离线状态缓慢刷新（模拟）
  void simulateOfflineDecay(int hours) {
    final moodDecay = (hours * 2).clamp(0, 30);
    final activityDecay = (hours * 3).clamp(0, 40);
    updateMood(-moodDecay);
    updateActivity(-activityDecay);
    if (hours > 4) {
      addRecord('离线了 $hours 小时，宠物有些想念你', 0);
    }
  }

  // ========== AI事件系统 ==========

  /// 模拟AI生成随机事件
  void generateRandomEvent() {
    final events = _mockEvents;
    _currentEvent = events[_eventIndex % events.length];
    _eventIndex++;
    notifyListeners();
  }

  /// 用户决策响应
  void respondToEvent(String decision) {
    if (_currentEvent == null) return;

    final positiveKeywords = [
      '陪伴',
      '安抚',
      '互动',
      '奖励',
      '玩耍',
      '喂食',
      '好',
      '陪',
      '关心',
      '抱抱',
    ];
    final isPositive = positiveKeywords.any((kw) => decision.contains(kw));

    final growthDelta = isPositive ? 15 : -10;
    final moodDelta = isPositive ? 10 : -15;
    final intimacyDelta = isPositive ? 8 : -12;

    addGrowth(growthDelta);
    updateMood(moodDelta);
    updateIntimacy(intimacyDelta);

    addRecord(isPositive ? '积极回应：$decision' : '消极回应：$decision', growthDelta);

    _currentEvent = null;
    notifyListeners();
  }

  // ========== 成长记录 ==========

  void addRecord(String content, int valueChange) {
    _records.insert(
      0,
      GrowthRecord(content: content, valueChange: valueChange),
    );
    if (_records.length > 100) {
      _records.removeLast();
    }
    _saveToDb();
  }

  // ========== 模拟事件数据 ==========

  static final List<AiEvent> _mockEvents = [
    AiEvent(
      title: '想要玩耍',
      description: '小宠在你脚边转来转去，叼来了它最喜欢的玩具球，眼巴巴地望着你，希望你能陪它玩一会儿。',
      category: EventCategory.daily,
      presetOptions: ['陪它玩耍', '摸摸头安抚', '先忙一会'],
    ),
    AiEvent(
      title: '肚子饿了',
      description: '小宠用鼻子蹭了蹭你的手，发出轻轻的呜咽声——它饿了，想让你给它准备吃的。',
      category: EventCategory.daily,
      presetOptions: ['喂食', '给零食奖励', '再等一会儿'],
    ),
    AiEvent(
      title: '突发小挑战',
      description: '外面突然下起大雨，一声惊雷让小宠吓得躲到了桌子底下，身体微微发抖，需要你的安慰。',
      category: EventCategory.challenge,
      presetOptions: ['温柔安抚', '抱在怀里', '用零食引导'],
    ),
    AiEvent(
      title: '想要探险',
      description: '小宠兴奋地跑到门口，回头朝你叫了一声，又跑回来蹭你的腿，明显想让你带它出去探险。',
      category: EventCategory.fun,
      presetOptions: ['出门探险', '在屋里玩', '改天再去'],
    ),
    AiEvent(
      title: '安静陪伴',
      description: '小宠安静地趴在你旁边，把头枕在你的腿上，发出满足的呼噜声，享受着和你在一起的平静时光。',
      category: EventCategory.healing,
      presetOptions: ['轻轻抚摸', '和它说话', '安静待着'],
    ),
    AiEvent(
      title: '感到孤单',
      description: '小宠独自趴在窗边，望着外面的风景，时不时回头看看你，眼神里带着一丝孤单。',
      category: EventCategory.daily,
      presetOptions: ['过去陪伴', '叫它过来', '给它玩具'],
    ),
    AiEvent(
      title: '发现新玩具',
      description: '小宠不知道从哪里翻出一个旧毛线球，兴奋地在屋里跑来跑去，不小心把线缠在了桌腿上。',
      category: EventCategory.fun,
      presetOptions: ['帮忙解开', '一起玩', '收起来'],
    ),
  ];
}

final petProvider = ChangeNotifierProvider<PetController>((ref) {
  return PetController();
});
