import '../entity/copy_entity.dart';
import '../entity/copy_record_entity.dart';
import '../entity/char_copy_story_entity.dart';
import '../db/copy_dao.dart';
import '../db/copy_record_dao.dart';
import '../db/char_copy_story_dao.dart';

class CopyRepository {
  final CopyDao _copyDao = CopyDao();
  final CopyRecordDao _recordDao = CopyRecordDao();
  final CharCopyStoryDao _storyDao = CharCopyStoryDao();

  /// 获取所有副本
  Future<List<CopyEntity>> getCopies() => _copyDao.getAll();

  /// 创建空白副本，返回副本ID
  Future<int> createCopy(String name, {String? modelConfig}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entity = CopyEntity(
      copyName: name,
      modelConfig: modelConfig,
      createTime: now,
    );
    return await _copyDao.insert(entity);
  }

  /// 启动副本AI生成
  Future<void> startCopyRun(int copyId, List<int> characterIds) async {
    // 标记为运行中
    final copy = await _copyDao.getById(copyId);
    if (copy == null) throw Exception('副本不存在');

    copy.isRunning = 1;
    await _copyDao.update(copy);

    try {
      // TODO: 实际AI生成逻辑，需要根据characterIds获取CharacterEntity列表
      // 此处仅做标记更新
      copy.isRunning = 0;
      copy.unreadRecord = 1;
      await _copyDao.update(copy);
    } catch (e) {
      copy.isRunning = 0;
      await _copyDao.update(copy);
      rethrow;
    }
  }

  Future<CopyEntity?> getCopyById(int id) => _copyDao.getById(id);
  Future<int> updateCopy(CopyEntity copy) => _copyDao.update(copy);
  Future<int> deleteCopy(int id) => _copyDao.delete(id);
  Future<List<CopyEntity>> getRunningCopies() => _copyDao.getRunningCopies();
  Future<List<CopyEntity>> getUnreadCopies() => _copyDao.getUnreadCopies();
  Future<void> markAsRead(int id) => _copyDao.markAsRead(id);

  Future<List<CopyRecordEntity>> getAllRecords() => _recordDao.getAll();
  Future<List<CopyRecordEntity>> getRecordsByCopyId(int copyId) =>
      _recordDao.getByCopyId(copyId);
  Future<CopyRecordEntity?> getLatestRecordByCopyId(int copyId) =>
      _recordDao.getLatestByCopyId(copyId);
  Future<List<CharCopyStoryEntity>> getCharStoriesByCopyId(int copyId) =>
      _storyDao.getByCopyId(copyId);
  Future<int> addRecord(CopyRecordEntity record) => _recordDao.insert(record);
  Future<int> saveCopyRecord(int copyId, String totalStory) => _recordDao
      .insert(CopyRecordEntity(copyId: copyId, totalStory: totalStory));
  Future<int> saveCharCopyStory(int copyId, int charId, String singleStory) =>
      _storyDao.insert(
        CharCopyStoryEntity(
          copyId: copyId,
          charId: charId,
          singleStory: singleStory,
        ),
      );
}
