// lib/game/character_chat/data/world_info_service.dart
// 世界书服务 — 关键词匹配的知识条目注入

import '../../../services/database_helper.dart';

class WorldInfoEntry {
  final int? id;
  final int sessionId;
  final String title;
  final String content;
  final List<String> keywords;
  final bool enabled;
  final DateTime createdAt;

  const WorldInfoEntry({
    this.id,
    required this.sessionId,
    required this.title,
    required this.content,
    this.keywords = const [],
    this.enabled = true,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'session_id': sessionId,
    'title': title,
    'content': content,
    'keywords': keywords.join(','),
    'enabled': enabled ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory WorldInfoEntry.fromMap(Map<String, dynamic> map) => WorldInfoEntry(
    id: map['id'] as int?,
    sessionId: map['session_id'] as int? ?? 0,
    title: map['title'] as String? ?? '',
    content: map['content'] as String? ?? '',
    keywords: (map['keywords'] as String? ?? '').split(',').where((k) => k.isNotEmpty).toList(),
    enabled: (map['enabled'] as int?) == 1,
    createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
  );
}

class WorldInfoService {
  /// 创建世界书条目
  static Future<int> createEntry(WorldInfoEntry entry) async {
    final db = await DatabaseHelper.database;
    return db.insert('world_info_entries', entry.toMap());
  }

  /// 获取会话的所有世界书条目
  static Future<List<WorldInfoEntry>> getEntries(int sessionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'world_info_entries',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => WorldInfoEntry.fromMap(r)).toList();
  }

  /// 删除世界书条目
  static Future<void> deleteEntry(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete('world_info_entries', where: 'id = ?', whereArgs: [id]);
  }

  /// 匹配关键词并返回匹配的世界书内容
  static String matchContent(List<WorldInfoEntry> entries, String text) {
    final matched = <String>[];
    for (final entry in entries) {
      if (!entry.enabled) continue;
      for (final keyword in entry.keywords) {
        if (keyword.isNotEmpty && text.contains(keyword)) {
          matched.add('[${entry.title}]\n${entry.content}');
          break;
        }
      }
    }
    if (matched.isEmpty) return '';
    return '\n\n相关背景知识：\n${matched.join('\n\n')}';
  }
}
