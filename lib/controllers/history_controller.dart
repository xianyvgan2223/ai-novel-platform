/// lib/controllers/history_controller.dart
/// 历史会话控制器 — 管理会话列表的加载、新建、删除
/// 基于 ChangeNotifier + Riverpod 暴露全局状态

import 'package:flutter/foundation.dart';
import '../models/chat_session.dart';
import '../services/chat_session_service.dart';

class HistoryController extends ChangeNotifier {
  List<ChatSession> _sessions = [];
  bool _loaded = false;

  List<ChatSession> get sessions => _sessions;
  bool get isLoaded => _loaded;

  /// 从数据库加载全部会话
  Future<void> loadSessions() async {
    try {
      _sessions = await ChatSessionService.getAllSessions();
    } catch (_) {
      _sessions = [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// 新建空白会话并返回其 id
  Future<int?> createSession() async {
    final newSession = ChatSession(
      title: '新对话',
      createTime: DateTime.now().toIso8601String(),
    );
    final id = await ChatSessionService.insertSession(newSession);
    await loadSessions();
    return id;
  }

  /// 删除指定会话
  Future<void> deleteSession(int id) async {
    await ChatSessionService.deleteSession(id);
    await loadSessions();
  }
}
