/// lib/services/chat_message_service.dart
/// chat_messages 消息表 CRUD 服务 — 按 session_id 存取消息

import 'dart:convert';

import '../models/chat_message.dart';
import 'database_helper.dart';

class ChatMessageService {
  /// 保存单条消息到数据库，返回带 id 的消息
  static Future<ChatMessage> insertMessage(
    ChatMessage message,
    int sessionId,
  ) async {
    final db = await DatabaseHelper.database;
    final row = <String, dynamic>{
      'session_id': sessionId,
      'role': message.isUser ? 'user' : 'assistant',
      'content': message.content,
      'thinking_text': message.thinkingText,
      'timestamp': message.timestamp,
    };
    if (message.searchResults != null) {
      row['search_results'] = jsonEncode(message.searchResults);
    }
    final id = await db.insert('chat_messages', row);
    return message.copyWith(id: id);
  }

  /// 读取指定会话的全部消息，按时间正序
  static Future<List<ChatMessage>> getMessagesBySession(int sessionId) async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return results.map((row) => _fromRow(row)).toList();
  }

  /// 按会话 ID 删除全部消息
  static Future<int> deleteMessagesBySession(int sessionId) async {
    final db = await DatabaseHelper.database;
    return db.delete(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 搜索当前会话中的历史消息（对话历史查询工具用）
  /// [sessionId] 当前会话 ID
  /// [keyword] 搜索关键词，匹配 content 字段
  /// [limit] 返回条数上限
  static Future<List<ChatMessage>> searchMessages(
    int sessionId, {
    required String keyword,
    int limit = 10,
  }) async {
    final db = await DatabaseHelper.database;
    final results = await db.query(
      'chat_messages',
      where: 'session_id = ? AND content LIKE ?',
      whereArgs: [sessionId, '%$keyword%'],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
    return results.map((row) => _fromRow(row)).toList();
  }

  /// 按 ID 列表批量删除消息
  static Future<void> deleteMessagesByIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await DatabaseHelper.database;
    final placeholders = ids.map((_) => '?').join(',');
    await db.delete(
      'chat_messages',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// 数据库行 → ChatMessage 实体
  static ChatMessage _fromRow(Map<String, dynamic> row) {
    final id = row['id'] as int?;
    final roleStr = row['role'] as String? ?? 'user';
    List<Map<String, dynamic>>? searchResults;
    final searchStr = row['search_results'] as String?;
    if (searchStr != null && searchStr.isNotEmpty) {
      final decoded = jsonDecode(searchStr);
      if (decoded is List) {
        searchResults = decoded.cast<Map<String, dynamic>>();
      }
    }
    return ChatMessage(
      id: id,
      role: roleStr == 'assistant' ? MessageRole.assistant : MessageRole.user,
      content: row['content'] as String? ?? '',
      thinkingText: row['thinking_text'] as String?,
      timestamp: row['timestamp'] as String? ?? '',
      searchResults: searchResults,
    );
  }
}
