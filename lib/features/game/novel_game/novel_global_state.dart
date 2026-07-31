import 'package:flutter/foundation.dart';

class NovelGlobalState extends ChangeNotifier {
  static final NovelGlobalState _instance = NovelGlobalState._internal();
  factory NovelGlobalState() => _instance;
  NovelGlobalState._internal();

  /// 运行中的副本ID列表
  final List<int> _runningCopyIds = [];

  /// 未读副本计数
  int _unreadCount = 0;

  List<int> get runningCopyIds => List.unmodifiable(_runningCopyIds);
  int get unreadCount => _unreadCount;

  bool isCopyRunning(int copyId) => _runningCopyIds.contains(copyId);

  void addRunningCopy(int copyId) {
    if (!_runningCopyIds.contains(copyId)) {
      _runningCopyIds.add(copyId);
      notifyListeners();
    }
  }

  void removeRunningCopy(int copyId) {
    _runningCopyIds.remove(copyId);
    notifyListeners();
  }

  void setUnreadCount(int count) {
    _unreadCount = count;
    notifyListeners();
  }

  void incrementUnread() {
    _unreadCount++;
    notifyListeners();
  }

  void clearUnread() {
    _unreadCount = 0;
    notifyListeners();
  }
}
