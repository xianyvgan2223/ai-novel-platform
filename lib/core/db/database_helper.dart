// lib/services/database_helper.dart
// sqflite 数据库单例 — 负责建表及版本迁移
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static const _dbName = 'deepseek.db';
  static const _dbVersion = 34;
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
    // 仅保留大纲专属列；字数配置已废弃移除，章节相关列已独立到 chapter_settings
    await db.execute('''
      CREATE TABLE outline_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
        system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1,
        pause_after_skeleton INTEGER NOT NULL DEFAULT 0,
        pause_after_events INTEGER NOT NULL DEFAULT 0,
        pause_after_minor INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert('outline_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-v4-flash',
      'system_prompt': '',
      'enable_thinking': 1,
    });

    // ── chapter_settings 章节写作设置表（小说模块，与大纲设置独立） ──
    await db.execute('''
      CREATE TABLE chapter_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
        chapter_system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1,
        enable_story_state INTEGER NOT NULL DEFAULT 1,
        chapter_min_words INTEGER NOT NULL DEFAULT 2000,
        chapter_max_words INTEGER NOT NULL DEFAULT 3000
      )
    ''');
    await db.insert('chapter_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-v4-flash',
      'chapter_system_prompt': '',
      'enable_thinking': 1,
      'enable_story_state': 1,
      'chapter_min_words': 2000,
      'chapter_max_words': 3000,
    });

    // ── outline_records 大纲生成记录表（小说模块） ──
    await db.execute('''
      CREATE TABLE outline_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        genre TEXT NOT NULL DEFAULT '',
        theme TEXT NOT NULL DEFAULT '',
        protagonist TEXT NOT NULL DEFAULT '',
        worldview TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        skeleton TEXT NOT NULL DEFAULT '',
        foreshadows TEXT NOT NULL DEFAULT '',
        story_state TEXT NOT NULL DEFAULT '',
        characters TEXT NOT NULL DEFAULT '',
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
        ai_summary TEXT NOT NULL DEFAULT '',
        story_state TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (outline_id) REFERENCES outline_records(id) ON DELETE CASCADE
      )
    ''');

    // ── character_chat_sessions 角色扮演会话表 ──
    await db.execute('''
      CREATE TABLE character_chat_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        personality TEXT NOT NULL DEFAULT '',
        scenario TEXT NOT NULL DEFAULT '',
        system_prompt TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // ── character_chat_messages 角色扮演消息表 ──
    await db.execute('''
      CREATE TABLE character_chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        is_user INTEGER NOT NULL DEFAULT 1,
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
      )
    ''');

    // ── character_tags 角色标签表 ──
    await db.execute('''
      CREATE TABLE character_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_name TEXT NOT NULL UNIQUE,
        tags TEXT NOT NULL DEFAULT '[]'
      )
    ''');

    // ── world_info_entries 世界书条目表 ──
    await db.execute('''
      CREATE TABLE world_info_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        keywords TEXT NOT NULL DEFAULT '[]',
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
      )
    ''');

    // ── character_memories 记忆表 ──
    await db.execute('''
      CREATE TABLE character_memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'general',
        importance INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
      )
    ''');

    // ── trpg_campaigns 跑团战役表 ──
    await db.execute('''
      CREATE TABLE trpg_campaigns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        dm_prompt TEXT NOT NULL DEFAULT '',
        scene TEXT NOT NULL DEFAULT '',
        flags TEXT NOT NULL DEFAULT '{}',
        summary TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // ── trpg_characters 跑团角色卡表（玩家 + NPC 共用） ──
    await db.execute('''
      CREATE TABLE trpg_characters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        campaign_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        race TEXT NOT NULL DEFAULT '',
        char_class TEXT NOT NULL DEFAULT '',
        level INTEGER NOT NULL DEFAULT 1,
        str INTEGER NOT NULL DEFAULT 10,
        dex INTEGER NOT NULL DEFAULT 10,
        con INTEGER NOT NULL DEFAULT 10,
        intl INTEGER NOT NULL DEFAULT 10,
        wis INTEGER NOT NULL DEFAULT 10,
        cha INTEGER NOT NULL DEFAULT 10,
        max_hp INTEGER NOT NULL DEFAULT 10,
        current_hp INTEGER NOT NULL DEFAULT 10,
        armor_bonus INTEGER NOT NULL DEFAULT 0,
        skilled_skills TEXT NOT NULL DEFAULT '[]',
        inventory TEXT NOT NULL DEFAULT '[]',
        background TEXT NOT NULL DEFAULT '',
        is_player INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (campaign_id) REFERENCES trpg_campaigns(id) ON DELETE CASCADE
      )
    ''');

    // ── trpg_messages 跑团叙事/对话日志表 ──
    await db.execute('''
      CREATE TABLE trpg_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        campaign_id INTEGER NOT NULL,
        is_user INTEGER NOT NULL DEFAULT 1,
        content TEXT NOT NULL,
        meta TEXT NOT NULL DEFAULT '{}',
        timestamp TEXT NOT NULL,
        FOREIGN KEY (campaign_id) REFERENCES trpg_campaigns(id) ON DELETE CASCADE
      )
    ''');

    // ── 同步簿记表（本机专用，不参与同步） ──
    await _createSyncTables(db);
  }

  /// 同步簿记表：sync_state 记录每行同步到哪个版本，sync_kv 存设备号与游标等
  static Future<void> _createSyncTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        db_name TEXT NOT NULL,
        table_name TEXT NOT NULL,
        pk INTEGER NOT NULL,
        rev INTEGER NOT NULL DEFAULT 0,
        hash TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (db_name, table_name, pk)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_kv (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  /// 导入数据库前暂存同步簿记（被导入的库文件里没有这两张表）
  static Future<Map<String, List<Map<String, Object?>>>>
      exportSyncBookkeeping() async {
    final db = await database;
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in const <String>['sync_kv', 'sync_state']) {
      try {
        out[table] = await db.query(table);
      } catch (_) {
        out[table] = const <Map<String, Object?>>[];
      }
    }
    return out;
  }

  /// 导入数据库后写回同步簿记，并确保两张表存在
  static Future<void> importSyncBookkeeping(
    Map<String, List<Map<String, Object?>>> data,
  ) async {
    final db = await database;
    await _createSyncTables(db);
    await db.transaction((txn) async {
      await txn.delete('sync_kv');
      await txn.delete('sync_state');
      for (final row in data['sync_kv'] ?? const <Map<String, Object?>>[]) {
        await txn.insert('sync_kv', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final row in data['sync_state'] ?? const <Map<String, Object?>>[]) {
        await txn.insert('sync_state', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
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
          worldview TEXT NOT NULL DEFAULT '',
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

    // V10 → V11：outline_settings 新增 chapter_system_prompt 列
    if (oldVersion < 11) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_settings)');
      final hasColumn = columns.any(
        (c) => c['name'] == 'chapter_system_prompt',
      );
      if (!hasColumn) {
        await db.execute(
          "ALTER TABLE outline_settings ADD COLUMN chapter_system_prompt TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V11 → V12：outline_records 新增 worldview 列
    if (oldVersion < 12) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_records)');
      final hasColumn = columns.any((c) => c['name'] == 'worldview');
      if (!hasColumn) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN worldview TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V12 → V13：outline_settings 新增字数配置列
    if (oldVersion < 13) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_settings)');
      final addIfMissing = (String col, int defaultVal) async {
        if (!columns.any((c) => c['name'] == col)) {
          await db.execute(
            "ALTER TABLE outline_settings ADD COLUMN $col INTEGER NOT NULL DEFAULT $defaultVal",
          );
        }
      };
      await addIfMissing('concept_min_words', 30);
      await addIfMissing('concept_max_words', 50);
      await addIfMissing('major_event_min_words', 50);
      await addIfMissing('major_event_max_words', 100);
      await addIfMissing('minor_event_min_words', 30);
      await addIfMissing('minor_event_max_words', 50);
      await addIfMissing('summary_max_words', 80);
    }

    // V15 → V16：新增 character_chat_sessions 和 character_chat_messages 表
    if (oldVersion < 16) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS character_chat_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_name TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          personality TEXT NOT NULL DEFAULT '',
          scenario TEXT NOT NULL DEFAULT '',
          system_prompt TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS character_chat_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          is_user INTEGER NOT NULL DEFAULT 1,
          content TEXT NOT NULL,
          timestamp TEXT NOT NULL,
          FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
        )
      ''');
    }

    // V15 → V16 迁移后补充 summary 列（兼容已有 V16 用户）
    if (oldVersion < 16 || oldVersion == 16) {
      final columns = await db.rawQuery(
        'PRAGMA table_info(character_chat_sessions)',
      );
      if (!columns.any((c) => c['name'] == 'summary')) {
        await db.execute(
          "ALTER TABLE character_chat_sessions ADD COLUMN summary TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V16 → V17：新增 character_tags / world_info_entries / character_memories 表
    if (oldVersion < 17) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS character_tags (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          character_name TEXT NOT NULL UNIQUE,
          tags TEXT NOT NULL DEFAULT '[]'
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS world_info_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          title TEXT NOT NULL,
          content TEXT NOT NULL,
          keywords TEXT NOT NULL DEFAULT '[]',
          enabled INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS character_memories (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          content TEXT NOT NULL,
          category TEXT NOT NULL DEFAULT 'general',
          importance INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          FOREIGN KEY (session_id) REFERENCES character_chat_sessions(id) ON DELETE CASCADE
        )
      ''');
    }

    // V17 → V18：删除已移除功能的 pet_data / memos 表
    if (oldVersion < 18) {
      await db.execute('DROP TABLE IF EXISTS pet_data');
      await db.execute('DROP TABLE IF EXISTS memos');
    }

    // V18 → V19：outline_settings 新增 enable_thinking 列（思考模式开关）
    if (oldVersion < 19) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_settings)');
      if (!columns.any((c) => c['name'] == 'enable_thinking')) {
        await db.execute(
          "ALTER TABLE outline_settings ADD COLUMN enable_thinking INTEGER NOT NULL DEFAULT 1",
        );
      }
    }

    // V19 → V20：outline_records 新增 foreshadows（伏笔清单）/ story_state（剧情状态账本）列，
    // outline_settings 新增 enable_story_state 列（章节剧情状态开关）
    if (oldVersion < 20) {
      var columns = await db.rawQuery('PRAGMA table_info(outline_records)');
      if (!columns.any((c) => c['name'] == 'foreshadows')) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN foreshadows TEXT NOT NULL DEFAULT ''",
        );
      }
      if (!columns.any((c) => c['name'] == 'story_state')) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN story_state TEXT NOT NULL DEFAULT ''",
        );
      }
      columns = await db.rawQuery('PRAGMA table_info(outline_settings)');
      if (!columns.any((c) => c['name'] == 'enable_story_state')) {
        await db.execute(
          "ALTER TABLE outline_settings ADD COLUMN enable_story_state INTEGER NOT NULL DEFAULT 0",
        );
      }
    }

    // V20 → V21：outline_chapters 新增 ai_summary 列（AI 提炼的整章小结）
    if (oldVersion < 21) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_chapters)');
      if (!columns.any((c) => c['name'] == 'ai_summary')) {
        await db.execute(
          "ALTER TABLE outline_chapters ADD COLUMN ai_summary TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V21 → V22：outline_records 新增 characters 列（人物档案 JSON，性格仅用户可改）
    if (oldVersion < 22) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_records)');
      if (!columns.any((c) => c['name'] == 'characters')) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN characters TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V22 → V23：章节写作设置独立成表（chapter_settings），与大纲生成设置彻底分离；
    // 从 outline_settings 迁移既有章节配置，避免升级后章节设置丢失
    if (oldVersion < 23) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS chapter_settings (
          id INTEGER PRIMARY KEY,
          temperature REAL NOT NULL DEFAULT 0.8,
          max_tokens INTEGER NOT NULL DEFAULT 4096,
          model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
          chapter_system_prompt TEXT NOT NULL DEFAULT '',
          enable_thinking INTEGER NOT NULL DEFAULT 1,
          enable_story_state INTEGER NOT NULL DEFAULT 1
        )
      ''');
      final exists = await db.query('chapter_settings', limit: 1);
      if (exists.isEmpty) {
        final src = await db.query('outline_settings', limit: 1);
        if (src.isNotEmpty) {
          final s = src.first;
          await db.insert('chapter_settings', {
            'id': 1,
            'temperature': s['temperature'] ?? 0.8,
            'max_tokens': s['max_tokens'] ?? 4096,
            'model': s['model'] ?? 'deepseek-v4-flash',
            'chapter_system_prompt': s['chapter_system_prompt'] ?? '',
            'enable_thinking': s['enable_thinking'] ?? 1,
            'enable_story_state': s['enable_story_state'] ?? 1,
          });
        } else {
          await db.insert('chapter_settings', {
            'id': 1,
            'temperature': 0.8,
            'max_tokens': 4096,
            'model': 'deepseek-v4-flash',
            'chapter_system_prompt': '',
            'enable_thinking': 1,
            'enable_story_state': 1,
          });
        }
      }
    }

    // V23 → V24：重建 outline_settings，彻底移除废弃/已迁移的列
    // （字数配置列已废弃移除；chapter_system_prompt / enable_story_state 已迁至 chapter_settings）
    // 采用「建新表→拷贝→删旧表→改名」方式，兼容不支持 DROP COLUMN 的旧 SQLite 版本
    if (oldVersion < 24) {
      final cols = await db.rawQuery('PRAGMA table_info(outline_settings)');
      final hasOrphan = cols.any(
        (c) =>
            c['name'] == 'concept_min_words' ||
            c['name'] == 'chapter_system_prompt',
      );
      if (hasOrphan) {
        await db.execute('''
          CREATE TABLE outline_settings_new (
            id INTEGER PRIMARY KEY,
            temperature REAL NOT NULL DEFAULT 0.8,
            max_tokens INTEGER NOT NULL DEFAULT 4096,
            model TEXT NOT NULL DEFAULT 'deepseek-v4-flash',
            system_prompt TEXT NOT NULL DEFAULT '',
            enable_thinking INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute('''
          INSERT INTO outline_settings_new
            (id, temperature, max_tokens, model, system_prompt, enable_thinking)
          SELECT id, temperature, max_tokens, model, system_prompt, enable_thinking
          FROM outline_settings
        ''');
        await db.execute('DROP TABLE outline_settings');
        await db.execute(
          'ALTER TABLE outline_settings_new RENAME TO outline_settings',
        );
      }
    }

    // V24 → V25：chapter_settings 新增单章字数范围列（章节字数可配置）
    if (oldVersion < 25) {
      final cols = await db.rawQuery('PRAGMA table_info(chapter_settings)');
      if (!cols.any((c) => c['name'] == 'chapter_min_words')) {
        await db.execute(
          'ALTER TABLE chapter_settings ADD COLUMN chapter_min_words INTEGER NOT NULL DEFAULT 2000',
        );
        await db.execute(
          'ALTER TABLE chapter_settings ADD COLUMN chapter_max_words INTEGER NOT NULL DEFAULT 3000',
        );
      }
    }

    // V25 → V26：剧情状态账本默认开启。
    // 此前从 outline_settings 迁移时沿用了旧默认值 0，此处对既有数据统一修正为默认开启
    if (oldVersion < 26) {
      await db.execute(
        'UPDATE chapter_settings SET enable_story_state = 1 WHERE id = 1 AND enable_story_state = 0',
      );
    }

    // V26 → V27：修正历史脏数据——内容为空但状态仍为已生成的章节恢复为待生成
    // （旧版清空内容时未同步 status，重载后会出现「内容已删却显示已生成」）
    if (oldVersion < 27) {
      await db.execute(
        "UPDATE outline_chapters SET status = 'pending' WHERE content IS NULL OR trim(content) = ''",
      );
    }

    // V27 → V28：outline_settings 新增生成检查点开关（粗骨架/大事件完成后暂停）
    if (oldVersion < 28) {
      final cols = await db.rawQuery('PRAGMA table_info(outline_settings)');
      if (!cols.any((c) => c['name'] == 'pause_after_skeleton')) {
        await db.execute(
          'ALTER TABLE outline_settings ADD COLUMN pause_after_skeleton INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!cols.any((c) => c['name'] == 'pause_after_events')) {
        await db.execute(
          'ALTER TABLE outline_settings ADD COLUMN pause_after_events INTEGER NOT NULL DEFAULT 0',
        );
      }
    }

    // V28 → V29：outline_settings 新增小事件检查点开关（步骤3展开完毕后暂停）
    if (oldVersion < 29) {
      final cols = await db.rawQuery('PRAGMA table_info(outline_settings)');
      if (!cols.any((c) => c['name'] == 'pause_after_minor')) {
        await db.execute(
          'ALTER TABLE outline_settings ADD COLUMN pause_after_minor INTEGER NOT NULL DEFAULT 0',
        );
      }
    }

    // V29 → V30：新增跑团（TRPG）模拟器相关表
    if (oldVersion < 30) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS trpg_campaigns (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          dm_prompt TEXT NOT NULL DEFAULT '',
          scene TEXT NOT NULL DEFAULT '',
          flags TEXT NOT NULL DEFAULT '{}',
          summary TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS trpg_characters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          campaign_id INTEGER NOT NULL,
          name TEXT NOT NULL,
          race TEXT NOT NULL DEFAULT '',
          char_class TEXT NOT NULL DEFAULT '',
          level INTEGER NOT NULL DEFAULT 1,
          str INTEGER NOT NULL DEFAULT 10,
          dex INTEGER NOT NULL DEFAULT 10,
          con INTEGER NOT NULL DEFAULT 10,
          intl INTEGER NOT NULL DEFAULT 10,
          wis INTEGER NOT NULL DEFAULT 10,
          cha INTEGER NOT NULL DEFAULT 10,
          max_hp INTEGER NOT NULL DEFAULT 10,
          current_hp INTEGER NOT NULL DEFAULT 10,
          armor_bonus INTEGER NOT NULL DEFAULT 0,
          skilled_skills TEXT NOT NULL DEFAULT '[]',
          inventory TEXT NOT NULL DEFAULT '[]',
          background TEXT NOT NULL DEFAULT '',
          is_player INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (campaign_id) REFERENCES trpg_campaigns(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS trpg_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          campaign_id INTEGER NOT NULL,
          is_user INTEGER NOT NULL DEFAULT 1,
          content TEXT NOT NULL,
          meta TEXT NOT NULL DEFAULT '{}',
          timestamp TEXT NOT NULL,
          FOREIGN KEY (campaign_id) REFERENCES trpg_campaigns(id) ON DELETE CASCADE
        )
      ''');
    }

    // V30 → V31：outline_records 新增 skeleton 列（书名/概念 + 精写后三幕骨架 JSON），
    // 供「局部重新生成」在内容不完整（如小事件中断后保存）时仍能重建粗骨与大事件
    if (oldVersion < 31) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_records)');
      if (!columns.any((c) => c['name'] == 'skeleton')) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN skeleton TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V31 → V32：outline_chapters 新增 story_state 列（每章独立的剧情账本）。
    // 每章生成时把本章账本保存到章节行，上一章账本作为下一章生成的上下文，
    // outline_records.story_state 仅镜像最新已完成章节的账本（账本页展示），
    // 章节重新生成后可回退查看/编辑历史账本
    if (oldVersion < 32) {
      final columns = await db.rawQuery('PRAGMA table_info(outline_chapters)');
      if (!columns.any((c) => c['name'] == 'story_state')) {
        await db.execute(
          "ALTER TABLE outline_chapters ADD COLUMN story_state TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V32 → V33：新增同步簿记表（sync_state / sync_kv）。
    // 顺带补齐 outline_settings 的 pause_after_minor 列 —— 该列此前只在 V29
    // 升级路径里创建，走 _onCreate 的全新安装缺少它，而 outline_setting.dart
    // 的 toMap() 会写入这一列，导致新装用户保存大纲设置时报 no such column。
    if (oldVersion < 33) {
      await _createSyncTables(db);
      final cols = await db.rawQuery('PRAGMA table_info(outline_settings)');
      if (!cols.any((c) => c['name'] == 'pause_after_minor')) {
        await db.execute(
          'ALTER TABLE outline_settings ADD COLUMN pause_after_minor INTEGER NOT NULL DEFAULT 0',
        );
      }
    }

    // V33 → V34：sync_state 增加 hash 列（行内容指纹）。
    // 有它之后推送就能先在本地比对，只有真正改过的行才会发出去；
    // 同时本地少了、簿记里还在的行会被识别成「已删除」并推给服务端。
    if (oldVersion < 34) {
      final cols = await db.rawQuery('PRAGMA table_info(sync_state)');
      if (cols.isNotEmpty && !cols.any((c) => c['name'] == 'hash')) {
        await db.execute(
          "ALTER TABLE sync_state ADD COLUMN hash TEXT NOT NULL DEFAULT ''",
        );
      }
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
