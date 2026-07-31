import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../../../../core/network/api_service.dart';
import '../../../../core/config/user_setting_service.dart';
import '../model/battle_model.dart';
import '../model/db/battle_db_helper.dart';
import '../service/battle_ai_service.dart';

/// AI 写战斗控制器 — 管理生成状态、流式输出、数据库持久化
class BattleController extends ChangeNotifier {
  final ApiService _apiService = ApiService();

  // ── 状态 ──
  bool _isLoading = false;
  String _streamingText = '';
  String _userInput = '';
  CancelToken? _cancelToken;
  List<BattleScene> _history = [];

  // 输入字段拆分
  String _skills = '';
  String _scene = '';
  String _result = '';

  /// 当前正在生成的场景 ID（用于流式更新入库）
  int? _currentSceneId;

  // ── Getter ──
  bool get isLoading => _isLoading;
  String get streamingText => _streamingText;
  String get userInput => _userInput;
  List<BattleScene> get history => _history;
  String get skills => _skills;
  String get scene => _scene;
  String get result => _result;

  // ── 输入更新 ──
  void updateSkills(String v) {
    _skills = v;
    notifyListeners();
  }

  void updateScene(String v) {
    _scene = v;
    notifyListeners();
  }

  void updateResult(String v) {
    _result = v;
    notifyListeners();
  }

  // ── 中断输出 ──
  void cancelRequest() {
    if (!_isLoading || _cancelToken == null) return;
    _cancelToken!.cancel();
    _cancelToken = null;
  }

  // ── 加载历史 ──
  Future<void> loadHistory() async {
    try {
      final rows = await BattleDbHelper().getAllScenes();
      _history = rows.map((r) => BattleScene.fromMap(r)).toList();
      notifyListeners();
    } catch (_) {}
  }

  // ── 仅从界面移除（不删数据库） ──
  void removeFromHistory(int id) {
    _history.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  /// 重置输出状态（完成按钮调用）
  void resetOutput() {
    _streamingText = '';
    _userInput = '';
    _skills = '';
    _scene = '';
    _result = '';
    notifyListeners();
  }

  // ── 从数据库删除历史 ──
  Future<void> deleteScene(int id) async {
    await BattleDbHelper().deleteScene(id);
    _history.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  // ── 更新场景（编辑后保存） ──
  Future<void> saveSceneEdit(int id, Map<String, dynamic> data) async {
    await BattleDbHelper().updateScene(id, data);
    await loadHistory();
  }

  // ── 核心：AI 生成战斗场景 ──
  Future<void> generate() async {
    final allInput = [
      if (_skills.trim().isNotEmpty) '双方人物技能：$_skills',
      if (_scene.trim().isNotEmpty) '战斗场景：$_scene',
      if (_result.trim().isNotEmpty) '战斗结果：$_result',
    ].join('\n');

    if (allInput.trim().isEmpty) return;
    if (_isLoading) return;

    _userInput = allInput;
    _streamingText = '';
    _isLoading = true;
    _currentSceneId = null;
    notifyListeners();

    // ① 从全局设置获取 apiKey
    final globalSetting = await UserSettingService.getSettings();
    if (globalSetting.apiKey.isEmpty) {
      _streamingText = '请先在主设置页面填写 API Key';
      _isLoading = false;
      notifyListeners();
      return;
    }

    // ② 从本地数据库获取战斗设置（温度、最大长度、模型、自定义提示）
    final battleSettings = await _loadBattleSettings();
    final model = battleSettings.model;

    // ③ 保存用户输入到数据库
    try {
      final scene = BattleScene(
        userInput: _userInput,
        characterSkills: _skills,
        battleSceneDesc: _scene,
        battleResult: _result,
        status: BattleStatus.generating,
      );
      _currentSceneId = await BattleDbHelper().insertScene(scene.toMap());
    } catch (_) {}

    // ④ 组装 API 请求
    final apiParams = <String, dynamic>{
      'model': model,
      'temperature': battleSettings.temperature,
      'max_tokens': battleSettings.maxTokens,
      'stream': true,
    };

    final messages = [
      {
        'role': 'system',
        'content': BattleAiService.buildSystemPrompt(
          customPrompt: battleSettings.systemPrompt,
        ),
      },
      {
        'role': 'user',
        'content': BattleAiService.buildUserMessage(
          skills: _skills,
          scene: _scene,
          result: _result,
        ),
      },
    ];

    // ⑤ 发起流式请求
    _cancelToken = CancelToken();
    await _apiService.streamChat(
      apiKey: globalSetting.apiKey,
      apiParams: apiParams,
      messages: messages,
      onChunk: _handleChunk,
      onDone: _handleDone,
      onError: _handleError,
      cancelToken: _cancelToken,
    );
  }

  void _handleChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List?;
    if (choices == null || choices.isEmpty) return;

    final delta = choices[0]['delta'] as Map<String, dynamic>?;
    if (delta == null) return;

    final content = delta['content'];
    if (content != null && content is String && content.isNotEmpty) {
      _streamingText += content;
      notifyListeners();
    }
  }

  Future<void> _handleDone() async {
    // 将流式结果持久化到数据库
    if (_currentSceneId != null && _streamingText.isNotEmpty) {
      try {
        await BattleDbHelper().updateResult(_currentSceneId!, _streamingText);
      } catch (_) {}
    }
    _isLoading = false;
    _cancelToken = null;
    _currentSceneId = null;
    notifyListeners();
    // 刷新历史
    await loadHistory();
  }

  void _handleError(String error) {
    _streamingText = '生成失败：$error';
    _isLoading = false;
    _cancelToken = null;

    // 更新数据库状态为失败
    if (_currentSceneId != null) {
      BattleDbHelper().updateResult(
        _currentSceneId!,
        _streamingText,
        status: 'failed',
      );
    }
    _currentSceneId = null;
    notifyListeners();
  }

  Future<BattleSetting> _loadBattleSettings() async {
    try {
      final row = await BattleDbHelper().getSettings();
      if (row != null) return BattleSetting.fromMap(row);
    } catch (_) {}
    return const BattleSetting();
  }

  @override
  void dispose() {
    cancelRequest();
    super.dispose();
  }
}
