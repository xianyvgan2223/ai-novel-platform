import 'package:sqflite/sqflite.dart';
import '../../../../../core/db/database_helper.dart';

/// 大纲生成记录数据库操作
class OutlineRecordDbHelper {
  static final OutlineRecordDbHelper _instance = OutlineRecordDbHelper._internal();
  factory OutlineRecordDbHelper() => _instance;
  OutlineRecordDbHelper._internal();

  Future<Database> get database => DatabaseHelper.database;

  /// 列表页只需要这些「小字段」，一次查出即可。
  ///
  /// 不要把 content / skeleton / foreshadows 加进来：Android 的 CursorWindow
  /// 固定 2 MB，而一条大纲的正文 + 骨架合计可以超过 2 MB（实测 2.68 MB），
  /// 一旦被 SELECT * 带上，整条查询会抛
  /// "Row too big to fit into CursorWindow"，列表就会变成「没有大纲」。
  static const List<String> _lightColumns = <String>[
    'id',
    'title',
    'genre',
    'theme',
    'protagonist',
    'worldview',
    'created_at',
  ];

  /// 大文本字段：必须一次只查一列（单列远小于 2 MB，能安全读取）。
  static const List<String> _heavyColumns = <String>[
    'content',
    'skeleton',
    'foreshadows',
    'story_state',
    'characters',
  ];

  /// 插入一条大纲记录
  Future<int> insert(Map<String, dynamic> record) async {
    final db = await database;
    return db.insert('outline_records', record);
  }

  /// 获取全部大纲的「列表摘要」（按时间倒序），只含小字段。
  ///
  /// 列表页一律走这里；需要正文 / 骨架等完整字段时再用 [getById] 单独取。
  Future<List<Map<String, dynamic>>> getAllSummaries() async {
    final db = await database;
    return db.query(
      'outline_records',
      columns: _lightColumns,
      orderBy: 'created_at DESC',
    );
  }

  /// 获取单条大纲记录（完整字段）。
  ///
  /// 刻意按列拼装而不是 SELECT *：Android 的 CursorWindow 只有 2 MB，
  /// 一条记录的 content + skeleton 可能超过它，SELECT * 会抛
  /// "Row too big to fit into CursorWindow"；逐列查询时每个字段单独进窗口，
  /// 单列最大值（当前约 1.3 MB）装得下。
  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await database;
    final head = await db.query(
      'outline_records',
      columns: _lightColumns,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (head.isEmpty) return null;
    final row = Map<String, dynamic>.from(head.first);
    for (final column in _heavyColumns) {
      final part = await db.query(
        'outline_records',
        columns: <String>[column],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (part.isNotEmpty) row[column] = part.first[column];
    }
    return row;
  }

  /// 只取大纲正文文本（**单列**查询，避开 CursorWindow 的 2 MB 限制）。
  ///
  /// 给「按最新正文校正章节结构」用（`reconcileOutlineChapters`）：页面手里那条
  /// `OutlineRecord` 是打开这本小说时的快照（`content` 是 final，编辑页保存时
  /// 只写库、不回填内存），不能拿它当校正依据。
  /// 记录不存在时返回 null（与「正文为空」区分开：正文为空也是有效状态，
  /// 调用方必须照它清空结构，而不是退回旧快照）。
  Future<String?> getContentById(int id) async {
    final db = await database;
    final rows = await db.query(
      'outline_records',
      columns: const <String>['content'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['content'] as String?;
  }

  /// 更新大纲记录内容。
  ///
  /// **写回正文前先把上一版正文留一份**（`content_backup` / `content_backup_at`）：
  /// 大纲正文是整段写回的（编辑页保存、章节页改标题、生成侧落库），一旦写错
  /// ——改错行、结构错位、把原来写好的几条大事件顶掉——用户就再也找不回来了。
  /// 留一版就够「回到改动前」，代价只是一列文本。
  ///
  /// 只在「正文确实变了、且新正文不是空串」时才动备份：只更新设置列（title /
  /// protagonist……）的空写回不该把好端端的备份冲掉。
  Future<void> update(int id, Map<String, dynamic> record) async {
    final db = await database;
    final next = record['content'];
    if (next is String && next.isNotEmpty) {
      final rows = await db.query(
        'outline_records',
        columns: const <String>['content'],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final old = rows.isEmpty ? null : rows.first['content'] as String?;
      if (old != null && old.isNotEmpty && old != next) {
        record = <String, dynamic>{
          ...record,
          'content_backup': old,
          'content_backup_at': DateTime.now().toIso8601String(),
        };
      }
    }
    await db.update('outline_records', record, where: 'id = ?', whereArgs: [id]);
  }

  /// 取上一版正文备份（[update] 每次覆盖正文前留下的那一份）。
  ///
  /// 供误覆盖后的找回使用：单列查询，避开 CursorWindow 的 2 MB 限制。
  /// 返回 (正文, 备份时间)；没有备份时正文为空串。
  Future<({String content, String savedAt})> getContentBackup(int id) async {
    final db = await database;
    final rows = await db.query(
      'outline_records',
      columns: const <String>['content_backup', 'content_backup_at'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return (content: '', savedAt: '');
    return (
      content: rows.first['content_backup'] as String? ?? '',
      savedAt: rows.first['content_backup_at'] as String? ?? '',
    );
  }

  /// 删除大纲记录
  Future<void> delete(int id) async {
    final db = await database;
    await db.delete('outline_records', where: 'id = ?', whereArgs: [id]);
  }
}
