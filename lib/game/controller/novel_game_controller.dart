import 'package:flutter/material.dart';
import '../model/entity/copy_entity.dart';
import '../model/entity/character_entity.dart';
import '../model/repo/copy_repository.dart';
import '../model/repo/character_repository.dart';
import '../model/ai/copy_ai_service.dart';
import '../novel_global_state.dart';
import '../view/widget/novel_dialogs.dart';
import '../view/page/copy_history_page.dart';

class NovelGameController extends ChangeNotifier {
  final CopyRepository _copyRepo = CopyRepository();
  final CharacterRepository _charRepo = CharacterRepository();
  final NovelGlobalState _globalState = NovelGlobalState();
  final CopyAiService _aiService = CopyAiService();

  List<CopyEntity> _copies = [];
  List<CharacterEntity> _characters = [];

  /// 副本中的人物关联，key: copyId, value: characterId列表
  final Map<int, List<int>> _copyCharacterIds = {};

  List<CopyEntity> get copies => List.unmodifiable(_copies);
  List<CharacterEntity> get characters => List.unmodifiable(_characters);
  NovelGlobalState get globalState => _globalState;

  /// 第一个运行中的副本（用于底部提示）
  CopyEntity? get runningCopy {
    try {
      return _copies.firstWhere((c) => c.isRunning == 1);
    } catch (_) {
      return null;
    }
  }

  /// 未读副本计数
  int get unreadRecordCount => _copies.where((c) => c.unreadRecord == 1).length;

  /// 获取指定副本中的人物列表
  List<CharacterEntity> getCharactersForCopy(int copyId) {
    final charIds = _copyCharacterIds[copyId] ?? [];
    return _characters
        .where((c) => c.id != null && charIds.contains(c.id))
        .toList();
  }

  /// 从数据库加载所有副本和人物 (需要 try-catch 外部处理)
  Future<void> loadData() async {
    _copies = await _copyRepo.getCopies();
    _characters = await _charRepo.getCharacters();
    _loadCopyCharacterBindings();
  }

  void _loadCopyCharacterBindings() {
    _copyCharacterIds.clear();
    for (final copy in _copies) {
      _copyCharacterIds.putIfAbsent(copy.id ?? 0, () => []);
    }
  }

  /// 显示创建副本弹窗，返回 true 表示成功创建
  Future<bool> showCreateCopyDialog(BuildContext context) async {
    try {
      final result = await showDialog<Map<String, String>>(
        context: context,
        useSafeArea: false,
        builder: (_) => const CreateCopyDialog(),
      );
      if (result != null) {
        await _doCreateCopy(result);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('showCreateCopyDialog error: $e');
      return false;
    }
  }

  Future<void> _doCreateCopy(Map<String, String> info) async {
    final name = info['name']!.trim();
    final setting = info['setting'] ?? '';
    final style = info['style'] ?? '默认';

    String? modelConfig;
    if (setting.isNotEmpty || style != '默认') {
      final map = <String, dynamic>{};
      if (setting.isNotEmpty) map['background'] = setting;
      if (style != '默认') map['style'] = style;
      modelConfig = _encodeModelConfig(map);
    }

    final id = await _copyRepo.createCopy(name, modelConfig: modelConfig);
    final copy = CopyEntity(
      id: id,
      copyName: name,
      modelConfig: modelConfig,
      createTime: DateTime.now().millisecondsSinceEpoch,
    );
    _copies.insert(0, copy);
    _copyCharacterIds[copy.id!] = [];
    notifyListeners();
  }

  String _encodeModelConfig(Map<String, dynamic> config) {
    // 简单 JSON 序列化，不使用 dart:convert 以外的方法
    final parts = <String>[];
    config.forEach((key, value) {
      parts.add('"$key":"${value.toString().replaceAll('"', '\\"')}"');
    });
    return '{${parts.join(',')}}';
  }

  /// 显示创建人物弹窗，返回 true 表示成功创建
  Future<bool> showCreateCharacterDialog(BuildContext context) async {
    try {
      final result = await showDialog<Map<String, String>>(
        context: context,
        useSafeArea: false,
        builder: (_) => const CreateCharacterDialog(),
      );
      if (result != null) {
        await _doCreateCharacter(result['name']!, result['desc'] ?? '');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('showCreateCharacterDialog error: $e');
      return false;
    }
  }

  Future<void> _doCreateCharacter(String name, String desc) async {
    final id = await _charRepo.createCharacter(name.trim(), desc.trim());
    final character = CharacterEntity(
      id: id,
      charName: name.trim(),
      baseDesc: desc.trim().isEmpty ? null : desc.trim(),
      createTime: DateTime.now().millisecondsSinceEpoch,
    );
    _characters.insert(0, character);
    notifyListeners();
  }

  /// 将人物添加到副本
  Future<void> addCharacterToCopy(int copyId, int charId) async {
    final list = _copyCharacterIds.putIfAbsent(copyId, () => []);
    if (list.contains(charId)) return;
    list.add(charId);
    notifyListeners();
  }

  /// 启动副本
  Future<void> startCopy(CopyEntity copy) async {
    final copyId = copy.id ?? 0;
    final charIds = _copyCharacterIds[copyId] ?? [];
    if (charIds.isEmpty) return;

    // 标记副本运行中
    copy.isRunning = 1;
    await _copyRepo.updateCopy(copy);
    _globalState.addRunningCopy(copyId);
    notifyListeners();

    try {
      // 获取副本关联的角色
      final characters = _characters
          .where((c) => charIds.contains(c.id))
          .toList();

      // 解析 modelConfig 获取背景和风格
      String? background;
      String? style;
      if (copy.modelConfig != null && copy.modelConfig!.isNotEmpty) {
        final config = _parseModelConfig(copy.modelConfig!);
        background = config['background'];
        style = config['style'];
      }

      // 调用 AI 生成副本总故事
      final result = await _aiService.generateCopyTotalStory(
        characters,
        copy.copyName,
        background: background,
        style: style,
      );

      final totalStory = result['totalStory'] as String? ?? '';
      final intersectionTexts =
          result['intersectionTexts'] as List<dynamic>? ?? [];

      if (totalStory.isNotEmpty) {
        // 保存副本总故事到 copy_record_table
        await _copyRepo.saveCopyRecord(copyId, totalStory);
      }

      // 处理角色交集
      for (final inter in intersectionTexts) {
        if (inter is Map<String, dynamic>) {
          final nameA = inter['char_a_name'] as String?;
          final nameB = inter['char_b_name'] as String?;
          final desc = inter['desc'] as String? ?? '';
          if (nameA != null && nameB != null) {
            // 找到对应角色 ID
            final charA = characters
                .where((c) => c.charName == nameA)
                .firstOrNull;
            final charB = characters
                .where((c) => c.charName == nameB)
                .firstOrNull;
            if (charA?.id != null &&
                charB?.id != null &&
                charA!.id != charB!.id) {
              await _charRepo.saveIntersection(charA.id!, charB.id!, desc);
            }
          }
        }
      }

      // 为每个角色生成单人故事
      for (final char in characters) {
        final charInfo = '角色名: ${char.charName}, 基础设定: ${char.baseDesc ?? "无"}';
        final singleResult = await _aiService.generateSingleCharacterStory(
          charInfo,
          totalStory,
        );

        final singleStory = singleResult['singleStory'] as String? ?? '';
        final skills = singleResult['skills'] as List<dynamic>? ?? [];
        final equipment = singleResult['equipment'] as List<dynamic>? ?? [];

        // 保存单人故事
        if (singleStory.isNotEmpty && char.id != null) {
          await _copyRepo.saveCharCopyStory(copyId, char.id!, singleStory);
        }

        // 保存技能
        for (final sk in skills) {
          if (sk is Map<String, dynamic>) {
            await _charRepo.saveSkill(
              char.id ?? 0,
              sk['name'] as String? ?? '',
              sk['desc'] as String? ?? '',
              copyId,
            );
          }
        }

        // 保存装备
        for (final eq in equipment) {
          if (eq is Map<String, dynamic>) {
            await _charRepo.saveEquipment(
              char.id ?? 0,
              eq['name'] as String? ?? '',
              eq['attr'] as String? ?? '',
              copyId,
            );
          }
        }
      }

      // 副本完成
      copy.isRunning = 0;
      copy.unreadRecord = 1;
      await _copyRepo.updateCopy(copy);
      _globalState.removeRunningCopy(copyId);
      _globalState.incrementUnread();
      notifyListeners();
    } catch (e) {
      debugPrint('startCopy error: $e');
      copy.isRunning = 0;
      await _copyRepo.updateCopy(copy);
      _globalState.removeRunningCopy(copyId);
      notifyListeners();
      rethrow;
    }
  }

  /// 简单解析 modelConfig JSON key-value
  Map<String, String> _parseModelConfig(String json) {
    try {
      final cleaned = json.trim();
      if (cleaned.startsWith('{') && cleaned.endsWith('}')) {
        final inner = cleaned.substring(1, cleaned.length - 1);
        final map = <String, String>{};
        int depth = 0;
        int start = 0;
        for (int i = 0; i < inner.length; i++) {
          if (inner[i] == '{') depth++;
          if (inner[i] == '}') depth--;
          if (inner[i] == ',' && depth == 0) {
            _parseKv(inner.substring(start, i), map);
            start = i + 1;
          }
        }
        if (start < inner.length) _parseKv(inner.substring(start), map);
        return map;
      }
    } catch (_) {}
    return {};
  }

  void _parseKv(String s, Map<String, String> map) {
    final idx = s.indexOf(':');
    if (idx > 0) {
      final key = s.substring(0, idx).trim().replaceAll('"', '');
      final value = s.substring(idx + 1).trim().replaceAll('"', '');
      if (key.isNotEmpty) map[key] = value;
    }
  }

  /// 删除副本
  Future<void> deleteCopy(int id) async {
    await _copyRepo.deleteCopy(id);
    _copies.removeWhere((c) => c.id == id);
    _copyCharacterIds.remove(id);
    notifyListeners();
  }

  /// 删除人物
  Future<void> deleteCharacter(int id) async {
    await _charRepo.deleteCharacter(id);
    _characters.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  /// 导航到人物编辑页
  void navigateToCharacterEdit(int characterId) {}

  /// 导航到副本历史页
  void navigateToCopyHistory(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => CopyHistoryPage(copies: _copies)));
  }
}
