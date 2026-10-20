import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/widgets/settings_kit.dart';
import 'package:deepseekapp/features/chat/application/chat_controller.dart';
import 'package:deepseekapp/features/chat/domain/chat_session.dart';
import 'package:deepseekapp/features/chat/presentation/session_setting_page.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/copy_entity.dart';
import 'package:deepseekapp/features/game/novel_game/view/widget/common_setting_dialog.dart';
import 'package:deepseekapp/features/novel_writing/ai_battle/view/page/battle_setting_page.dart';

/// 「功能设置页 v2」的**截图工具**（文件名不以 `_test` 结尾，`flutter test`
/// 不会自动跑它）。改动会话设置 / 战斗设置 / 小说游戏编辑弹窗后用它出图核对：
///
///     flutter test --update-goldens test/ui_shot/feature_settings_shot.dart
///
/// 设备真身是 Honor KOZ-AL00：720×1600 px @ 320 dpi = 360×800 dp，系统字体
/// 缩放 1.15。SimHei 比真机字体窄，1.0 倍图会遮蔽截断问题，所以每页同时出
/// 1.0 / 1.15 两张全页图。
///
/// 输出在 test/ui_shot/shots/：
///   30 会话设置·360dp 全页·1.0
///   31 会话设置·360dp 全页·1.15
///   36 战斗设置·360dp 全页·1.0
///   37 战斗设置·360dp 全页·1.15
///   38a 小说游戏·编辑副本名称弹窗
///   38b 小说游戏·编辑人物经历弹窗
void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 图标字体。
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    // SimHei 缺部分英文标点/圆点，挂 Arial 作为 fallback。
    await _loadFont('Arial', r'C:\Windows\Fonts\arial.ttf');
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    if (flutterRoot.isNotEmpty) {
      await _loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf',
      );
    }
  });

  // ── 会话设置 ──
  testWidgets('会话设置·360dp 全页·1.0', (tester) async {
    await _pumpFullPage(tester, app: _sessionApp());
    await _expectGolden(tester, '30_session_settings_full.png');
  });

  testWidgets('会话设置·360dp 全页·1.15', (tester) async {
    await _pumpFullPage(tester, app: _sessionApp(), textScale: 1.15);
    await _expectGolden(tester, '31_session_settings_full_font115.png');
  });

  // ── 战斗设置 ──
  testWidgets('战斗设置·360dp 全页·1.0', (tester) async {
    await _pumpFullPage(tester, app: _battleApp());
    await _expectGolden(tester, '36_battle_settings_full.png');
  });

  testWidgets('战斗设置·360dp 全页·1.15', (tester) async {
    await _pumpFullPage(tester, app: _battleApp(), textScale: 1.15);
    await _expectGolden(tester, '37_battle_settings_full_font115.png');
  });

  // ── 小说游戏编辑弹窗 ──
  testWidgets('小说游戏·编辑副本名称弹窗', (tester) async {
    await _pumpDialogHost(tester);
    await tester.tap(find.byKey(const ValueKey('open-copy-dialog')));
    await tester.pumpAndSettle();
    await _expectGolden(tester, '38a_novel_game_copy_dialog.png');
  });

  testWidgets('小说游戏·编辑人物经历弹窗', (tester) async {
    await _pumpDialogHost(tester);
    await tester.tap(find.byKey(const ValueKey('open-character-dialog')));
    await tester.pumpAndSettle();
    await _expectGolden(tester, '38b_novel_game_character_dialog.png');
  });
}

/// 会话设置页依赖 chatProvider：用假控制器跳过真实 DB/网络。
///
/// 只 override `currentSession` 与 `updateSessionSystemPrompt`；
/// `session.id` 故意为 null——真实保存会写库，截图用例只需要渲染。
class _FakeChatController extends ChatController {
  @override
  ChatSession? get currentSession => ChatSession(
    id: null,
    title: '迷雾之城·第一章',
    createTime: '2026-10-20T08:00:00.000',
    systemPrompt:
        '你是一位严谨的小说编辑。回答用户问题时先给结论，再给依据；'
        '语言简洁具体，不要空话套话。涉及设定冲突时，明确指出冲突点。',
  );

  @override
  void updateSessionSystemPrompt(String prompt) {
    // 截图用例不点保存，空实现即可（真实逻辑由 chat_controller 单测覆盖）。
  }
}

Widget _sessionApp() {
  return ProviderScope(
    overrides: [
      chatProvider.overrideWith((ref) => _FakeChatController()),
    ],
    child: _app(const SessionSettingsPage()),
  );
}

Widget _battleApp() {
  // 战斗设置页在 initState 里读 sqflite；widget test 下会抛
  // MissingPluginException 并被页面自己 try/catch 掉，随后回填默认提示词，
  // 因此可以直接渲染，无需 override 数据层。
  return _app(const BattleSettingPage());
}

Widget _app(Widget home) {
  return MaterialApp(
    theme: _cjkTheme(),
    // 截图不要 DEBUG 角标：它会盖住 AppBar 右上角的「保存」按钮
    debugShowCheckedModeBanner: false,
    home: home,
  );
}

Future<void> _expectGolden(WidgetTester tester, String fileName) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('shots/$fileName'),
  );
}

/// 全页长图：先在 3600dp 高视口里渲染出全部内容，量出内容底部，再把视口
/// 收紧到「内容底 + 40dp 列表底部留白」，避免长图末尾拖一大幅空白。
///
/// 内容底取「最后一张 [SettingsCard] 的底边」：功能页的 ListView 底部 padding
/// 统一是 40dp，卡片之外没有其它内容；比「按某个 Text 量」更稳（文字下沿
/// 不等于卡片下沿，会切掉卡片底部圆角与投影）。
Future<void> _pumpFullPage(
  WidgetTester tester, {
  required Widget app,
  double width = 360,
  double dpr = 2,
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(width * dpr, 3600 * dpr);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
  }
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  await tester.pumpWidget(app);
  await tester.pumpAndSettle();

  final bottom = tester.getBottomRight(find.byType(SettingsCard).last).dy;
  final height = ((bottom + 40) * dpr).ceilToDouble() / dpr;
  tester.view.physicalSize = Size(width * dpr, height * dpr);
  await tester.pumpAndSettle();
}

/// 弹窗截图宿主：360×800 白底页面 + 两个入口按钮，点开后截整个 MaterialApp
/// （带遮罩的弹窗，与真机观感一致）。弹窗不点关闭，因此不会触发
/// scheduleControllerDispose 的 400ms 定时器，测试结束不会残留 Timer。
Future<void> _pumpDialogHost(WidgetTester tester) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(360 * 2, 800 * 2);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_app(const _DialogHost()));
  await tester.pumpAndSettle();
}

class _DialogHost extends StatelessWidget {
  const _DialogHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              key: const ValueKey('open-copy-dialog'),
              onPressed: () => showCopySettingDialog(
                context,
                CopyEntity(copyName: '第一卷·迷雾之城'),
              ),
              child: const Text('编辑副本名称'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('open-character-dialog'),
              onPressed: () => showCharacterSettingDialog(
                context,
                CharacterEntity(
                  charName: '林清玄',
                  baseDesc:
                      '青云宗外门弟子，性格沉静内敛，擅长剑术与阵法。'
                      '十年前家族被灭，他带着一枚残缺的玉佩踏上修行之路，'
                      '始终在追查当年惨案的真相。',
                ),
              ),
              child: const Text('编辑人物经历'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 截图用主题：test 默认字体（FlutterTest）画不出字形，会渲染成一排空心方框。
ThemeData _cjkTheme() {
  const fallback = <String>['Arial'];
  final base = ThemeData(fontFamily: 'SimHei', fontFamilyFallback: fallback);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'SimHei',
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'SimHei',
      fontFamilyFallback: fallback,
    ),
  );
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final loader = FontLoader(family)
    ..addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
  await loader.load();
}
