import 'package:flutter/foundation.dart';
import '../model/entity/char_copy_story_entity.dart';
import '../model/entity/character_entity.dart';
import '../model/db/char_copy_story_dao.dart';
import '../model/repo/character_repository.dart';
import '../novel_global_state.dart';

class CopyController extends ChangeNotifier {
  final CharCopyStoryDao _storyDao = CharCopyStoryDao();
  final CharacterRepository _charRepo = CharacterRepository();
  final NovelGlobalState _globalState = NovelGlobalState();

  /// 每个副本绑定的人物ID列表，key: copyId, value: characterId列表
  final Map<int, List<int>> _copyCharacterMap = {};

  /// 获取指定副本中的人物ID列表（不可变快照）
  List<int> getCharacterIdsInCopy(int copyId) =>
      List.unmodifiable(_copyCharacterMap[copyId] ?? []);

  /// 获取指定副本中的人物实体列表
  Future<List<CharacterEntity>> getCharactersInCopy(int copyId) async {
    final charIds = _copyCharacterMap[copyId] ?? [];
    if (charIds.isEmpty) return [];

    final allChars = await _charRepo.getCharacters();
    return allChars
        .where((c) => c.id != null && charIds.contains(c.id))
        .toList();
  }

  /// 加载所有副本的人物绑定数据
  Future<void> loadAllBindings() async {
    final allStories = await _storyDao.getAll();
    _copyCharacterMap.clear();
    for (final story in allStories) {
      _copyCharacterMap.putIfAbsent(story.copyId, () => []).add(story.charId);
    }
    notifyListeners();
  }

  /// 添加人物到副本（自动去重）
  Future<void> addCharacterToCopy(int copyId, int charId) async {
    final existing = _copyCharacterMap[copyId] ?? [];
    if (existing.contains(charId)) return;

    final story = CharCopyStoryEntity(copyId: copyId, charId: charId);

    // 先持久化
    await _charRepo.addCharStory(story);

    // 再更新内存状态
    _copyCharacterMap.putIfAbsent(copyId, () => []).add(charId);
    notifyListeners();
  }

  /// 从副本移除人物
  Future<void> removeCharacterFromCopy(int copyId, int charId) async {
    final list = _copyCharacterMap[copyId];
    if (list == null || !list.contains(charId)) return;

    // 从数据库中查找并删除对应的关联记录
    final stories = await _storyDao.getByCopyId(copyId);
    for (final s in stories) {
      if (s.charId == charId && s.id != null) {
        await _storyDao.delete(s.id!);
        break;
      }
    }

    // 更新内存状态
    list.remove(charId);
    if (list.isEmpty) {
      _copyCharacterMap.remove(copyId);
    }
    notifyListeners();
  }

  /// 启动副本AI生成（校验至少1个人物）
  Future<bool> startCopy(int copyId) async {
    final charIds = _copyCharacterMap[copyId];
    if (charIds == null || charIds.isEmpty) {
      return false;
    }

    _globalState.addRunningCopy(copyId);
    return true;
  }
}
