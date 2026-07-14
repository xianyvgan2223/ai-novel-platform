/// lib/services/chat_session_service.dart
/// chat_sessions 会话表 CRUD 服务

import '../models/chat_session.dart';
import 'database_helper.dart';

class ChatSessionService {
  /// 查询全部会话，按创建时间倒序
  static Future<List<ChatSession>> getAllSessions() async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'chat_sessions',
      orderBy: 'create_time DESC',
    );
    return results.map((r) => ChatSession.fromMap(r)).toList();
  }

  /// 插入一条新会话，返回自增 id
  static Future<int> insertSession(ChatSession session) async {
    final db = await DatabaseHelper.database;
    final map = session.toMap();
    map.remove('id'); // 自增列不传
    return db.insert('chat_sessions', map);
  }

  /// 更新会话（主要用于更新 last_message 或 system_prompt）
  static Future<int> updateSession(ChatSession session) async {
    final db = await DatabaseHelper.database;
    return db.update(
      'chat_sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  /// 按 id 删除会话（同时清理关联消息，替代外键 CASCADE）
  static Future<void> deleteSession(int id) async {
    final db = await DatabaseHelper.database;
    // 先删消息，再删会话
    await db.delete('chat_messages', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
  }
}
