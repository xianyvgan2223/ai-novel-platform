/// lib/features/sync/data/sync_targets.dart
///
/// 参与同步的表清单。
///
/// 注意：**数组顺序就是依赖顺序（父表在前）**。
/// 拉取到的变更必须按这个顺序落库，否则子表先写入会违反外键约束。
library;

/// 一张参与同步的表
class SyncTarget {
  /// 所属数据库：'deepseek' 或 'novel'
  final String db;

  /// 表名
  final String table;

  /// 中文名（用于界面展示）
  final String label;

  const SyncTarget(this.db, this.table, this.label);
}

/// 同步范围：App 里所有会变动的业务表
const List<SyncTarget> kSyncTargets = <SyncTarget>[
  // ───────────── deepseek.db ─────────────
  SyncTarget('deepseek', 'user_settings', '全局设置'),
  SyncTarget('deepseek', 'chat_sessions', '对话会话'),
  SyncTarget('deepseek', 'chat_messages', '对话消息'),
  SyncTarget('deepseek', 'battle_settings', '战斗设置'),
  SyncTarget('deepseek', 'battle_scenes', '战斗场景'),
  SyncTarget('deepseek', 'outline_settings', '大纲设置'),
  SyncTarget('deepseek', 'chapter_settings', '章节设置'),
  SyncTarget('deepseek', 'outline_records', '大纲 / 作品'),
  SyncTarget('deepseek', 'outline_chapters', '章节'),
  SyncTarget('deepseek', 'character_chat_sessions', '角色扮演会话'),
  SyncTarget('deepseek', 'character_tags', '角色标签'),
  SyncTarget('deepseek', 'character_chat_messages', '角色扮演消息'),
  SyncTarget('deepseek', 'world_info_entries', '世界书条目'),
  SyncTarget('deepseek', 'character_memories', '角色记忆'),
  SyncTarget('deepseek', 'trpg_campaigns', '跑团战役'),
  SyncTarget('deepseek', 'trpg_characters', '跑团角色卡'),
  SyncTarget('deepseek', 'trpg_messages', '跑团日志'),

  // ────────────── novel.db ──────────────
  SyncTarget('novel', 'copy_table', '副本'),
  SyncTarget('novel', 'character_table', '角色'),
  SyncTarget('novel', 'skill_table', '技能'),
  SyncTarget('novel', 'equipment_table', '装备'),
  SyncTarget('novel', 'character_intersection_table', '角色交集'),
  SyncTarget('novel', 'copy_record_table', '副本记录'),
  SyncTarget('novel', 'char_copy_story_table', '角色副本剧情'),
];

/// 敏感列：只留在本机 —— 既不上传，也不会被服务端的数据覆盖。
/// （API Key 没必要同步到网页，也避免导出时泄露）
const Map<String, List<String>> kSensitiveColumns = <String, List<String>>{
  'user_settings': <String>['apiKey', 'baidu_api_key'],
};

/// 取某表需要跳过的列
List<String> sensitiveColumnsOf(String table) =>
    kSensitiveColumns[table] ?? const <String>[];

/// 表在同步顺序中的位置，越小越靠前；未知表排在最后
int syncRankOf(String db, String table) {
  for (var i = 0; i < kSyncTargets.length; i++) {
    final t = kSyncTargets[i];
    if (t.db == db && t.table == table) return i;
  }
  return kSyncTargets.length;
}

/// 按 (db, table) 查中文名
String syncLabelOf(String db, String table) {
  for (final t in kSyncTargets) {
    if (t.db == db && t.table == table) return t.label;
  }
  return table;
}
