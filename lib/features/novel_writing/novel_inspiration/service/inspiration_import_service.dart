// 小说灵感 — 从已有大纲导入设定 / 人物资料
//
// 只读大纲数据，不修改大纲；人物描述优先取大纲「人物档案」里的对应角色，
// 没有档案时回退到大纲的主角简介。

import 'dart:convert';

import '../../shared/domain/character_profile.dart';
import '../../shared/data/outline_record_db_helper.dart';

class InspirationOutlineBrief {
  final int id;
  final String title;
  final String theme;
  final String worldview;
  final String protagonist;

  const InspirationOutlineBrief({
    required this.id,
    required this.title,
    this.theme = '',
    this.worldview = '',
    this.protagonist = '',
  });
}

class InspirationCharacterOption {
  final String name;
  final String description;
  final String abilities;
  final String personality;

  const InspirationCharacterOption({
    this.name = '',
    this.description = '',
    this.abilities = '',
    this.personality = '',
  });

  bool get useful =>
      name.trim().isNotEmpty ||
      description.trim().isNotEmpty ||
      abilities.trim().isNotEmpty;
}

class InspirationImportService {
  final OutlineRecordDbHelper _records = OutlineRecordDbHelper();

  Future<List<InspirationOutlineBrief>> loadOutlines() async {
    final rows = await _records.getAllSummaries();
    return rows
        .map(
          (row) => InspirationOutlineBrief(
            id: row['id'] as int? ?? 0,
            title: row['title'] as String? ?? '',
            theme: row['theme'] as String? ?? '',
            worldview: row['worldview'] as String? ?? '',
            protagonist: row['protagonist'] as String? ?? '',
          ),
        )
        .where((o) => o.id > 0)
        .toList();
  }

  /// 读取某部大纲可用于人物描述的内容：人物档案优先，否则回退主角简介。
  Future<List<InspirationCharacterOption>> loadCharacterOptions(
    int outlineId,
  ) async {
    final map = await _records.getById(outlineId);
    if (map == null) return const [];
    final options = <InspirationCharacterOption>[];
    final raw = map['characters'] as String? ?? '';
    if (raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded.whereType<Map<String, dynamic>>()) {
            final c = CharacterProfile.fromJson(item);
            final option = InspirationCharacterOption(
              name: c.name,
              description: c.description,
              abilities: c.abilities,
              personality: c.personality,
            );
            if (option.useful) options.add(option);
          }
        }
      } catch (_) {}
    }
    if (options.isEmpty) {
      final protagonist = map['protagonist'] as String? ?? '';
      if (protagonist.trim().isNotEmpty) {
        options.add(
          InspirationCharacterOption(
            name: '主角',
            description: protagonist.trim(),
          ),
        );
      }
    }
    return options;
  }
}
