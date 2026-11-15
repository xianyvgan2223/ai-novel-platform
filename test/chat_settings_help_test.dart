import 'package:deepseekapp/core/widgets/settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('参数说明默认隐藏，点击 info 图标才显示且不触发开关', (tester) async {
    var toggled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsCard(
            children: [
              SettingsSwitchRow(
                label: 'thinking',
                help: '开启后会先输出思考过程。',
                initialValue: false,
                onChanged: (value) => toggled = value,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开启后会先输出思考过程。'), findsNothing);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.info_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.text('开启后会先输出思考过程。'), findsOneWidget);
    expect(toggled, isFalse);
  });

  testWidgets('下拉参数说明不触发下拉菜单', (tester) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsCard(
            children: [
              SettingsSelectRow(
                label: 'reasoning_effort',
                value: 'high',
                help: '强度说明',
                options: const [
                  SettingsSelectOption('low', 'low'),
                  SettingsSelectOption('high', 'high'),
                ],
                onChanged: (_) => changed = true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.info_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.text('强度说明'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      findsNothing,
    );
    expect(changed, isFalse);
  });
}
