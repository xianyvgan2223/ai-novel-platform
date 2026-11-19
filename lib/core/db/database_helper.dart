// lib/services/database_helper.dart
// sqflite 数据库单例 — 负责建表及版本迁移
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static const _dbName = 'deepseek.db';
  static const _dbVersion = 52;
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
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 每次连接建立时开启外键约束。
  ///
  /// SQLite 默认 `PRAGMA foreign_keys = OFF`，**建表时写的 `ON DELETE CASCADE`
  /// 在默认状态下是一条摆设**：删掉大纲记录，`outline_chapters` 里的章节行
  /// 会全部留下变成孤儿（正文 / AI 小结 / 剧情账本一起留在库里）。实测库里
  /// 已有这种残留，且一条 719 章的大纲删掉就是 719 行垃圾。
  ///
  /// 这条 pragma 是**连接级**的（不是持久化设置），所以必须每次开库都设；
  /// 放在 onConfigure 里可以保证它在 onCreate / onUpgrade 之前、且早于任何读写。
  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// 新用户首次安装：创建最新完整表结构（V3+ 含 battle 表）
  static Future<void> _onCreate(Database db, int version) async {
    // ── user_settings 用户配置表（全局单条记录） ──
    await db.execute('''
      CREATE TABLE user_settings (
        id INTEGER PRIMARY KEY,
        model TEXT NOT NULL DEFAULT 'deepseek-flash',
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
        reasoning_effort TEXT NOT NULL DEFAULT 'high',
        stream_include_usage INTEGER NOT NULL DEFAULT 0,
        tool_choice TEXT NOT NULL DEFAULT 'auto',
        safety_check TEXT NOT NULL DEFAULT 'low',
        title_enabled INTEGER NOT NULL DEFAULT 0,
        user_id TEXT NOT NULL DEFAULT '',
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
        search_engine TEXT NOT NULL DEFAULT 'off',
        search_need_content INTEGER NOT NULL DEFAULT 1,
        show_cache_hit INTEGER NOT NULL DEFAULT 1,
        history_query INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ── chat_sessions 会话表（每条记录对应一组独立对话） ──
    // summary_count / context_* 是 DSH 式压缩与缓存命中率展示需要的字段：
    // summary_count 记录摘要覆盖了多少条消息，避免重复摘要；后三个记录上次请求的实测用量。
    await db.execute('''
      CREATE TABLE chat_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        create_time TEXT NOT NULL,
        last_message TEXT NOT NULL DEFAULT '',
        system_prompt TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        summary_count INTEGER NOT NULL DEFAULT 0,
        context_tokens INTEGER NOT NULL DEFAULT 0,
        cached_tokens INTEGER NOT NULL DEFAULT 0,
        context_window INTEGER NOT NULL DEFAULT 0,
        total_prompt_tokens INTEGER NOT NULL DEFAULT 0,
        total_cached_tokens INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ── chat_messages 消息表（关联 session_id） ──
    // prompt/cached/completion tokens 记录「产生这条回答的那次请求」的 usage，
    // 用于在消息菜单里显示该条回答自己的缓存命中率（不随会话累计变化）。
    await db.execute('''
      CREATE TABLE chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        thinking_text TEXT,
        search_results TEXT,
        timestamp TEXT NOT NULL,
        prompt_tokens INTEGER NOT NULL DEFAULT 0,
        cached_tokens INTEGER NOT NULL DEFAULT 0,
        completion_tokens INTEGER NOT NULL DEFAULT 0,
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
        model TEXT NOT NULL DEFAULT 'deepseek-flash',
        system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // 插入默认战斗设置
    await db.insert('battle_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-flash',
      'system_prompt': '',
      'enable_thinking': 1,
    });

    // ── outline_settings 大纲生成设置表（小说模块） ──
    // 仅保留大纲专属列；字数配置已废弃移除，章节相关列已独立到 chapter_settings
    await db.execute('''
      CREATE TABLE outline_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-flash',
        system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1,
        reasoning_effort TEXT NOT NULL DEFAULT 'high',
        pause_after_skeleton INTEGER NOT NULL DEFAULT 0,
        pause_after_events INTEGER NOT NULL DEFAULT 0,
        pause_after_minor INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert('outline_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-flash',
      'system_prompt': '',
      'enable_thinking': 1,
    });

    // ── chapter_settings 章节写作设置表（小说模块，与大纲设置独立） ──
    await db.execute('''
      CREATE TABLE chapter_settings (
        id INTEGER PRIMARY KEY,
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        model TEXT NOT NULL DEFAULT 'deepseek-flash',
        chapter_system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1,
        reasoning_effort TEXT NOT NULL DEFAULT 'high',
        enable_story_state INTEGER NOT NULL DEFAULT 1,
        chapter_min_words INTEGER NOT NULL DEFAULT 2000,
        chapter_max_words INTEGER NOT NULL DEFAULT 3000
      )
    ''');
    await db.insert('chapter_settings', {
      'id': 1,
      'temperature': 0.8,
      'max_tokens': 4096,
      'model': 'deepseek-flash',
      'chapter_system_prompt': '',
      'enable_thinking': 1,
      'reasoning_effort': 'high',
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
        content_backup TEXT NOT NULL DEFAULT '',
        content_backup_at TEXT NOT NULL DEFAULT '',
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
    // ── 小说灵感：会话 / 对话 / 推演分支 / 人物卡 / 设置 ──
    await _createInspirationTables(db);
  }

  /// 小说灵感功能的本地表：全部只在本功能内使用，不参与其它模块。
  static Future<void> _createInspirationTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        world_view TEXT NOT NULL DEFAULT '',
        theme TEXT NOT NULL DEFAULT '',
        outline_record_id INTEGER,
        outline_title TEXT NOT NULL DEFAULT '',
        selected_events TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        revisions TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES inspiration_sessions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_branches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'single',
        chosen INTEGER NOT NULL DEFAULT 0,
        generation_no INTEGER NOT NULL DEFAULT 1,
        source_ids TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES inspiration_sessions(id) ON DELETE CASCADE,
        FOREIGN KEY (message_id) REFERENCES inspiration_messages(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES inspiration_sessions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        personality TEXT NOT NULL DEFAULT '',
        experiences TEXT NOT NULL DEFAULT '',
        skills TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        inject INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES inspiration_sessions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inspiration_settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        model TEXT NOT NULL DEFAULT 'deepseek-flash',
        temperature REAL NOT NULL DEFAULT 0.8,
        max_tokens INTEGER NOT NULL DEFAULT 4096,
        system_prompt TEXT NOT NULL DEFAULT '',
        enable_thinking INTEGER NOT NULL DEFAULT 1,
        reasoning_effort TEXT NOT NULL DEFAULT 'high',
        tts_voice TEXT NOT NULL DEFAULT 'stella',
        tts_engine TEXT NOT NULL DEFAULT 'auto',
        tts_rate REAL NOT NULL DEFAULT 1.0,
        show_scroll_to_bottom INTEGER NOT NULL DEFAULT 1,
        concurrency INTEGER NOT NULL DEFAULT 3
      )
    ''');
    await db.insert('inspiration_settings', {
      'id': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
        await txn.insert(
          'sync_kv',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in data['sync_state'] ?? const <Map<String, Object?>>[]) {
        await txn.insert(
          'sync_state',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
          model TEXT NOT NULL DEFAULT 'deepseek-flash',
          system_prompt TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.insert('battle_settings', {
        'id': 1,
        'temperature': 0.8,
        'max_tokens': 4096,
        'model': 'deepseek-flash',
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
          model TEXT NOT NULL DEFAULT 'deepseek-flash',
          system_prompt TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.insert('outline_settings', {
        'id': 1,
        'temperature': 0.8,
        'max_tokens': 4096,
        'model': 'deepseek-flash',
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
          model TEXT NOT NULL DEFAULT 'deepseek-flash',
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
            'model': s['model'] ?? 'deepseek-flash',
            'chapter_system_prompt': s['chapter_system_prompt'] ?? '',
            'enable_thinking': s['enable_thinking'] ?? 1,
            'enable_story_state': s['enable_story_state'] ?? 1,
          });
        } else {
          await db.insert('chapter_settings', {
            'id': 1,
            'temperature': 0.8,
            'max_tokens': 4096,
            'model': 'deepseek-flash',
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
            model TEXT NOT NULL DEFAULT 'deepseek-flash',
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

    // V34 → V35：outline_records 增加正文的「上一版备份」两列。
    // 大纲正文是整段写回的（编辑页保存 / 生成侧落库），写错一次就再也找不回来：
    // 留一份上一版，至少能回到改动前（见 OutlineRecordDbHelper.update）。
    // 这两列只留在本机（sync_targets.dart 的 kSensitiveColumns），不同步。
    if (oldVersion < 35) {
      final cols = await db.rawQuery('PRAGMA table_info(outline_records)');
      if (cols.isNotEmpty && !cols.any((c) => c['name'] == 'content_backup')) {
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN content_backup TEXT NOT NULL DEFAULT ''",
        );
        await db.execute(
          "ALTER TABLE outline_records ADD COLUMN content_backup_at TEXT NOT NULL DEFAULT ''",
        );
      }
    }

    // V35 → V36：user_settings 增加 search_engine 列（联网搜索来源）。
    //
    // 为什么现在只有 'baidu' 一个可用值：用真 key 实测过 DeepSeek 官方 API，
    // 结论是**官方 API 没有可用的自带联网搜索**，证据如下——
    //   1) /chat/completions 传 tools:[{"type":"web_search"}] → HTTP 422
    //      "unknown variant `web_search`, expected `function`"，只认 function 工具；
    //   2) 顶层 web_search / search / enable_search / search_source 参数 → 200 但被静默忽略；
    //   3) /responses 传 tools:[{"type":"web_search"}] → 200 不报错，但模型自述
    //      "系统没有列出工具"，且带工具与不带工具的回答**完全一致**，实测产出率 0/6；
    //   4) /models 未声明任何搜索能力字段；
    //   5) 网页版 chat.deepseek.com 的联网是私有接口 + 浏览器登录态，API Key 调不通（429）。
    // 早期曾观察到模型吐出 `{"title","url","date","content"}` 形状的搜索结果块，
    // 但那是模型**凭训练记忆编造的**（内容全是旧闻，实跑还会泄漏英文思考过程），
    // 直接采信会让 App 展示伪造的来源链接，比没有搜索更糟。
    // 因此 'deepseek' 值只作预留：等官方开放后无需再动表结构。
    if (oldVersion < 36) {
      final cols = await db.rawQuery('PRAGMA table_info(user_settings)');
      if (cols.isNotEmpty && !cols.any((c) => c['name'] == 'search_engine')) {
        await db.execute(
          "ALTER TABLE user_settings ADD COLUMN search_engine TEXT NOT NULL DEFAULT 'baidu'",
        );
      }
    }

    // V36 → V37：统一模型标识写法（deepseek-v4-flash → deepseek-flash）。
    //
    // 起因：`deepseek-v4-flash` 是早期写死的默认值，但它并不是官方 /models 里的
    // 正式名字（官方正式名是 `deepseek-flash`；`deepseek-v4-pro` 反而是正式名，
    // 写成 `deepseek-pro` 会 400，所以 pro 保持不动）。
    // 这里把库里已有的历史值就地收敛，避免"设置页显示 flash、库里存 v4-flash"
    // 这种表里不一——否则用户改完别的设置一保存，值又跳回去，看着像没生效。
    //
    // 注意 model 只是一个字符串，直接透传给 API，改它不需要动表结构。
    if (oldVersion < 37) {
      const remap = <String, String>{'deepseek-v4-flash': 'deepseek-flash'};
      const tables = <String>[
        'user_settings',
        'battle_settings',
        'outline_settings',
        'chapter_settings',
      ];
      for (final entry in remap.entries) {
        for (final table in tables) {
          try {
            await db.update(
              table,
              {'model': entry.value},
              where: 'model = ?',
              whereArgs: [entry.key],
            );
          } catch (_) {
            // 该库可能还没有这张表（老版本升级路径），跳过即可
          }
        }
      }
      // 说明：小说副本的模型名存在 novel.db 的 copy_table.model_config（JSON 串）里，
      // 属于另一个库、另一套版本号，本迁移不越界处理；且该表通常为空，
      // 其中残留的历史模型名不影响调用（旧名仍是官方别名）。
    }

    // V37 → V38：DeepSeek 官方搜索可用后的两处收口。
    //
    // 背景（2026-10 官方上线 Search / Fetch 接口）：
    //   POST https://api.deepseek.com/v1/tools/search，与对话接口共用同一个
    //   Bearer Key，返回 title/url/snippet/summary/content/date/authority 等字段。
    //   真 Key 实测 200 且有结果，`need_content=true` 时带网页正文。
    //   于是上面 V35→V36 那段"官方 API 没有可用的自带搜索"的结论**已经过时**：
    //   它说的其实是"模型不会自己调用服务端搜索工具"，而这条 Search 接口是
    //   独立工具接口，由 App 自己发请求，绕开了那个限制。
    //
    // 于是这里补两件事：
    //   1) 修 V35→V36 的遗留缺陷：那次加列是一律 `DEFAULT 'baidu'`，把从未开过
    //      联网搜索（web_search=0）的用户也标成了"百度搜索已开启"——而
    //      chat_controller 只认 search_engine，结果是这些人每发一条消息都被
    //      拦下要求填百度 Key。这里按历史布尔量回填真实意图。
    //      能这么回填是因为 setSearchEngine() 一直同步写两列：web_search=0 而
    //      search_engine='baidu' 只可能来自那次加列的默认值，不可能是用户选择。
    //   2) 新增 search_need_content 列（DeepSeek 搜索的 need_content 开关）。
    if (oldVersion < 38) {
      final cols = await db.rawQuery('PRAGMA table_info(user_settings)');
      if (cols.isNotEmpty &&
          !cols.any((c) => c['name'] == 'search_need_content')) {
        await db.execute(
          'ALTER TABLE user_settings '
          "ADD COLUMN search_need_content INTEGER NOT NULL DEFAULT 1",
        );
      }
      await db.rawUpdate(
        "UPDATE user_settings SET search_engine = 'off' "
        "WHERE search_engine = 'baidu' AND web_search = 0",
      );
    }

    // V38→V39：新增「小说灵感」功能表（会话/消息/推演/人物卡/设置）
    if (oldVersion < 39) {
      await _createInspirationTables(db);
    }

    // V39→V40：人物卡新增「人物描述」列
    if (oldVersion < 40) {
      try {
        final cols = await db.rawQuery('PRAGMA table_info(inspiration_cards)');
        if (cols.isNotEmpty && !cols.any((c) => c['name'] == 'description')) {
          await db.execute(
            "ALTER TABLE inspiration_cards ADD COLUMN description TEXT NOT NULL DEFAULT ''",
          );
        }
      } catch (_) {}
    }

    // V40→V41：灵感对话新增「编辑前版本」记录列
    if (oldVersion < 41) {
      try {
        final cols = await db.rawQuery(
          'PRAGMA table_info(inspiration_messages)',
        );
        if (cols.isNotEmpty && !cols.any((c) => c['name'] == 'revisions')) {
          await db.execute(
            "ALTER TABLE inspiration_messages ADD COLUMN revisions TEXT NOT NULL DEFAULT '[]'",
          );
        }
      } catch (_) {}
    }

    // V41→V42：新增「对话模式」聊天消息表
    if (oldVersion < 42) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS inspiration_chat_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES inspiration_sessions(id) ON DELETE CASCADE
          )
        ''');
      } catch (_) {}
    }

    // V42→V43：聊天设置补齐 DeepSeek Chat Completions 官方参数。
    if (oldVersion < 43) {
      final cols = await db.rawQuery('PRAGMA table_info(user_settings)');
      Future<void> addColumn(
        String name,
        String type,
        String defaultValue,
      ) async {
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE user_settings ADD COLUMN $name $type NOT NULL DEFAULT $defaultValue',
          );
        }
      }

      await addColumn('reasoning_effort', 'TEXT', "'high'");
      await addColumn('stream_include_usage', 'INTEGER', '0');
      await addColumn('tool_choice', 'TEXT', "'auto'");
      await addColumn('safety_check', 'TEXT', "'low'");
      await addColumn('title_enabled', 'INTEGER', '0');
      await addColumn('user_id', 'TEXT', "''");
    }

    // V43→V44：大纲/灵感设置补齐思考强度，灵感设置增加 DeepSeek TTS 音色。
    if (oldVersion < 44) {
      Future<void> addTo(
        String table,
        String name,
        String type,
        String def,
      ) async {
        final cols = await db.rawQuery('PRAGMA table_info($table)');
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE $table ADD COLUMN $name $type NOT NULL DEFAULT $def',
          );
        }
      }

      await addTo('outline_settings', 'reasoning_effort', 'TEXT', "'high'");
      await addTo('inspiration_settings', 'reasoning_effort', 'TEXT', "'high'");
      await addTo('inspiration_settings', 'tts_voice', 'TEXT', "'stella'");
    }

    // V44→V45：小说灵感朗读可选择系统/本地引擎，并支持 0.75–5.0x 语速。
    if (oldVersion < 45) {
      Future<void> addTo(
        String table,
        String name,
        String type,
        String def,
      ) async {
        final cols = await db.rawQuery('PRAGMA table_info($table)');
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE $table ADD COLUMN $name $type NOT NULL DEFAULT $def',
          );
        }
      }

      await addTo('inspiration_settings', 'tts_engine', 'TEXT', "'auto'");
      await addTo('inspiration_settings', 'tts_rate', 'REAL', '1.0');
    }

    // V45→V46：小说灵感可关闭「回到底部」悬浮按钮。
    if (oldVersion < 46) {
      final cols = await db.rawQuery('PRAGMA table_info(inspiration_settings)');
      if (!cols.any((c) => c['name'] == 'show_scroll_to_bottom')) {
        await db.execute(
          'ALTER TABLE inspiration_settings ADD COLUMN '
          'show_scroll_to_bottom INTEGER NOT NULL DEFAULT 1',
        );
      }
    }

    // V46→V47：聊天会话增加压缩进度与上下文用量（DSH 式压缩 + 缓存命中率展示）。
    if (oldVersion < 47) {
      final cols = await db.rawQuery('PRAGMA table_info(chat_sessions)');
      Future<void> add(String name, String type, String def) async {
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE chat_sessions ADD COLUMN $name $type NOT NULL DEFAULT $def',
          );
        }
      }

      await add('summary_count', 'INTEGER', '0');
      await add('context_tokens', 'INTEGER', '0');
      await add('cached_tokens', 'INTEGER', '0');
      await add('context_window', 'INTEGER', '0');
    }

    // V47→V48：聊天会话增加累计用量（整体缓存命中率 = Σ命中 / Σ输入）。
    if (oldVersion < 48) {
      final cols = await db.rawQuery('PRAGMA table_info(chat_sessions)');
      Future<void> add(String name) async {
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE chat_sessions ADD COLUMN $name INTEGER NOT NULL DEFAULT 0',
          );
        }
      }

      await add('total_prompt_tokens');
      await add('total_cached_tokens');
    }

    // V48→V49：chat_messages 增加每条回答的 usage（消息级缓存命中率）。
    if (oldVersion < 49) {
      final cols = await db.rawQuery('PRAGMA table_info(chat_messages)');
      Future<void> add(String name) async {
        if (!cols.any((c) => c['name'] == name)) {
          await db.execute(
            'ALTER TABLE chat_messages ADD COLUMN $name INTEGER NOT NULL DEFAULT 0',
          );
        }
      }

      await add('prompt_tokens');
      await add('cached_tokens');
      await add('completion_tokens');
    }

    // V49→V50：user_settings 增加「显示缓存命中」开关（默认开启）。
    if (oldVersion < 50) {
      final cols = await db.rawQuery('PRAGMA table_info(user_settings)');
      if (!cols.any((c) => c['name'] == 'show_cache_hit')) {
        await db.execute(
          'ALTER TABLE user_settings '
          'ADD COLUMN show_cache_hit INTEGER NOT NULL DEFAULT 1',
        );
      }
    }

    // V50→V51：战斗设置增加「思考模式」开关（默认开启）。
    if (oldVersion < 51) {
      final cols = await db.rawQuery('PRAGMA table_info(battle_settings)');
      if (!cols.any((c) => c['name'] == 'enable_thinking')) {
        await db.execute(
          'ALTER TABLE battle_settings '
          'ADD COLUMN enable_thinking INTEGER NOT NULL DEFAULT 1',
        );
      }
    }

    // V51→V52：章节设置增加「思考深度」（大纲编辑 AI 使用，默认 high）。
    if (oldVersion < 52) {
      final cols = await db.rawQuery('PRAGMA table_info(chapter_settings)');
      if (!cols.any((c) => c['name'] == 'reasoning_effort')) {
        await db.execute(
          'ALTER TABLE chapter_settings '
          "ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT 'high'",
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
