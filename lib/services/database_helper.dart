// lib/services/database_helper.dart
// sqflite 数据库单例 — 负责建表及版本迁移
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static const _dbName = 'deepseek.db';
  static const _dbVersion = 10;
  static Database? _database;

  /// 单例入口，全局复用同一个数据库连接
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// 数据库文件完整路径
  static Future<String> get databasePath async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, 'deepseekApp_data', _dbName);
  }

  /// 关闭当前数据库连接（导入/导出前使用）
  static Future<void> closeDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  /// 检查指定 db 文件版本是否兼容
  /// 检查指定 db 文件版本是否兼容
  /// [filePath] db 文件路径
  /// 返回 null 表示兼容，否则返回错误说明
  static Future<String?> validateDbFile(String filePath) async {
    Database? testDb;
    try {
      // 不传 version，避免 sqflite 尝试 PRAGMA user_version = N（只读模式下会失败）
      testDb = await openDatabase(
        filePath,
        readOnly: true,
        singleInstance: false,
      );
      // 手动查询版本号
      final result = await testDb.rawQuery('PRAGMA user_version');
      final version = result.first['user_version'] as int? ?? 0;
      await testDb.close();
      testDb = null;

      if (version > _dbVersion) {
        return '数据库版本 v$version 高于当前应用版本 v$_dbVersion，不兼容';
      }
      return null;
    } catch (e) {
      if (testDb != null) await testDb.close();
      // 可能是完全无关的文件
      try {
        final bytes = await File(filePath).length();
        if (bytes < 100) return '文件不是有效的数据库';
      } catch (_) {}
      return '无法读取数据库文件：$e';
    }
  }

  /// 打开数据库，传入 onCreate / onUpgrade 回调
  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'deepseekApp_data', _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 新用户首次安装：创建最新完整表结构（V3+ 含 battle 表）
  static Future<void> _onCreate(Database db, int version) async {
    // ── user_settings 用户配置表（全局单条记录） ──
    await db.execute('''
      CREATE TABLE user_settings (
        id INTEGER PRIMARY KEY,
        model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
        apiKey TEXT NOT NULL DEFAULT '',
        temperature REAL NOT NULL DEFAULT 1.0,
        top_p REAL NOT NULL DEFAULT 1.0,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        stop TEXT NOT NULL DEFAULT '',
        stream INTEGER NOT NULL DEFAULT 1,
        stream_options TEXT NOT NULL DEFAULT '',
        frequency_penalty REAL NOT NULL DEFAULT 0.0,
        presence_penalty REAL NOT NULL DEFAULT 0.0,
        response_format TEXT NOT NULL DEFAULT 'text',
        thinking INTEGER NOT NULL DEFAULT 0,
        logprobs INTEGER NOT NULL DEFAULT 0,
        top_logprobs INTEGER NOT NULL DEFAULT 0,
        logit_bias TEXT NOT NULL DEFAULT '',
        n INTEGER NOT NULL DEFAULT 1,
        reasoning_content TEXT NOT NULL DEFAULT '',
        context_rounds INTEGER NOT NULL DEFAULT 10,
        system_prompt TEXT NOT NULL DEFAULT '',
        web_search INTEGER NOT NULL DEFAULT 0,
        baidu_api_key TEXT NOT NULL DEFAULT '',
        search_count INTEGER NOT NULL DEFAULT 5,
        search_freshness TEXT NOT NULL DEFAULT '',
        history_query INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ── chat_sessions 会话表（每条记录对应一组独立对话） ──
    await db.execute('''
      CREATE TABLE chat_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        create_time TEXT NOT NULL,
        last_message TEXT NOT NULL DEFAULT '',
        system_prompt TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT ''
      )
    ''');

    // ── chat_messages 消息表（关联 session_id） ──
    await db.execute('''
      CREATE TABLE chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        thinking_text TEXT,
        search_results TEXT,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
      )
    ''');

    // ── battle_scenes 战斗场景表（写小说） ──
    await db.execute('''
      CREATE TABLE battle_scenes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_input TEXT NOT NULL,
        ai_result TEXT NOT NULL DEFAULT '',
        character_skills TEXT NOT NULL DEFAULT '',
        battle_scene_desc TEXT NOT NULL DEFAULT '',
        battle_result TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'completed',
        created_at TEXT NOT NULL
      )
    ''');

    // ── battle_settings 战斗设置表（写小说，单条记录） ──
    await db.execute('''
      CREATE TABLE battle_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
        system_prompt TEXT NOT NULL DEFAULT ''
      )
    ''');

    // 插入默认战斗设置
    await db.insert('battle_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-v4-flash',
      'system_prompt': '',
    });

    // ── outline_settings 大纲生成设置表（小说模块） ──
    await db.execute('''
      CREATE TABLE outline_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
        system_prompt TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.insert('outline_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-v4-flash',
      'system_prompt': '',
    });

    // ── outline_records 大纲生成记录表（小说模块） ──
    await db.execute('''
      CREATE TABLE outline_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        theme TEXT NOT NULL DEFAULT '',
        protagonist TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');

    // ── outline_chapters 章节生成表（按事件逐章写入） ──
    await db.execute('''
      CREATE TABLE outline_chapters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        outline_id INTEGER NOT NULL,
        event_index INTEGER NOT NULL,
        event_type TEXT NOT NULL DEFAULT 'major',
        event_title TEXT NOT NULL DEFAULT '',
        event_summary TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (outline_id) REFERENCES outline_records(id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // V1 → V2：新增 chat_messages 表（已在 V1 创建，仅占位）
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS chat_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          thinking_text TEXT,
          search_results TEXT,
          timestamp TEXT NOT NULL,
          FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
        )
      ''');
    }

    // V2 → V3：新增 battle_scenes / battle_settings 表（写小说）
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS battle_scenes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_input TEXT NOT NULL,
          ai_result TEXT NOT NULL DEFAULT '',
          character_skills TEXT NOT NULL DEFAULT '',
          battle_scene_desc TEXT NOT NULL DEFAULT '',
          battle_result TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'completed',
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS battle_settings (
          id INTEGER PRIMARY KEY,
          temperature REAL NOT NULL DEFAULT 0.8,
          max_tokens INTEGER NOT NULL DEFAULT 4096,
          model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
          system_prompt TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.insert('battle_settings', {
        'id': 1,
        'temperature': 0.8,
        'max_tokens': 4096,
        'model': 'deepseek-v4-flash',
        'system_prompt': '',
      });

      // ── 从旧 battle.db 迁移数据（如果有） ──
      await _migrateBattleDb(db);
    }

    // V3 → V4：chat_sessions 新增 summary 列（对话摘要）
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE chat_sessions ADD COLUMN summary TEXT NOT NULL DEFAULT ''",
      );
    }

    // V4 → V5：user_settings 新增 history_query 列（对话历史查询工具）
    if (oldVersion < 5) {
      // 先检查列是否已存在（避免重复迁移导致 crash）
      final columns = await db.rawQuery('PRAGMA table_info(user_settings)');
      final hasColumn = columns.any((c) => c['name'] == 'history_query');
      if (!hasColumn) {
        await db.execute(
          "ALTER TABLE user_settings ADD COLUMN history_query INTEGER NOT NULL DEFAULT 0",
        );
      }
    }

    // V5 → V6：新建 message_embeddings 表（RAG 语义搜索）
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS message_embeddings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER NOT NULL,
          session_id INTEGER NOT NULL,
          embedding BLOB NOT NULL,
          FOREIGN KEY (message_id) REFERENCES chat_messages(id) ON DELETE CASCADE,
          FOREIGN KEY (session_id) REFERENCES chat_sessions(id) ON DELETE CASCADE
        )
      ''');
    }

    // V6 → V7：删除 message_embeddings 表（history_query 工具已移除）
    if (oldVersion < 7) {
      await db.execute('DROP TABLE IF EXISTS message_embeddings');
    }

    // V7 → V8：新增 outline_settings 表（大纲生成设置）
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outline_settings (
          id INTEGER PRIMARY KEY,
          temperature REAL NOT NULL DEFAULT 0.8,
          max_tokens INTEGER NOT NULL DEFAULT 4096,
          model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
          system_prompt TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.insert('outline_settings', {
        'id': 1,
        'temperature': 0.8,
        'max_tokens': 4096,
        'model': 'deepseek-v4-flash',
        'system_prompt': '',
      });
    }

    // V8 → V9：新增 outline_records 表（大纲生成记录）
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outline_records (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL DEFAULT '',
          genre TEXT NOT NULL DEFAULT '',
          theme TEXT NOT NULL DEFAULT '',
          protagonist TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        )
      ''');
    }

    // V9 → V10：新增 outline_chapters 表（按事件逐章写入）
    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outline_chapters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          outline_id INTEGER NOT NULL,
          event_index INTEGER NOT NULL,
          event_type TEXT NOT NULL DEFAULT 'major',
          event_title TEXT NOT NULL DEFAULT '',
          event_summary TEXT NOT NULL DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (outline_id) REFERENCES outline_records(id) ON DELETE CASCADE
        )
      ''');
    }
  }

  /// 从独立的 battle.db 迁移数据到 deepseek.db
  static Future<void> _migrateBattleDb(Database targetDb) async {
    final dbPath = await getDatabasesPath();
    final battleDbPath = p.join(dbPath, 'battle.db');
    final battleFile = File(battleDbPath);
    if (!battleFile.existsSync()) return;

    Database? battleDb;
    try {
      battleDb = await openDatabase(battleDbPath, version: 1, readOnly: true);

      // 迁移战斗场景
      final scenes = await battleDb.query('battle_scenes');
      for (final scene in scenes) {
        scene.remove('id'); // 让 autoincrement 重新分配 id
        await targetDb.insert('battle_scenes', scene);
      }

      // 迁移战斗设置
      final settings = await battleDb.query('battle_settings', limit: 1);
      if (settings.isNotEmpty) {
        final s = settings.first;
        await targetDb.update(
          'battle_settings',
          s,
          where: 'id = ?',
          whereArgs: [1],
        );
      }
    } catch (_) {
      // battle.db 可能表结构不完整，静默跳过
    } finally {
      if (battleDb != null) await battleDb.close();
    }

    // 迁移完成后删除旧文件
    try {
      await battleFile.delete();
    } catch (_) {}
  }
}
