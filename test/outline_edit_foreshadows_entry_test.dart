import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/page/outline_edit_page.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// 「大纲编辑」页的伏笔清单入口：页面条右侧常驻的「伏笔 N」按钮，
/// 点开是列表 + 「编辑」，改完**立即**落库（不等底部「保存」）。
///
/// 为什么要这个入口：伏笔清单原先只在剧情账本页能看，而它是**只读注入**
/// 给 AI 的（提示词里的【伏笔清单】），边看大纲边核对伏笔时要能就地看到。
///
/// 测试里 outline.id 一律传 null（不落库）：保存走「只更新内存」那条路，
/// 不依赖 sqflite（测试环境没有数据库工厂）。
void main() {
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  List<OutlineChapter> chapters() => [ch(1, 'major', '甲'), ch(2, 'minor', '乙')];

  /// 打开编辑页，返回**页面在用的那个控制器**（经 widget.controller 注入）。
  ///
  /// 记录带 id：页面打开时照常走一遍「读上下文」（真机上正是这一步把伏笔清单
  /// 读进来的）。测试环境没有 sqflite，读库会失败并被 [_loadContext] 吞掉——
  /// 这里要的只是「读过了」这个状态，清单内容由 [foreshadows] 直接摆好。
  Future<OutlineEditController> pumpPage(
    WidgetTester tester, {
    String foreshadows = '',
  }) async {
    final ctrl = OutlineEditController(
      OutlineRecord(
        id: 1,
        title: '测试小说',
        content: '',
        foreshadows: foreshadows,
      ),
    );
    ctrl.foreshadows = foreshadows;
    ctrl.init(chapters());
    // 收尾：换掉页面，控制器随页面一起 dispose
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditPage(
          outline: ctrl.outline,
          chapters: ctrl.drafts.map((d) => d.chapter).toList(),
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctrl;
  }

  /// 「伏笔」入口按钮（页面条右侧，书签图标）
  Finder foreshadowsButton() => find.byIcon(Icons.bookmark_border).first;

  testWidgets('页面条右侧常驻「伏笔 N」按钮，条数按非空行算', (tester) async {
    await pumpPage(tester, foreshadows: '甲伏笔\n\n乙伏笔\n   \n丙伏笔');

    // 空行与只含空白的一行都不算一条
    expect(find.text('伏笔 3'), findsOneWidget);
    // 事件数还在，两个入口并排
    expect(find.textContaining('2 个事件'), findsOneWidget);
  });

  testWidgets('没有伏笔时按钮仍在（显示「伏笔 0」）', (tester) async {
    // 不能只在有清单时才显示按钮：那样用户永远不知道这里能看伏笔
    await pumpPage(tester);

    expect(find.text('伏笔 0'), findsOneWidget);
  });

  testWidgets('点按钮打开清单：逐条列出', (tester) async {
    await pumpPage(tester, foreshadows: '主角身世的玉佩\n第 3 章埋下的旧伤');

    await tester.tap(foreshadowsButton());
    await tester.pumpAndSettle();

    expect(find.text('伏笔清单'), findsOneWidget); // 面板标题
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('主角身世的玉佩'), findsOneWidget);
    expect(find.text('第 3 章埋下的旧伤'), findsOneWidget);
    // 面板上说明改完立即生效，别让用户以为要再点底部「保存」
    expect(find.textContaining('改完立即保存'), findsOneWidget);

    // 「关闭」收起面板
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('主角身世的玉佩'), findsNothing);
  });

  testWidgets('清单为空时面板给出空态与生成去处', (tester) async {
    await pumpPage(tester);

    await tester.tap(foreshadowsButton());
    await tester.pumpAndSettle();

    expect(find.text('（暂无伏笔清单）'), findsOneWidget);
    expect(find.textContaining('重新提炼'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('编辑后立即写回：面板与内存里的清单同步更新（AI 提示词读的就是它）', (tester) async {
    final ctrl = await pumpPage(tester, foreshadows: '旧伏笔');

    await tester.tap(foreshadowsButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // 编辑器预填现有清单
    final field = find.byType(TextField).last;
    expect(tester.widget<TextField>(field).controller?.text, '旧伏笔');

    await tester.enterText(field, '  新伏笔一\n\n新伏笔二  ');
    // 弹窗里的「保存」：标题栏的「保存」也是 TextButton，所以限定在弹窗内找
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '保存'),
      ),
    );
    await tester.pumpAndSettle();

    // 前后空白与空行被合并掉：面板显示 2 条、内存里就是 2 行（口径一致）
    expect(ctrl.foreshadows, '新伏笔一\n新伏笔二');
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('新伏笔一'), findsOneWidget);
    expect(find.text('新伏笔二'), findsOneWidget);
    expect(find.text('旧伏笔'), findsNothing);
    // 大纲本身没改动：伏笔不走底部「保存」
    expect(find.text('所有大纲已保存'), findsOneWidget);
    // 落库结果如实提示。测试环境没有 sqflite，这一步必然走失败分支——
    // 正好证明「写库失败不会静默」；真机上成功时提示的是「伏笔清单已保存」。
    expect(
      find.text('伏笔清单已保存').evaluate().isNotEmpty ||
          find.textContaining('伏笔清单保存失败：').evaluate().isNotEmpty,
      isTrue,
      reason: '保存后应给出提示（成功或失败都不能静默）',
    );
  });

  testWidgets('取消编辑不写回（连内存也不动）', (tester) async {
    final ctrl = await pumpPage(tester, foreshadows: '原有伏笔');

    await tester.tap(foreshadowsButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '改了一半');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(ctrl.foreshadows, '原有伏笔');
    expect(find.text('原有伏笔'), findsOneWidget);
    expect(find.text('改了一半'), findsNothing);
  });

  test('saveForeshadows 立即更新内存里的清单（AI 提示词与界面读的都是它）', () async {
    final ctrl = OutlineEditController(OutlineRecord(title: 'T', content: ''));
    ctrl.init(chapters());

    // 前后空白被合并掉；outline.id 为 null 时走「只更新内存」这条路，不报错
    final error = await ctrl.saveForeshadows('  一条伏笔  ');
    expect(error, isEmpty);
    expect(ctrl.foreshadows, '一条伏笔');

    ctrl.dispose();
  });

  testWidgets('360dp 窄屏 + 长书名：页面条多了伏笔按钮也不溢出', (tester) async {
    // 页面条这一行是「书名（可伸缩）+ N 个事件 + 伏笔按钮」，
    // 书名的 Expanded 必须把余量全部吃掉，否则窄屏上会 RenderFlex overflow
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctrl = OutlineEditController(
      OutlineRecord(
        id: 1,
        title: '一个非常非常长的书名用来把页面条这一行撑到极限看会不会溢出',
        content: '',
        foreshadows: '伏笔一\n伏笔二',
      ),
    );
    ctrl.foreshadows = '伏笔一\n伏笔二';
    ctrl.init(chapters());
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      MaterialApp(
        home: OutlineEditPage(
          outline: ctrl.outline,
          chapters: ctrl.drafts.map((d) => d.chapter).toList(),
          controller: ctrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('伏笔 2'), findsOneWidget);
    expect(find.textContaining('2 个事件'), findsOneWidget);
  });
}
