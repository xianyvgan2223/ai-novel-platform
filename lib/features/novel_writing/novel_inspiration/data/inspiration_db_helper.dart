// 小说灵感 — 本地数据访问
//
// 独立表：inspiration_sessions / messages / branches / cards / settings。
// 所有读写只服务本功能，和 outline / chapter 数据互不影响。

import 'package:sqflite/sqflite.dart';
import '../../../../core/db/database_helper.dart';
import '../domain/inspiration_models.dart';

class InspirationDbHelper {
  Future<Database> get database => DatabaseHelper.database;

  // ── 会话 ──────────────────────────────────────────────────

  Future<List<InspirationSession>> listSessions() async {
    final db = await database;
    final rows = await db.query(
      'inspiration_sessions',
      orderBy: 'updated_at DESC',
    );
    return rows.map(InspirationSession.fromMap).toList();
  }

  Future<InspirationSession?> getSession(int id) async {
    final db = await database;
    final rows = await db.query(
      'inspiration_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return InspirationSession.fromMap(rows.first);
  }

  Future<int> insertSession(InspirationSession session) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.insert('inspiration_sessions', {
      ...session.toMap(),
      'created_at': session.createdAt.isEmpty ? now : session.createdAt,
      'updated_at': now,
    });
  }

  Future<void> updateSession(InspirationSession session) async {
    final id = session.id;
    if (id == null) return;
    final db = await database;
    await db.update(
      'inspiration_sessions',
      {...session.toMap(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> touchSession(int id) async {
    final db = await database;
    await db.update(
      'inspiration_sessions',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteSession(int id) async {
    final db = await database;
    await db.delete('inspiration_sessions', where: 'id = ?', whereArgs: [id]);
  }

  // ── 消息 / 推演 ────────────────────────────────────────────

  Future<List<InspirationMessage>> listMessages(int sessionId) async {
    final db = await database;
    final msgRows = await db.query(
      'inspiration_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    if (msgRows.isEmpty) return const [];
    final branchRows = await db.query(
      'inspiration_branches',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    final grouped = <int, List<InspirationBranch>>{};
    for (final row in branchRows) {
      final branch = InspirationBranch.fromMap(row);
      grouped.putIfAbsent(branch.messageId, () => []).add(branch);
    }
    return msgRows.map((row) {
      final msg = InspirationMessage(
        id: row['id'] as int?,
        sessionId: row['session_id'] as int? ?? sessionId,
        content: row['content'] as String? ?? '',
        createdAt: row['created_at'] as String? ?? '',
        revisions: InspirationMessageRevision.decodeList(
          row['revisions'] as String? ?? '[]',
        ),
      );
      final branches = grouped[msg.id] ?? const <InspirationBranch>[];
      return msg.copyWith(branches: branches);
    }).toList();
  }

  Future<int> insertMessage(int sessionId, String content) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.insert('inspiration_messages', {
      'session_id': sessionId,
      'content': content,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> deleteMessage(int id) async {
    final db = await database;
    await db.delete('inspiration_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateMessageContent(int id, String content) async {
    final db = await database;
    await db.update(
      'inspiration_messages',
      {'content': content, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 修改对话：保存新指令，同时写入「编辑前版本」快照。
  Future<void> updateMessageEdit(
    int id,
    String content,
    List<InspirationMessageRevision> revisions,
  ) async {
    final db = await database;
    await db.update(
      'inspiration_messages',
      {
        'content': content,
        'revisions': InspirationMessageRevision.encodeList(revisions),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertBranch(InspirationBranch branch) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    await db.insert('inspiration_branches', {
      ...branch.toMap(),
      'created_at': branch.createdAt.isEmpty ? now : branch.createdAt,
      'updated_at': now,
    });
  }

  Future<void> updateBranchContent(int id, String content) async {
    final db = await database;
    await db.update(
      'inspiration_branches',
      {'content': content, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setChosen(int messageId, int? branchId) async {
    final db = await database;
    await db.update(
      'inspiration_branches',
      {'chosen': 0},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    if (branchId != null) {
      await db.update(
        'inspiration_branches',
        {'chosen': 1},
        where: 'id = ?',
        whereArgs: [branchId],
      );
    }
  }

  Future<void> deleteBranch(int id) async {
    final db = await database;
    await db.delete('inspiration_branches', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> maxGenerationNo(int messageId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT MAX(generation_no) AS n FROM inspiration_branches WHERE message_id = ?',
      [messageId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<List<InspirationBranch>> listBranches(int messageId) async {
    final db = await database;
    final rows = await db.query(
      'inspiration_branches',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'id ASC',
    );
    return rows.map(InspirationBranch.fromMap).toList();
  }

  // ── 对话模式消息 ───────────────────────────────────────────

  Future<List<InspirationChatMessage>> listChatMessages(int sessionId) async {
    final db = await database;
    final rows = await db.query(
      'inspiration_chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(InspirationChatMessage.fromMap).toList();
  }

  Future<int> insertChatMessage({
    required int sessionId,
    required String role,
    required String content,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.insert('inspiration_chat_messages', {
      'session_id': sessionId,
      'role': role,
      'content': content,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> updateChatMessage(int id, String content) async {
    final db = await database;
    await db.update(
      'inspiration_chat_messages',
      {'content': content, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除某条消息之后的所有对话消息（编辑对话时完全分离旧下文）。
  Future<void> deleteChatMessagesAfter(int sessionId, int messageId) async {
    final db = await database;
    await db.delete(
      'inspiration_chat_messages',
      where: 'session_id = ? AND id > ?',
      whereArgs: [sessionId, messageId],
    );
  }

  Future<void> deleteChatMessage(int id) async {
    final db = await database;
    await db.delete(
      'inspiration_chat_messages',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── 人物卡 ─────────────────────────────────────────────────

  Future<List<InspirationCharacterCard>> listCards(int sessionId) async {
    final db = await database;
    final rows = await db.query(
      'inspiration_cards',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(InspirationCharacterCard.fromMap).toList();
  }

  Future<int> insertCard(InspirationCharacterCard card) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return db.insert('inspiration_cards', {
      ...card.toMap(),
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> updateCard(InspirationCharacterCard card) async {
    final id = card.id;
    if (id == null) return;
    final db = await database;
    await db.update(
      'inspiration_cards',
      {...card.toMap(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteCard(int id) async {
    final db = await database;
    await db.delete('inspiration_cards', where: 'id = ?', whereArgs: [id]);
  }

  // ── 设置 ───────────────────────────────────────────────────

  Future<InspirationSettings> getSettings() async {
    final db = await database;
    final rows = await db.query(
      'inspiration_settings',
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) {
      await db.insert('inspiration_settings', {
        'id': 1,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return const InspirationSettings();
    }
    return InspirationSettings.fromMap(rows.first);
  }

  Future<void> saveSettings(InspirationSettings settings) async {
    final db = await database;
    await db.update('inspiration_settings', settings.toMap(), where: 'id = 1');
  }
}
