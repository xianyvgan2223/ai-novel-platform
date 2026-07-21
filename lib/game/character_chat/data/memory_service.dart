// lib/game/character_chat/data/memory_service.dart
// 记忆系统服务 — 关键信息提取、存储、注入

import '../../../services/database_helper.dart';

class MemoryItem {
  final int? id;
  final int sessionId;
  final String content;
  final String category;
  final int importance;
  final DateTime createdAt;

  const MemoryItem({
    this.id,
    required this.sessionId,
    required this.content,
    this.category = 'general',
    this.importance = 1,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'session_id': sessionId,
    'content': content,
    'category': category,
    'importance': importance,
    'created_at': createdAt.toIso8601String(),
  };

  factory MemoryItem.fromMap(Map<String, dynamic> map) => MemoryItem(
    id: map['id'] as int?,
    sessionId: map['session_id'] as int? ?? 0,
    content: map['content'] as String? ?? '',
    category: map['category'] as String? ?? 'general',
    importance: map['importance'] as int? ?? 1,
    createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

class MemoryService {
  /// 保存一条记忆
  static Future<void> saveMemory(MemoryItem memory) async {
    final db = await DatabaseHelper.database;
    await db.insert('character_memories', memory.toMap());
  }

  /// 获取会话的所有记忆（按重要性排序）
  static Future<List<MemoryItem>> getMemories(int sessionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_memories',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'importance DESC, created_at DESC',
      limit: 50,
    );
    return rows.map((r) => MemoryItem.fromMap(r)).toList();
  }

  /// 获取重要记忆（重要性 >= 2），注入 prompt 使用
  static Future<List<MemoryItem>> getImportantMemories(int sessionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'character_memories',
      where: 'session_id = ? AND importance >= ?',
      whereArgs: [sessionId, 2],
      orderBy: 'created_at DESC',
      limit: 10,
    );
    return rows.map((r) => MemoryItem.fromMap(r)).toList();
  }

  /// 构建记忆文本块，用于注入 prompt
  static Future<String> buildMemoryBlock(int sessionId) async {
    final memories = await getImportantMemories(sessionId);
    if (memories.isEmpty) return '';
    final lines = memories.map((m) => '- ${m.content}');
    return '\n\n[长期记忆]\n${lines.join('\n')}';
  }

  /// 删除会话的所有记忆
  static Future<void> deleteMemories(int sessionId) async {
    final db = await DatabaseHelper.database;
    await db.delete('character_memories', where: 'session_id = ?', whereArgs: [sessionId]);
  }
}
