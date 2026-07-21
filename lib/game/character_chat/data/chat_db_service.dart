// lib/game/character_chat/data/chat_db_service.dart
// 角色扮演对话持久化服务 — 会话与消息的 CRUD

import '../../../services/database_helper.dart';
import '../model/character_model.dart';
import '../controller/chat_controller.dart' show ChatMessage;

/// 角色扮演会话记录
class CharacterChatSession {
  final int? id;
  final String characterName;
  final String description;
  final String personality;
  final String scenario;
  final String systemPrompt;
  final String summary;
  final DateTime createdAt;
  final DateTime updatedAt;

  const CharacterChatSession({
    this.id,
    required this.characterName,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.systemPrompt = '',
    this.summary = '',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'character_name': characterName,
    'description': description,
    'personality': personality,
    'scenario': scenario,
    'system_prompt': systemPrompt,
    'summary': summary,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory CharacterChatSession.fromMap(
    Map<String, dynamic> map,
  ) => CharacterChatSession(
    id: map['id'] as int?,
    characterName: map['character_name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    personality: map['personality'] as String? ?? '',
    scenario: map['scenario'] as String? ?? '',
    systemPrompt: map['system_prompt'] as String? ?? '',
    summary: map['summary'] as String? ?? '',
    createdAt:
        DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
  );

  /// 从角色模型构建会话记录
  factory CharacterChatSession.fromCharacter(
    CharacterModel character, {
    int? id,
  }) => CharacterChatSession(
    id: id,
    characterName: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    systemPrompt: character.systemPrompt ?? '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// 还原为角色模型
  CharacterModel toCharacter() => CharacterModel(
    name: characterName,
    description: description,
    personality: personality,
    scenario: scenario,
    systemPrompt: systemPrompt.isEmpty ? null : systemPrompt,
    firstMes: '',
    tags: const [],
  );
}

class CharacterChatDbService {
  /// 创建新会话
  static Future<int> createSession(CharacterChatSession session) async {
    final db = await DatabaseHelper.database;
    return db.insert('character_chat_sessions', session.toMap());
  }

  /// 获取所有会话（按更新时间倒序）
  static Future<List<CharacterChatSession>> getAllSessions() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_chat_sessions',
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) => CharacterChatSession.fromMap(r)).toList();
  }

  /// 根据 id 获取单个会话
  static Future<CharacterChatSession?> getSession(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_chat_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CharacterChatSession.fromMap(rows.first);
  }

  /// 更新会话时间戳
  static Future<void> touchSession(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'character_chat_sessions',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除会话及其所有消息
  static Future<void> deleteSession(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'character_chat_messages',
      where: 'session_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'character_chat_sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 批量保存消息（插入到数据库）
  static Future<void> saveMessages(
    int sessionId,
    List<ChatMessage> messages,
  ) async {
    final db = await DatabaseHelper.database;
    final batch = db.batch();

    for (final msg in messages) {
      batch.insert('character_chat_messages', {
        'session_id': sessionId,
        'is_user': msg.isUser ? 1 : 0,
        'content': msg.content,
        'timestamp': msg.timestamp.toIso8601String(),
      });
    }

    await batch.commit(noResult: true);
  }

  /// 获取会话的消息列表
  static Future<List<ChatMessage>> getMessages(int sessionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map((r) {
      return ChatMessage(
        isUser: (r['is_user'] as int?) == 1,
        content: r['content'] as String? ?? '',
        timestamp:
            DateTime.tryParse(r['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
    }).toList();
  }

  /// 删除会话的所有消息（用于重新保存）
  static Future<void> deleteMessages(int sessionId) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'character_chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }
}
