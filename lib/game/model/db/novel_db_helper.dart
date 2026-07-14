import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// 小说模块数据库管理工具
///
/// ### 数据库迁移指南
/// 每次修改表结构时：
/// 1. 递增 [databaseVersion]
/// 2. 在 `_migrations` map 中添加对应版本的迁移 SQL
/// 3. 在 `_migrationNotes` 中添加说明
///
/// 示例：如果现在要从 v1→v2（添加新表），只需：
/// ```
/// static const databaseVersion = 2;
/// ... _migrations: 2 → ["CREATE TABLE xxx (...)"]
/// ```
class NovelDbHelper {
  static final NovelDbHelper _instance = NovelDbHelper._internal();
  factory NovelDbHelper() => _instance;
  NovelDbHelper._internal();

  /// 当前数据库版本号 —— 每次改表结构必须递增
  static const databaseVersion = 1;

  /// 迁移脚本映射表
  /// key: 目标版本号, value: 要执行的 SQL 列表（从上一版升级到本版）
  ///
  /// 例如从 v1→v2：
  /// ```dart
  /// 2: [
  ///   'ALTER TABLE copy_table ADD COLUMN copy_desc TEXT',
  ///   'CREATE TABLE new_table (...)',
  /// ]
  /// ```
  static const Map<int, List<String>> _migrations = {
    // 示例：版本 2 迁移
    // 2: [
    //   'ALTER TABLE character_table ADD COLUMN avatar_url TEXT',
    // ],
  };

  // 仅供调试阅读的迁移说明
  static const Map<int, String> _migrationNotes = {
    // 2: 'character_table 新增 avatar_url 字段',
  };

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'novel.db');
    return await openDatabase(
      path,
      version: databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  /// 连接配置：启用外键约束
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// 首次创建数据库（仅在数据库不存在时调用）
  Future<void> _onCreate(Database db, int version) async {
    // 先建所有表（初始完整 schema）
    await _createAllTables(db);
    // 如果有版本 > 1 的迁移，仍需按顺序执行
    // （覆盖创建后直接升级到最新版本）
    for (var v = 1; v < version; v++) {
      await _runMigrationsForVersion(db, v + 1);
    }
  }

  /// 数据库升级（数据库已存在但版本号比本地低时调用）
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    for (var v = oldVersion; v < newVersion; v++) {
      await _runMigrationsForVersion(db, v + 1);
    }
  }

  /// 执行单个版本的迁移 SQL
  Future<void> _runMigrationsForVersion(Database db, int targetVersion) async {
    final sqls = _migrations[targetVersion];
    if (sqls == null || sqls.isEmpty) return;

    final note = _migrationNotes[targetVersion];
    await db.transaction((txn) async {
      for (final sql in sqls) {
        await txn.execute(sql);
      }
      // 更新版本号元数据
      await txn.execute('PRAGMA user_version = $targetVersion');
    });
    if (note != null) {
      // ignore: avoid_print
      print('[NovelDb] 数据库迁移 v${targetVersion - 1} → v$targetVersion: $note');
    }
  }

  /// 创建所有初始表（版本 1 的完整 schema）
  Future<void> _createAllTables(Database db) async {
    await db.execute('''
      CREATE TABLE copy_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        copy_name TEXT NOT NULL,
        model_config TEXT,
        create_time INTEGER NOT NULL,
        is_running INTEGER DEFAULT 0,
        unread_record INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE character_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        char_name TEXT NOT NULL,
        base_desc TEXT,
        create_time INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE skill_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        char_id INTEGER NOT NULL,
        skill_name TEXT NOT NULL,
        skill_desc TEXT,
        source_copy_id INTEGER,
        FOREIGN KEY (char_id) REFERENCES character_table(id) ON DELETE CASCADE,
        FOREIGN KEY (source_copy_id) REFERENCES copy_table(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE equipment_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        char_id INTEGER NOT NULL,
        equip_name TEXT NOT NULL,
        equip_attr TEXT,
        source_copy_id INTEGER,
        FOREIGN KEY (char_id) REFERENCES character_table(id) ON DELETE CASCADE,
        FOREIGN KEY (source_copy_id) REFERENCES copy_table(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE character_intersection_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        char_a_id INTEGER NOT NULL,
        char_b_id INTEGER NOT NULL,
        intersection_desc TEXT,
        update_time INTEGER NOT NULL,
        FOREIGN KEY (char_a_id) REFERENCES character_table(id) ON DELETE CASCADE,
        FOREIGN KEY (char_b_id) REFERENCES character_table(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE copy_record_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        copy_id INTEGER NOT NULL,
        total_story TEXT,
        create_time INTEGER NOT NULL,
        FOREIGN KEY (copy_id) REFERENCES copy_table(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE char_copy_story_table (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        copy_id INTEGER NOT NULL,
        char_id INTEGER NOT NULL,
        single_story TEXT,
        FOREIGN KEY (copy_id) REFERENCES copy_table(id) ON DELETE CASCADE,
        FOREIGN KEY (char_id) REFERENCES character_table(id) ON DELETE CASCADE
      )
    ''');

    // 创建索引提高查询性能
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_skill_char_id ON skill_table(char_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_equip_char_id ON equipment_table(char_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_intersection_char_a ON character_intersection_table(char_a_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_intersection_char_b ON character_intersection_table(char_b_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_copy_record_copy_id ON copy_record_table(copy_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_char_story_copy_id ON char_copy_story_table(copy_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_char_story_char_id ON char_copy_story_table(char_id)',
    );
  }

  /// 重置数据库（用于调试，删除所有数据重新创建）
  Future<void> resetDatabase() async {
    final db = await database;
    // 按外键依赖顺序倒序删除
    await db.delete('char_copy_story_table');
    await db.delete('copy_record_table');
    await db.delete('character_intersection_table');
    await db.delete('equipment_table');
    await db.delete('skill_table');
    await db.delete('character_table');
    await db.delete('copy_table');
  }
}
