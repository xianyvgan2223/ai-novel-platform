// lib/game/trpg/data/trpg_db_service.dart
// 跑团模拟器持久化服务 — 战役 / 角色卡 / 消息 CRUD

import 'dart:convert';
import '../../../../core/db/database_helper.dart';
import '../model/character_sheet.dart';

/// 跑团战役（存档）
class TrpgCampaign {
  final int? id;
  final String name;
  final String dmPrompt;
  final String scene;
  final Map<String, String> flags;
  final String summary;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TrpgCampaign({
    this.id,
    required this.name,
    this.dmPrompt = '',
    this.scene = '',
    this.flags = const {},
    this.summary = '',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'dm_prompt': dmPrompt,
    'scene': scene,
    'flags': jsonEncode(flags),
    'summary': summary,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory TrpgCampaign.fromMap(Map<String, dynamic> map) {
    Map<String, String> parseFlags(String raw) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {
        return <String, String>{};
      }
    }

    return TrpgCampaign(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      dmPrompt: map['dm_prompt'] as String? ?? '',
      scene: map['scene'] as String? ?? '',
      flags: parseFlags(map['flags'] as String? ?? '{}'),
      summary: map['summary'] as String? ?? '',
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 跑团叙事/对话消息
class TrpgMessage {
  final int? id;
  final int campaignId;
  final bool isUser;
  final String content;
  final Map<String, dynamic> meta;
  final DateTime timestamp;

  const TrpgMessage({
    this.id,
    required this.campaignId,
    required this.isUser,
    required this.content,
    this.meta = const {},
    required this.timestamp,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'campaign_id': campaignId,
    'is_user': isUser ? 1 : 0,
    'content': content,
    'meta': jsonEncode(meta),
    'timestamp': timestamp.toIso8601String(),
  };

  factory TrpgMessage.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> parseMeta(String raw) {
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    return TrpgMessage(
      id: map['id'] as int?,
      campaignId: map['campaign_id'] as int? ?? 0,
      isUser: (map['is_user'] as int?) == 1,
      content: map['content'] as String? ?? '',
      meta: parseMeta(map['meta'] as String? ?? '{}'),
      timestamp:
          DateTime.tryParse(map['timestamp'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class TrpgDbService {
  // ── 战役 ──

  static Future<int> createCampaign(TrpgCampaign campaign) async {
    final db = await DatabaseHelper.database;
    return db.insert('trpg_campaigns', campaign.toMap());
  }

  static Future<List<TrpgCampaign>> getCampaigns() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('trpg_campaigns', orderBy: 'updated_at DESC');
    return rows.map((r) => TrpgCampaign.fromMap(r)).toList();
  }

  static Future<TrpgCampaign?> getCampaign(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'trpg_campaigns',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TrpgCampaign.fromMap(rows.first);
  }

  static Future<void> updateCampaign(TrpgCampaign campaign) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'trpg_campaigns',
      campaign.toMap(),
      where: 'id = ?',
      whereArgs: [campaign.id],
    );
  }

  static Future<void> touchCampaign(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'trpg_campaigns',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteCampaign(int id) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'trpg_characters',
      where: 'campaign_id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'trpg_messages',
      where: 'campaign_id = ?',
      whereArgs: [id],
    );
    await db.delete('trpg_campaigns', where: 'id = ?', whereArgs: [id]);
  }

  // ── 角色卡 ──

  static Future<int> saveCharacter(CharacterSheet sheet) async {
    final db = await DatabaseHelper.database;
    if (sheet.id != null) {
      await db.update(
        'trpg_characters',
        sheet.toMap(),
        where: 'id = ?',
        whereArgs: [sheet.id],
      );
      return sheet.id!;
    }
    return db.insert('trpg_characters', sheet.toMap());
  }

  /// 获取指定战役的玩家角色卡
  static Future<CharacterSheet?> getPlayerCharacter(int campaignId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'trpg_characters',
      where: 'campaign_id = ? AND is_player = 1',
      whereArgs: [campaignId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CharacterSheet.fromMap(rows.first);
  }

  static Future<List<CharacterSheet>> getCharacters(int campaignId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'trpg_characters',
      where: 'campaign_id = ?',
      whereArgs: [campaignId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => CharacterSheet.fromMap(r)).toList();
  }

  // ── 消息 ──

  static Future<void> saveMessages(
    int campaignId,
    List<TrpgMessage> messages,
  ) async {
    final db = await DatabaseHelper.database;
    final batch = db.batch();
    for (final msg in messages) {
      batch.insert('trpg_messages', msg.toMap());
    }
    await batch.commit(noResult: true);
  }

  static Future<List<TrpgMessage>> getMessages(int campaignId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'trpg_messages',
      where: 'campaign_id = ?',
      whereArgs: [campaignId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => TrpgMessage.fromMap(r)).toList();
  }

  static Future<void> deleteMessages(int campaignId) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'trpg_messages',
      where: 'campaign_id = ?',
      whereArgs: [campaignId],
    );
  }
}
