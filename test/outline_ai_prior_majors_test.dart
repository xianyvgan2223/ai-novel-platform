import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import 'package:deepseekapp/features/novel_writing/outline_editing/view/widget/outline_ai_chat_sheet.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_chapter.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/outline_record.dart';

/// AI 面板上的两个大事件注入开关：
/// - 「注入之前所有大事件」：默认关闭，打开后只注入**当前事件之前**的大事件
///   （按时间先后），之后的一律不注入；与【所属大事件】【前一事件】
///   【同批所选事件】的重叠不重复注入
/// - 「注入下一个大事件」：默认关闭，打开后把当前事件之后第一个大事件整段注入，
///   它已在【后续事件】里出现时不重复注入
void main() {
  /// 8 个事件的测试大纲：
  /// 大事件A(1) / 甲(2) / 大事件B(3) / 乙(4) / 丙(5) / 大事件C(6) / 丁(7) / 大事件D(8)
  OutlineChapter ch(int id, String type, String title) => OutlineChapter(
    id: id,
    outlineId: 1,
    eventIndex: id,
    eventType: type,
    eventTitle: title,
    eventSummary: '$title 的概要',
  );

  List<OutlineChapter> chapters() => [
    ch(1, 'major', '大事件A'),
    ch(2, 'minor', '甲'),
    ch(3, 'major', '大事件B'),
    ch(4, 'minor', '乙'),
    ch(5, 'minor', '丙'),
    ch(6, 'major', '大事件C'),
    ch(7, 'minor', '丁'),
    ch(8, 'major', '大事件D'),
  ];

  /// [target] 是「AI 生成」的目标事件在 [chapters] 里的下标（默认「丙」，第 5 个）
  OutlineEditController makeController({int target = 4}) {
    final ctrl = OutlineEditController(OutlineRecord(title: 'T', content: ''));
    ctrl.init(chapters());
    ctrl.setAiTarget(target);
    return ctrl;
  }

  /// 系统提示词里【某栏目】的内容：栏目那一行（值可能就写在同一行，如
  /// 「【当前事件】章节 · 丙」）加上随后到**下一个栏目**为止的正文行。
  /// 只按栏目名切段、不把空行当分隔——正文里的换行与空行都要保留。
  /// 系统提示词里所有栏目的名字（按 buildSystemPrompt 里的顺序）。
  ///
  /// 不能拿「以【开头」当栏目判断：正文行本身也长这样
  /// （`【大事件】大事件C：…` / `【章节】甲：…`），会被误当成新栏目把上一节截断。
  const sectionNames = <String>[
    '小说设定',
    '当前事件',
    '当前事件概要',
    '所属大事件',
    '之前所有大事件',
    '同批所选事件',
    '前一事件',
    '后续事件',
    '下一个大事件',
    '已写章节的剧情状态',
    '伏笔清单',
  ];

  /// 提示词里属于某个栏目的行
  bool isSectionLine(String trimmed) => sectionNames.any(
    (n) => trimmed == '【$n】' || trimmed.startsWith('【$n】'),
  );

  /// 系统提示词里【某栏目】的内容：栏目那一行（值可能就写在同一行，如
  /// 「【当前事件】章节 · 丙」）加上随后到**下一个栏目**为止的正文行。
  String section(String prompt, String name) {
    final header = '【$name】';
    final out = <String>[];
    var inside = false;
    for (final line in prompt.split('\n')) {
      final t = line.trim();
      if (isSectionLine(t)) {
        if (inside) break; // 到了下一个栏目
        inside = t.startsWith(header);
        if (!inside) continue;
        final same = t.substring(header.length).trim();
        if (same.isNotEmpty) out.add(same);
        continue;
      }
      if (inside && t.isNotEmpty) out.add(t);
    }
    return out.join('\n');
  }

  /// 提示词里同一行出现几次（检查「不重复注入」）
  int countLine(String text, String needle) {
    return text
        .split('\n')
        .where((l) => l.trim().startsWith(needle))
        .length;
  }

  group('控制器注入口径', () {
    test('默认关闭：提示词里没有【之前所有大事件】这一节', () {
      final ctrl = makeController();
      expect(ctrl.injectPriorMajors, isFalse);
      expect(ctrl.aiPriorMajorsText, isEmpty);
      expect(ctrl.aiPriorMajorsCount, 0);
    });

    test('打开后只注入当前事件之前的两个大事件，按时间先后排列', () {
      final ctrl = makeController(); // 目标是「丙」(第 5 个)
      ctrl.setInjectPriorMajors(true);

      // 前面的两个大事件：A、B；后面的大事件 C 不在里面（它就在丙之后）
      expect(ctrl.aiPriorMajorsText, '大事件A：大事件A 的概要\n大事件B：大事件B 的概要');
      expect(ctrl.aiPriorMajorsCount, 2);
    });

    test('目标是大事件时：不含自己，也不含之后的大事件', () {
      final ctrl = makeController(
        target: 5, // 大事件C
      );
      ctrl.setInjectPriorMajors(true);

      expect(ctrl.aiPriorMajorsText, '大事件A：大事件A 的概要\n大事件B：大事件B 的概要');
      expect(ctrl.aiPriorMajorsText.contains('大事件C'), isFalse);
    });

    test('目标是第一个大事件时：没有可注入项，提示词里不出现该栏目', () {
      final ctrl = makeController(target: 0); // 大事件A
      ctrl.setInjectPriorMajors(true);

      expect(ctrl.aiPriorMajorsText, isEmpty);
      expect(ctrl.aiPriorMajorsCount, 0);
    });

    test('同一份内容不重复：已在【之前所有大事件】里的不再注第二遍', () {
      final ctrl = makeController(); // 「丙」
      ctrl.setInjectPriorMajors(true);
      // 同批所选事件也开着：B 已在【之前所有大事件】里，不该再列一遍
      ctrl.setInjectSelectedEvents(true);

      final selected = ctrl.aiSelectedEventsText;
      // 所属大事件 B（也是「前一事件」会取到的那一条）不重复
      expect(countLine(selected, '【大事件】大事件B'), 0);
      // 【前一事件】只给最近两条非大事件：乙、丙；这两条已在里面，也不重复
      expect(countLine(selected, '【章节】乙'), 0);
      expect(countLine(selected, '【章节】丙'), 0);
      // 当前事件自己不该出现在「同批所选」里
      expect(selected, isNot(contains('【章节】丙')));
      // B 之下、丙之前的更早小事件照常注入
      expect(countLine(selected, '【章节】甲'), 1);
      // 注：后面的大事件若也被用户勾选了，仍会由「同批所选事件」带上——
      // 那是用户自己勾的，与本节「只注入之前」的规则不是一回事。
    });

    test('【之前所有大事件】段里绝不出现当前事件及之后的大事件', () {
      for (final target in [0, 1, 4, 5, 7]) {
        final ctrl = makeController(target: target);
        ctrl.setInjectPriorMajors(true);
        final body = ctrl.aiPriorMajorsText;
        final current = ctrl.aiTargetDraft!;
        // 目标之后的大事件一个都不能有
        for (final c in chapters()) {
          if (!c.isMajor || c.eventIndex <= current.eventIndex) continue;
          expect(
            body.contains(c.eventTitle),
            isFalse,
            reason: 'target=${current.title} 时不该注入后面的 ${c.eventTitle}',
          );
        }
        // 注入了的那几个都必须在当前事件之前，且按时间先后排列
        var lastAt = -1;
        for (final c in chapters()) {
          if (!c.isMajor || c.eventIndex >= current.eventIndex) continue;
          final at = body.indexOf(c.eventTitle);
          expect(at, greaterThan(lastAt), reason: '${c.eventTitle} 应按时间先后出现');
          lastAt = at;
        }
      }
    });

    test('注入的整段上下文里，每个大事件只出现一次', () {
      final ctrl = makeController();
      ctrl.setInjectPriorMajors(true);
      ctrl.setInjectSelectedEvents(true);

      final prior = ctrl.aiPriorMajorsText;
      final selected = ctrl.aiSelectedEventsText;
      for (final title in ['大事件A', '大事件B']) {
        expect(
          countLine(prior, title) + countLine(selected, title),
          1,
          reason: '$title 在注入内容里应恰好出现一次',
        );
      }
    });

    test('组装出的系统提示词包含该栏目与前置大事件，且不含后续大事件', () {
      final ctrl = makeController();
      ctrl.setInjectPriorMajors(true);
      final draft = ctrl.aiTargetDraft!;

      final messages = ctrl.service.buildChatMessages(
        outline: ctrl.outline,
        eventTitle: draft.title,
        eventSummary: draft.summary,
        isMajor: draft.isMajor,
        userInput: '写一下这节',
        parentMajor: ctrl.aiParentMajorText,
        priorMajors: ctrl.aiPriorMajorsText,
        prevEvents: ctrl.aiPrevEventsText,
        nextEvents: ctrl.aiNextEventsText,
      );
      final system = messages.first['content'] as String;

      final body = section(system, '之前所有大事件');
      // 栏目名后面那句括注是给模型看的说明，正文按时间先后列出前置大事件
      expect(body, contains('大事件A：大事件A 的概要'));
      expect(body, contains('大事件B：大事件B 的概要'));
      expect(
        body.indexOf('大事件A'),
        lessThan(body.indexOf('大事件B')),
        reason: '按时间先后排列',
      );
      // 当前事件、所属大事件、后续事件分列各自栏目，不受影响
      expect(section(system, '当前事件'), contains('章节 · 丙'));
      expect(section(system, '所属大事件'), contains('大事件B'));
      expect(section(system, '后续事件'), contains('大事件C'));
      // 「之后的大事件」绝不能进【之前所有大事件】段
      expect(body.contains('大事件C'), isFalse);
      expect(body.contains('大事件D'), isFalse);
    });
  });

  /// 把几段注入文本接成一份（**用换行接**：`countLine` 是按行首匹配的，
  /// 直接用 `+` 会把两段粘成一行，怎么数都不对）
  String joined(List<String> parts) => parts
      .where((p) => p.trim().isNotEmpty)
      .map((p) => p.trim())
      .join('\n');

  group('注入下一个大事件', () {
    /// 与上面不同的一份大纲：当前事件（丙）与下一个大事件之间隔着 3 个小事件，
    /// 大事件 C 落在【后续事件】那两条之外——这正是这个开关要解决的场景。
    /// 大事件A / 甲 / 大事件B / 乙 / 丙(当前) / 丁 / 戊 / 己 / 大事件C / 庚
    List<OutlineChapter> farChapters() => [
      ch(1, 'major', '大事件A'),
      ch(2, 'minor', '甲'),
      ch(3, 'major', '大事件B'),
      ch(4, 'minor', '乙'),
      ch(5, 'minor', '丙'),
      ch(6, 'minor', '丁'),
      ch(7, 'minor', '戊'),
      ch(8, 'minor', '己'),
      ch(9, 'major', '大事件C'),
      ch(10, 'minor', '庚'),
    ];

    OutlineEditController makeFar({int target = 4}) {
      final ctrl = OutlineEditController(OutlineRecord(title: 'T', content: ''));
      ctrl.init(farChapters());
      ctrl.setAiTarget(target);
      return ctrl;
    }

    test('默认关闭：不注入，且【后续事件】仍是原来那两条', () {
      final ctrl = makeController(); // 「丙」，下一个大事件是 C
      expect(ctrl.injectNextMajor, isFalse);
      expect(ctrl.aiNextMajorText, isEmpty);
      expect(ctrl.aiHasNextMajorToInject, isFalse);
      // 关着时后续事件照旧：C 与 丁（都在紧邻两条内）
      expect(ctrl.aiNextEventsText, '【大事件】大事件C：大事件C 的概要\n【章节】丁：丁 的概要');
    });

    test('关闭时下一个大事件只能靠【后续事件】的位置进来，没有别的来源', () {
      // 「丙」：下一个大事件 C 就在后面第 1 条，关着开关也能在【后续事件】里看到它
      final near = makeController();
      final nearAll = joined([
        near.aiParentMajorText,
        near.aiPriorMajorsText,
        near.aiNextMajorText,
        near.aiNextEventsText,
      ]);
      expect(countLine(nearAll, '【大事件】大事件C'), 1); // 恰好一次，来自【后续事件】
      expect(countLine(near.aiNextEventsText, '【大事件】大事件C'), 1);

      // 「甲」：后面两条是 B、乙，下一个大事件 B 正好在窗口里（不是缺口）
      final jia = makeController(target: 1);
      expect(jia.aiNextEventsText, '【大事件】大事件B：大事件B 的概要\n【章节】乙：乙 的概要');

      // 「乙」：下一个大事件是 C，而后面两条是 丙、C —— 中间隔了丙这一条，
      // 但 C 仍落在第二条里，所以看得到
      final yi = makeController(target: 3);
      expect(yi.aiNextEventsText, '【章节】丙：丙 的概要\n【大事件】大事件C：大事件C 的概要');

      // 真正的缺口：只有"下一个大事件"落在【后续事件】两条之外时才注入不到。
      // 用 4 个小事件隔开它（见下面 farChapters 那组用例）
    });

    test('打开后紧接着的大事件改由独立栏目给出，不再在【后续事件】里重复', () {
      final ctrl = makeController(); // 「丙」：C 原本在后续事件第一条
      ctrl.setInjectNextMajor(true);

      expect(ctrl.aiNextMajorText, '大事件C：大事件C 的概要');
      expect(ctrl.aiHasNextMajorToInject, isTrue);
      // 后续事件里不再重复它，并且补上再下一条，仍然只有两条
      expect(ctrl.aiNextEventsText, '【章节】丁：丁 的概要\n【大事件】大事件D：大事件D 的概要');
      expect(countLine(ctrl.aiNextEventsText, '【大事件】大事件C'), 0);
    });

    test('下一个大事件离得远（中间隔了 3 个小事件）时也能注入', () {
      final ctrl = makeFar(); // 「丙」→ 下一个大事件是 C（第 9 个）
      // 先看关着开关时的缺口：后续两条里只有丁、戊，看不到 C
      expect(ctrl.aiNextEventsText, '【章节】丁：丁 的概要\n【章节】戊：戊 的概要');
      expect(ctrl.aiNextMajorText, isEmpty);
      expect(
        joined([
          ctrl.aiParentMajorText,
          ctrl.aiPriorMajorsText,
          ctrl.aiNextMajorText,
          ctrl.aiNextEventsText,
        ]).contains('大事件C'),
        isFalse,
        reason: '关着开关时，落在【后续事件】两条之外的下一个大事件完全注入不到',
      );

      ctrl.setInjectNextMajor(true);
      expect(ctrl.aiNextMajorText, '大事件C：大事件C 的概要');
      expect(ctrl.aiHasNextMajorToInject, isTrue);
      // 后续事件保持"紧邻两条"的预览，不因为注入 C 而跳过中间的小事件
      expect(ctrl.aiNextEventsText, '【章节】丁：丁 的概要\n【章节】戊：戊 的概要');
    });

    test('紧邻的大事件也单独开一节：开关一开表现恒定，不因远近变来变去', () {
      // 「丁」（第 7 个）：下一个大事件是 D，就在紧邻两条内
      final ctrl = makeController(target: 6);
      expect(ctrl.aiNextEventsText, '【大事件】大事件D：大事件D 的概要'); // 关着时在后续事件里

      ctrl.setInjectNextMajor(true);
      expect(ctrl.aiNextMajorText, '大事件D：大事件D 的概要');
      expect(ctrl.aiHasNextMajorToInject, isTrue);
      // 让位给【下一个大事件】后，后续事件里不再有它
      expect(countLine(ctrl.aiNextEventsText, '【大事件】大事件D'), 0);
    });

    test('后面没有大事件时：打开也没有可注入的内容', () {
      final ctrl = makeController(target: 7); // 大事件D，后面没有大事件了
      ctrl.setInjectNextMajor(true);

      expect(ctrl.aiNextMajorText, isEmpty);
      expect(ctrl.aiHasNextMajorToInject, isFalse);
    });

    test('与「同批所选事件」不重复：只注入一次', () {
      final ctrl = makeFar(); // 「丙」，下一个大事件 C
      ctrl.setInjectNextMajor(true);
      ctrl.setInjectSelectedEvents(true);

      final next = ctrl.aiNextMajorText;
      final selected = ctrl.aiSelectedEventsText;
      expect(countLine(next, '大事件C'), 1);
      expect(countLine(selected, '【大事件】大事件C'), 0);
      expect(
        countLine(next, '大事件C') + countLine(selected, '大事件C'),
        1,
        reason: '大事件C 在注入内容里应恰好出现一次',
      );
    });

    test('组装出的系统提示词含【下一个大事件】段，且它排在【后续事件】之后', () {
      final ctrl = makeFar();
      ctrl.setInjectNextMajor(true);
      final draft = ctrl.aiTargetDraft!;

      final system =
          ctrl.service.buildChatMessages(
                outline: ctrl.outline,
                eventTitle: draft.title,
                eventSummary: draft.summary,
                isMajor: draft.isMajor,
                userInput: '写一下这节',
                parentMajor: ctrl.aiParentMajorText,
                priorMajors: ctrl.aiPriorMajorsText,
                prevEvents: ctrl.aiPrevEventsText,
                nextEvents: ctrl.aiNextEventsText,
                nextMajor: ctrl.aiNextMajorText,
              ).first['content']
              as String;

      expect(section(system, '下一个大事件'), contains('大事件C：大事件C 的概要'));
      expect(section(system, '后续事件'), contains('【章节】丁'));
      expect(
        system.indexOf('【下一个大事件】'),
        greaterThan(system.indexOf('【后续事件】')),
        reason: '往后看的栏目排在一起',
      );
      // 前面的栏目不受影响
      expect(section(system, '所属大事件'), contains('大事件B'));
      // 当前事件自己不会出现在这几段里
      expect(section(system, '下一个大事件').contains('丙'), isFalse);
    });
  });

  group('面板上的开关', () {
    Future<OutlineEditController> pumpSheet(
      WidgetTester tester, {
      int target = 4,
    }) async {
      final ctrl = makeController(target: target);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OutlineAiChatSheet(controller: ctrl)),
        ),
      );
      await tester.pumpAndSettle();
      return ctrl;
    }

    /// 展开选项区
    Future<void> expandOptions(WidgetTester tester) async {
      await tester.tap(find.byTooltip('展开选项'));
      await tester.pumpAndSettle();
    }

    testWidgets('默认关闭，点整行可开可关，说明文字如实反映注入条数', (tester) async {
      final ctrl = await pumpSheet(tester);
      await expandOptions(tester);

      expect(find.text('注入之前所有大事件'), findsOneWidget);
      expect(ctrl.injectPriorMajors, isFalse);
      expect(find.textContaining('之后的大事件不注入'), findsOneWidget);

      await tester.tap(find.text('注入之前所有大事件'));
      await tester.pumpAndSettle();
      expect(ctrl.injectPriorMajors, isTrue);
      // 开了以后告诉用户这次到底注入了几个
      expect(find.textContaining('已注入当前事件之前的 2 个大事件'), findsOneWidget);

      await tester.tap(find.text('注入之前所有大事件'));
      await tester.pumpAndSettle();
      expect(ctrl.injectPriorMajors, isFalse);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('前面没有大事件时，开了也如实说没有可注入的内容', (tester) async {
      final ctrl = await pumpSheet(tester, target: 0); // 大事件A
      await expandOptions(tester);

      await tester.tap(find.text('注入之前所有大事件'));
      await tester.pumpAndSettle();

      expect(ctrl.injectPriorMajors, isTrue);
      expect(ctrl.aiPriorMajorsText, isEmpty);
      expect(find.textContaining('还没有大事件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('「注入下一个大事件」也是整行可点，说明文字如实反映状态', (tester) async {
      final ctrl = await pumpSheet(tester);
      await expandOptions(tester);

      // 三个选项行并排在同一块选项区里
      expect(find.text('注入同批所选事件'), findsOneWidget);
      expect(find.text('注入之前所有大事件'), findsOneWidget);
      expect(find.text('注入下一个大事件'), findsOneWidget);

      // 默认关闭
      expect(ctrl.injectNextMajor, isFalse);
      expect(find.textContaining('便于收尾衔接'), findsOneWidget);

      await tester.tap(find.text('注入下一个大事件'));
      await tester.pumpAndSettle();
      expect(ctrl.injectNextMajor, isTrue);
      expect(find.textContaining('已注入下一个大事件'), findsOneWidget);

      await tester.tap(find.text('注入下一个大事件'));
      await tester.pumpAndSettle();
      expect(ctrl.injectNextMajor, isFalse);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('后面没有大事件时，开了也如实说没有可注入的内容', (tester) async {
      final ctrl = await pumpSheet(tester, target: 7); // 大事件D，后面没有了
      await expandOptions(tester);

      await tester.tap(find.text('注入下一个大事件'));
      await tester.pumpAndSettle();

      expect(ctrl.injectNextMajor, isTrue);
      expect(ctrl.aiNextMajorText, isEmpty);
      expect(find.textContaining('之后还没有大事件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('开关状态存得住：收起再展开不被重置', (tester) async {
      final ctrl = await pumpSheet(tester);
      await expandOptions(tester);

      await tester.tap(find.text('注入之前所有大事件'));
      await tester.pumpAndSettle();
      expect(ctrl.injectPriorMajors, isTrue);

      await tester.tap(find.byTooltip('收起选项'));
      await tester.pumpAndSettle();
      expect(find.text('注入之前所有大事件'), findsNothing);

      await tester.tap(find.byTooltip('展开选项'));
      await tester.pumpAndSettle();
      expect(find.text('注入之前所有大事件'), findsOneWidget);
      expect(ctrl.injectPriorMajors, isTrue);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('360dp 窄屏：三个选项行全展开也不溢出', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final ctrl = await pumpSheet(tester);
      await expandOptions(tester);
      // 三个开关都打开（说明文字最长的那种状态）
      await tester.tap(find.text('注入同批所选事件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注入之前所有大事件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注入下一个大事件'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('注入下一个大事件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });
  });
}
