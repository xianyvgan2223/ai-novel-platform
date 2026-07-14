import '../entity/character_entity.dart';
import '../entity/skill_entity.dart';
import '../entity/equipment_entity.dart';
import '../entity/char_copy_story_entity.dart';
import '../entity/character_intersection_entity.dart';
import '../db/character_dao.dart';
import '../db/skill_dao.dart';
import '../db/equipment_dao.dart';
import '../db/char_copy_story_dao.dart';
import '../db/intersection_dao.dart';

class CharacterRepository {
  final CharacterDao _charDao = CharacterDao();
  final SkillDao _skillDao = SkillDao();
  final EquipmentDao _equipDao = EquipmentDao();
  final CharCopyStoryDao _storyDao = CharCopyStoryDao();
  final IntersectionDao _intersectionDao = IntersectionDao();

  /// 创建角色，返回角色ID
  Future<int> createCharacter(String name, String desc) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entity = CharacterEntity(
      charName: name,
      baseDesc: desc,
      createTime: now,
    );
    return await _charDao.insert(entity);
  }

  /// 获取所有角色
  Future<List<CharacterEntity>> getCharacters() => _charDao.getAll();

  /// 获取角色详情（包含技能和装备）
  Future<Map<String, dynamic>> getCharacterDetail(int charId) async {
    final character = await _charDao.getById(charId);
    final skills = await _skillDao.getByCharId(charId);
    final equipment = await _equipDao.getByCharId(charId);
    return {'character': character, 'skills': skills, 'equipment': equipment};
  }

  Future<CharacterEntity?> getCharacterById(int id) => _charDao.getById(id);
  Future<int> updateCharacter(CharacterEntity character) =>
      _charDao.update(character);

  Future<int> deleteCharacter(int id) async {
    await _skillDao.deleteByCharId(id);
    await _equipDao.deleteByCharId(id);
    await _storyDao.deleteByCharId(id);
    await _intersectionDao.deleteByCharId(id);
    return await _charDao.delete(id);
  }

  Future<List<SkillEntity>> getSkillsByCharId(int charId) =>
      _skillDao.getByCharId(charId);
  Future<List<EquipmentEntity>> getEquipmentByCharId(int charId) =>
      _equipDao.getByCharId(charId);
  Future<int> addSkill(SkillEntity skill) => _skillDao.insert(skill);
  Future<int> addEquipment(EquipmentEntity equipment) =>
      _equipDao.insert(equipment);
  Future<int> addCharStory(CharCopyStoryEntity story) =>
      _storyDao.insert(story);
  Future<List<CharCopyStoryEntity>> getCharStoriesByCharId(int charId) =>
      _storyDao.getByCharId(charId);

  Future<int> saveSkill(
    int charId,
    String name,
    String desc,
    int sourceCopyId,
  ) => _skillDao.insert(
    SkillEntity(
      charId: charId,
      skillName: name,
      skillDesc: desc,
      sourceCopyId: sourceCopyId,
    ),
  );
  Future<int> saveEquipment(
    int charId,
    String name,
    String attr,
    int sourceCopyId,
  ) => _equipDao.insert(
    EquipmentEntity(
      charId: charId,
      equipName: name,
      equipAttr: attr,
      sourceCopyId: sourceCopyId,
    ),
  );
  Future<int> saveIntersection(int charAId, int charBId, String desc) =>
      _intersectionDao.insert(
        CharacterIntersectionEntity(
          charAId: charAId,
          charBId: charBId,
          intersectionDesc: desc,
        ),
      );
}
