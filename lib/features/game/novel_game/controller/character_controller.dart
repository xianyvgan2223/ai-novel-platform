import 'package:flutter/foundation.dart';

class CharacterController extends ChangeNotifier {
  /// 当前选中的角色ID
  int? _selectedCharacterId;

  /// 是否正在拖拽
  bool _isDragging = false;

  int? get selectedCharacterId => _selectedCharacterId;
  bool get isDragging => _isDragging;
  bool get hasSelection => _selectedCharacterId != null;

  void selectCharacter(int charId) {
    _selectedCharacterId = charId;
    notifyListeners();
  }

  void deselectCharacter() {
    _selectedCharacterId = null;
    notifyListeners();
  }

  void setDragging(bool value) {
    _isDragging = value;
    notifyListeners();
  }

  void toggleCharacter(int charId) {
    if (_selectedCharacterId == charId) {
      deselectCharacter();
    } else {
      selectCharacter(charId);
    }
  }
}
