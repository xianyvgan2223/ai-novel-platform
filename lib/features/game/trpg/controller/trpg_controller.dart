// lib/game/trpg/controller/trpg_controller.dart
// 跑团模拟器主控制器 — 对话流 + 本地骰子判定 + 状态变更

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../../core/network/api_service.dart';
import '../../../../core/config/user_setting_service.dart';
import '../model/character_sheet.dart';
import '../model/dice.dart';
import '../model/dm_response.dart';
import '../data/trpg_db_service.dart';
import '../data/trpg_ai_service.dart';

class TrpgController extends ChangeNotifier {
  final TrpgAiService _aiService;

  // ── 核心状态 ──
  TrpgCampaign? _campaign;
  CharacterSheet? _character;
  List<TrpgMessage> _messages = [];
  bool _isLoading = false;
  String? _error;
  String? _apiKey;
  CancelToken? _cancelToken;

  /// 待处理的判定请求（AI 返回 need_check 后，等待玩家掷骰）
  CheckInfo? _pendingCheck;

  TrpgController({ApiService? apiService, TrpgAiService? aiService})
    : _aiService = aiService ?? TrpgAiService(apiService: apiService);

  // ── Getters ──
  TrpgCampaign? get campaign => _campaign;
  CharacterSheet? get character => _character;
  List<TrpgMessage> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  String? get error => _error;
  CheckInfo? get pendingCheck => _pendingCheck;

  // ── 加载与创建 ──

  Future<void> loadCampaign(int id) async {
    try {
      final campaign = await TrpgDbService.getCampaign(id);
      if (campaign == null) {
        _error = '战役不存在';
        notifyListeners();
        return;
      }
      _campaign = campaign;
      _character = await TrpgDbService.getPlayerCharacter(id);
      _messages = await TrpgDbService.getMessages(id);
      _pendingCheck = null;
      _error = null;
      await _loadApiKey();
    } catch (e) {
      _error = '加载战役失败: $e';
    }
    notifyListeners();
  }

  Future<int> createCampaign({
    required String name,
    String dmPrompt = '',
  }) async {
    final now = DateTime.now();
    final campaign = TrpgCampaign(
      name: name.trim(),
      dmPrompt: dmPrompt.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final id = await TrpgDbService.createCampaign(campaign);
    _campaign = TrpgCampaign(
      id: id,
      name: name.trim(),
      dmPrompt: dmPrompt.trim(),
      createdAt: now,
      updatedAt: now,
    );
    _character = null;
    _messages = [];
    _pendingCheck = null;
    _error = null;
    await _loadApiKey();
    notifyListeners();
    return id;
  }

  /// 保存玩家角色卡并绑定到当前战役
  Future<void> setPlayerCharacter(CharacterSheet sheet) async {
    final campaignId = _campaign?.id;
    if (campaignId == null) {
      _error = '请先创建战役';
      notifyListeners();
      return;
    }
    final savedId = await TrpgDbService.saveCharacter(
      CharacterSheet(
        id: sheet.id,
        campaignId: campaignId,
        name: sheet.name,
        race: sheet.race,
        charClass: sheet.charClass,
        level: sheet.level,
        str: sheet.str,
        dex: sheet.dex,
        con: sheet.con,
        intl: sheet.intl,
        wis: sheet.wis,
        cha: sheet.cha,
        maxHp: sheet.maxHp,
        currentHp: sheet.currentHp,
        armorBonus: sheet.armorBonus,
        skilledSkills: sheet.skilledSkills,
        inventory: sheet.inventory,
        background: sheet.background,
        isPlayer: true,
      ),
    );
    _character = CharacterSheet(
      id: savedId,
      campaignId: campaignId,
      name: sheet.name,
      race: sheet.race,
      charClass: sheet.charClass,
      level: sheet.level,
      str: sheet.str,
      dex: sheet.dex,
      con: sheet.con,
      intl: sheet.intl,
      wis: sheet.wis,
      cha: sheet.cha,
      maxHp: sheet.maxHp,
      currentHp: sheet.currentHp,
      armorBonus: sheet.armorBonus,
      skilledSkills: sheet.skilledSkills,
      inventory: sheet.inventory,
      background: sheet.background,
      isPlayer: true,
    );
    notifyListeners();
  }

  Future<void> deleteCampaign(int id) async {
    await TrpgDbService.deleteCampaign(id);
    if (_campaign?.id == id) {
      reset();
    }
  }

  Future<void> _loadApiKey() async {
    try {
      final settings = await UserSettingService.getSettings();
      _apiKey = settings.apiKey;
      if (_apiKey == null || _apiKey!.isEmpty) {
        _error = '请先在设置中配置 API Key';
      }
    } catch (e) {
      _error = '读取配置失败: $e';
    }
  }

  // ── 对话交互 ──

  /// 玩家发起行动（自由文本或选项）
  Future<void> sendAction(String text) async {
    if (text.trim().isEmpty || _isLoading || _character == null) return;
    if (_apiKey == null || _apiKey!.isEmpty) {
      _error = '请先在设置中配置 API Key';
      notifyListeners();
      return;
    }

    _messages = [
      ..._messages,
      TrpgMessage(
        campaignId: _campaign!.id!,
        isUser: true,
        content: text.trim(),
        timestamp: DateTime.now(),
      ),
    ];
    _error = null;
    notifyListeners();
    await _requestDm();
  }

  /// 对当前待判定项进行本地骰子判定，并把结果交给 DM
  Future<void> rollCheck() async {
    final check = _pendingCheck;
    final character = _character;
    if (check == null || character == null || _isLoading) return;

    // 本地掷骰：d20 + 属性调整 + （熟练则加熟练加值）
    final d20 = Dice.d20();
    final bonus = check.skill != null
        ? character.skillBonus(check.type, check.skill!)
        : character.abilityModifier(check.type);
    final total = d20 + bonus;
    final success = total >= check.dc;

    final skillName = check.skill != null
        ? CharacterSheet.skillLabels[check.skill] ?? check.skill!
        : CharacterSheet.abilityLabels[check.type] ?? check.type;
    final abilityName = CharacterSheet.abilityLabels[check.type] ?? check.type;

    final resultText =
        '[判定结果] $abilityName($skillName)检定：d20=$d20 ${bonus >= 0 ? '+' : ''}$bonus = $total，DC ${check.dc} → ${success ? '成功' : '失败'}';

    _messages = [
      ..._messages,
      TrpgMessage(
        campaignId: _campaign!.id!,
        isUser: true,
        content: resultText,
        meta: {
          'roll': {
            'd20': d20,
            'bonus': bonus,
            'total': total,
            'dc': check.dc,
            'success': success,
            'ability': check.type,
            'skill': check.skill,
          },
        },
        timestamp: DateTime.now(),
      ),
    ];
    _pendingCheck = null;
    notifyListeners();
    await _requestDm();
  }

  Future<void> _requestDm() async {
    if (_character == null || _apiKey == null || _campaign == null) return;

    _isLoading = true;
    _cancelToken = CancelToken();
    _error = null;
    notifyListeners();

    try {
      final settings = await UserSettingService.getSettings();
      final apiParams = settings.toApiParams();

      final response = await _aiService.generate(
        apiKey: _apiKey!,
        apiParams: apiParams,
        messages: _buildContextMessages(),
        cancelToken: _cancelToken,
      );

      // 追加 DM 叙事
      _messages = [
        ..._messages,
        TrpgMessage(
          campaignId: _campaign!.id!,
          isUser: false,
          content: response.displayText,
          meta: response.needCheck
              ? {
                  'need_check': true,
                  'check': {
                    'type': response.check?.type,
                    'skill': response.check?.skill,
                    'dc': response.check?.dc,
                    'description': response.check?.description,
                  },
                }
              : {},
          timestamp: DateTime.now(),
        ),
      ];

      if (response.needCheck && response.check != null) {
        _pendingCheck = response.check;
      } else {
        _applyStateChanges(response.stateChanges, response.sceneUpdate);
      }

      await _persist();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        _isLoading = false;
        notifyListeners();
        return;
      }
      _isLoading = false;
      _error = 'AI 请求失败: $e';
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _buildContextMessages() {
    final system = TrpgAiService.buildSystemPrompt(
      _character!,
      scene: _campaign?.scene ?? '',
      flags: _campaign?.flags ?? const {},
    );
    final result = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];

    // 限制上下文窗口，避免超长
    const maxHistory = 20;
    final history = _messages.length > maxHistory
        ? _messages.sublist(_messages.length - maxHistory)
        : _messages;
    result.addAll(
      history.map(
        (m) => {'role': m.isUser ? 'user' : 'assistant', 'content': m.content},
      ),
    );
    return result;
  }

  void _applyStateChanges(StateChanges changes, String sceneUpdate) {
    if (_character != null && changes.hpDelta != 0) {
      final newHp = (_character!.currentHp + changes.hpDelta).clamp(
        0,
        _character!.maxHp,
      );
      _character = CharacterSheet(
        id: _character!.id,
        campaignId: _character!.campaignId,
        name: _character!.name,
        race: _character!.race,
        charClass: _character!.charClass,
        level: _character!.level,
        str: _character!.str,
        dex: _character!.dex,
        con: _character!.con,
        intl: _character!.intl,
        wis: _character!.wis,
        cha: _character!.cha,
        maxHp: _character!.maxHp,
        currentHp: newHp,
        armorBonus: _character!.armorBonus,
        skilledSkills: _character!.skilledSkills,
        inventory: _character!.inventory,
        background: _character!.background,
        isPlayer: _character!.isPlayer,
      );
    }

    if (changes.addFlags.isNotEmpty || changes.addItems.isNotEmpty) {
      final flags = Map<String, String>.from(_campaign?.flags ?? {});
      for (final f in changes.addFlags) {
        if (f.isNotEmpty) flags[f] = 'true';
      }

      if (_character != null && changes.addItems.isNotEmpty) {
        final items = List<String>.from(_character!.inventory);
        for (final item in changes.addItems) {
          if (item.isNotEmpty && !items.contains(item)) items.add(item);
        }
        _character = CharacterSheet(
          id: _character!.id,
          campaignId: _character!.campaignId,
          name: _character!.name,
          race: _character!.race,
          charClass: _character!.charClass,
          level: _character!.level,
          str: _character!.str,
          dex: _character!.dex,
          con: _character!.con,
          intl: _character!.intl,
          wis: _character!.wis,
          cha: _character!.cha,
          maxHp: _character!.maxHp,
          currentHp: _character!.currentHp,
          armorBonus: _character!.armorBonus,
          skilledSkills: _character!.skilledSkills,
          inventory: items,
          background: _character!.background,
          isPlayer: _character!.isPlayer,
        );
      }

      _campaign = TrpgCampaign(
        id: _campaign!.id,
        name: _campaign!.name,
        dmPrompt: _campaign!.dmPrompt,
        scene: _campaign!.scene,
        flags: flags,
        summary: _campaign!.summary,
        createdAt: _campaign!.createdAt,
        updatedAt: _campaign!.updatedAt,
      );
    }

    if (sceneUpdate.isNotEmpty) {
      _campaign = TrpgCampaign(
        id: _campaign!.id,
        name: _campaign!.name,
        dmPrompt: _campaign!.dmPrompt,
        scene: sceneUpdate,
        flags: _campaign!.flags,
        summary: _campaign!.summary,
        createdAt: _campaign!.createdAt,
        updatedAt: _campaign!.updatedAt,
      );
    }
  }

  Future<void> _persist() async {
    final campaignId = _campaign?.id;
    if (campaignId == null) return;
    try {
      if (_character != null) {
        await TrpgDbService.saveCharacter(_character!);
      }
      if (_campaign != null) {
        await TrpgDbService.updateCampaign(_campaign!);
      }
      await TrpgDbService.deleteMessages(campaignId);
      await TrpgDbService.saveMessages(campaignId, _messages);
    } catch (e) {
      debugPrint('持久化失败: $e');
    }
  }

  // ── 工具 ──

  void cancelRequest() {
    _cancelToken?.cancel();
    _isLoading = false;
    notifyListeners();
  }

  void reset() {
    _cancelToken?.cancel();
    _campaign = null;
    _character = null;
    _messages = [];
    _error = null;
    _apiKey = null;
    _pendingCheck = null;
    _isLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }
}
