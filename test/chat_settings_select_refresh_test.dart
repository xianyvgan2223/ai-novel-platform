import 'package:deepseekapp/features/chat/application/setting_controller.dart';
import 'package:deepseekapp/features/chat/presentation/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSettingController extends SettingController {
  String _effort = 'high';

  @override
  bool get isLoaded => true;

  @override
  Future<void> loadSettings() async {}

  @override
  String get reasoningEffort => _effort;

  @override
  void setReasoningEffort(String v) {
    _effort = v;
    notifyListeners();
  }
}

void main() {
  testWidgets('聊天设置的下拉值选择后立即刷新显示', (tester) async {
    final fake = _FakeSettingController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingProvider.overrideWith((ref) => fake)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.text('reasoning_effort');
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('max · 最深'), findsOneWidget);
    await tester.tap(find.text('max · 最深'));
    await tester.pumpAndSettle();

    // 设置页只订阅了少量字段；如果 reasoningEffort 没被 watch，
    // 这里仍会显示旧的 high，正是用户反馈的“选了不刷新”。
    expect(fake.reasoningEffort, 'max');
    expect(find.text('max · 最深'), findsOneWidget);
  });
}
