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

  /// 更新大纲记录内容
  Future<void> update(int id, Map<String, dynamic> record) async {
    final db = await database;
    await db.update('outline_records', record, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除大纲记录
  Future<void> delete(int id) async {
    final db = await database;
    await db.delete('outline_records', where: 'id = ?', whereArgs: [id]);
  }
}
