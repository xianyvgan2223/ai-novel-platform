import '../entity/character_intersection_entity.dart';
import '../db/intersection_dao.dart';

class IntersectionRepository {
  final IntersectionDao _intersectionDao = IntersectionDao();

  /// 合并/更新两个角色之间的交集描述
  Future<void> mergeIntersection(
    int charAId,
    int charBId,
    String newDesc,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entity = CharacterIntersectionEntity(
      charAId: charAId,
      charBId: charBId,
      intersectionDesc: newDesc,
      updateTime: now,
    );
    await _intersectionDao.upsert(entity);
  }

  Future<CharacterIntersectionEntity?> getIntersection(
    int charAId,
    int charBId,
  ) => _intersectionDao.getByCharPair(charAId, charBId);

  Future<List<CharacterIntersectionEntity>> getIntersectionsByCharId(
    int charId,
  ) => _intersectionDao.getIntersectionsForChar(charId);

  Future<int> createIntersection(CharacterIntersectionEntity entity) =>
      _intersectionDao.insert(entity);

  Future<int> updateIntersection(CharacterIntersectionEntity entity) =>
      _intersectionDao.update(entity);
}
