import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/view/widget/outline_settings_edit_sheet.dart';

/// 「大纲编辑 · 选择事件」页右上角的「小说设定」弹层：
/// 预填当前书名 / 类型 / 主题 / 主角简介 / 世界观，保存后把草稿返回给页面落库。
void main() {
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              // 结果由各用例自己 await；这里只为把弹层挂出来
              showOutlineSettingsEditSheet(
                context,
                initial: const OutlineSettingsDraft(
                  title: '旧书名',
                  genre: '玄幻',
                  theme: '成长',
                  protagonist: '顾泽',
                  worldview: '九域',
                ),
              );
            },
            child: const Text('打开设定'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设定'));
    await tester.pumpAndSettle();
  }

  testWidgets('预填当前设定；改书名与世界观后保存返回新值', (tester) async {
    OutlineSettingsDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showOutlineSettingsEditSheet(
                context,
                initial: const OutlineSettingsDraft(
                  title: '旧书名',
                  genre: '玄幻',
                  theme: '成长',
                  protagonist: '顾泽',
                  worldview: '九域',
                ),
              );
            },
            child: const Text('打开设定'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设定'));
    await tester.pumpAndSettle();

    expect(find.text('小说设定'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '旧书名');
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, '玄幻');
    expect(tester.widget<TextField>(fields.at(2)).controller?.text, '成长');
    expect(tester.widget<TextField>(fields.at(3)).controller?.text, '顾泽');
    expect(tester.widget<TextField>(fields.at(4)).controller?.text, '九域');

    await tester.enterText(fields.at(0), '新书名');
    await tester.enterText(fields.at(4), '新世界观');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('小说设定'), findsNothing); // 弹层已关闭
    expect(result, isNotNull);
    expect(result!.title, '新书名');
    expect(result!.genre, '玄幻');
    expect(result!.theme, '成长');
    expect(result!.protagonist, '顾泽');
    expect(result!.worldview, '新世界观');
  });

  testWidgets('取消返回 null', (tester) async {
    OutlineSettingsDraft? result = const OutlineSettingsDraft(
      title: '未点击',
      genre: '',
      theme: '',
      protagonist: '',
      worldview: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showOutlineSettingsEditSheet(
                context,
                initial: const OutlineSettingsDraft(
                  title: '旧书名',
                  genre: '玄幻',
                  theme: '成长',
                  protagonist: '顾泽',
                  worldview: '九域',
                ),
              );
            },
            child: const Text('打开设定'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设定'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('小说设定'), findsNothing);
    expect(result, isNull);
  });

  testWidgets('点右上角关闭按钮也返回 null', (tester) async {
    OutlineSettingsDraft? result = const OutlineSettingsDraft(
      title: '未点击',
      genre: '',
      theme: '',
      protagonist: '',
      worldview: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showOutlineSettingsEditSheet(
                context,
                initial: const OutlineSettingsDraft(
                  title: '旧书名',
                  genre: '玄幻',
                  theme: '成长',
                  protagonist: '顾泽',
                  worldview: '九域',
                ),
              );
            },
            child: const Text('打开设定'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设定'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  // 保留一个占位：openSheet 供后续需要复用"只打开"的场景（避免被分析器判未使用）
  testWidgets('打开后可见五个输入框与保存按钮', (tester) async {
    await openSheet(tester);
    expect(find.byType(TextField), findsNWidgets(5));
    expect(find.widgetWithText(ElevatedButton, '保存'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '取消'), findsOneWidget);
  });
}
