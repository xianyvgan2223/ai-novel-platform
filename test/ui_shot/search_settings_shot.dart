import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/config/app_version.dart';
import 'package:deepseekapp/features/chat/application/setting_controller.dart';
import 'package:deepseekapp/features/chat/presentation/settings_page.dart';
import 'package:deepseekapp/features/chat/presentation/widgets/search_sources_card.dart';

/// 设置页布局 v2 + 搜索来源卡片的**截图工具**：文件名不以 `_test` 结尾，
/// `flutter test` 不会自动跑它。改动设置页布局后用它出图肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/search_settings_shot.dart
///
/// 设备真身是 Honor KOZ-AL00：720×1600 px @ 320 dpi = 360×800 dp，所以
/// 设置页一律按 360dp 宽、dpr=2 出图（旧套件是 390dp，跟真机不符，已删）。
///
/// 输出在 test/ui_shot/shots/：
///   20 设置页 v2·全页·联网搜索关闭
///   21 设置页 v2·全页·DeepSeek 官方搜索
///   22 设置页 v2·全页·百度千帆
///   23 设置页 v2·首屏 360×800（真机视口）
///   24 设置页 v2·320dp 窄屏全页（验证不溢出）
///   25 设置页 v2·360dp 全页 + 1.3 倍字号
///   26 设置页 v2·首屏 360×800 + 1.15 倍字号（Honor KOZ-AL00 同款缩放）
///   27 设置页 v2·全页 + 1.15 倍字号（验证 frequency_penalty 等参数名完整）
///   14 来源卡片·收起态（历史消息气泡）
///   15 来源卡片·展开态（DeepSeek 结果：标题 / 站点·日期 / 摘要 / 链接）
void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 自带图标字体
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    // SimHei 没有 U+2022（•），API Key 输入框的掩码圆点会变成一排豆腐块；
    // 挂 Arial 作为字体 fallback，让掩码/英文标点都有字形。
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

  testWidgets('设置页 v2·全页·联网搜索关闭', (tester) async {
    await _pumpSettings(tester, engine: 'off');
    await _expectGolden(tester, '20_settings_v2_full_off.png');
  });

  testWidgets('设置页 v2·全页·DeepSeek 官方搜索', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
    );
    await _expectGolden(tester, '21_settings_v2_full_deepseek.png');
  });

  testWidgets('设置页 v2·全页·百度千帆', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'baidu',
      apiKey: 'sk-1234567890abcdef',
      baiduApiKey: 'bce-v3-abcdef123456',
    );
    await _expectGolden(tester, '22_settings_v2_full_baidu.png');
  });

  testWidgets('设置页 v2·首屏 360×800', (tester) async {
    // 真机视口：只画第一屏，用来核对首屏信息密度与 AppBar
    await _pumpSettings(tester, engine: 'off', fullPageHeight: 800);
    await _expectGolden(tester, '23_settings_v2_phone_off.png');
  });

  testWidgets('设置页 v2·320dp 窄屏全页', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
      width: 320,
    );
    await _expectGolden(tester, '24_settings_v2_full_320.png');
  });

  testWidgets('设置页 v2·全页 + 1.3 倍字号', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
      textScale: 1.3,
    );
    await _expectGolden(tester, '25_settings_v2_full_textscale.png');
  });

  // 真机 Honor KOZ-AL00 的系统字号是 1.15（adb 实测）。1.15 倍下必须仍然
  // 是「左标签 + 右值」的横向布局（真机观感），且 frequency_penalty 等
  // 长参数名完整——这两张图就是设备同款缩放的证据。
  testWidgets('设置页 v2·首屏 360×800 + 1.15 倍字号', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
      textScale: 1.15,
      fullPageHeight: 800,
    );
    await _expectGolden(tester, '26_settings_v2_phone_font115.png');
  });

  testWidgets('设置页 v2·全页 + 1.15 倍字号', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
      textScale: 1.15,
    );
    await _expectGolden(tester, '27_settings_v2_full_font115.png');
  });

  testWidgets('来源卡片·收起与展开', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 300 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: _cjkTheme(),
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: SearchSourcesCard(results: _deepSeekResults()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/14_sources_collapsed.png'),
    );

    await tester.tap(find.textContaining('搜索来源'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/15_sources_expanded.png'),
    );
  });
}

Future<void> _expectGolden(WidgetTester tester, String fileName) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('shots/$fileName'),
  );
}

/// 渲染设置页并固定视口。
///
/// [fullPageHeight] 为 null 时表示"全页长图"：先在一个足够高的视口
/// （3600dp，能一次装下所有区块）里量出内容底部，再把视口收到
/// 「版本号 + 40dp 列表底部留白」，避免长图末尾拖一大块空白；
/// 传了具体高度就按固定视口出图（23 号图用 800dp 模拟真机首屏）。
Future<void> _pumpSettings(
  WidgetTester tester, {
  required String engine,
  String apiKey = '',
  String baiduApiKey = '',
  bool searchNeedContent = true,
  bool stream = true,
  String model = 'deepseek-flash',
  double width = 360,
  double dpr = 2,
  double? fullPageHeight,
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(width * dpr, (fullPageHeight ?? 3600) * dpr);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
  }
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  final ctrl = _PresetSettingController()
    ..setModel(model)
    ..setApiKey(apiKey)
    ..setBaiduApiKey(baiduApiKey)
    ..setSearchEngine(engine)
    ..setSearchNeedContent(searchNeedContent)
    ..setStream(stream);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [settingProvider.overrideWith((ref) => ctrl)],
      child: MaterialApp(
        theme: _cjkTheme(),
        // 截图不要 DEBUG 角标：它会盖住 AppBar 右上角的「保存」按钮
        debugShowCheckedModeBanner: false,
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (fullPageHeight == null) {
    final bottom =
        tester.getBottomRight(find.text('当前版本 v$kAppVersion')).dy;
    final height = ((bottom + 40) * dpr).ceilToDouble() / dpr;
    tester.view.physicalSize = Size(width * dpr, height * dpr);
    await tester.pumpAndSettle();
  }
}

/// DeepSeek 官方搜索的真实返回形状（照抄线上响应字段）
List<Map<String, dynamic>> _deepSeekResults() => [
  {
    'name': 'DeepSeek V4.1 Flash 模型正式发布',
    'url': 'https://api-docs.deepseek.com/news/v41-flash',
    'snippet': 'DeepSeek 今日发布 V4.1 Flash，主打更低延迟与更长上下文，API 已同步上线。',
    'summary': '长摘要（给模型阅读）',
    'content': '正文',
    'site_name': 'DeepSeek 文档',
    'date': '2026-09-09T16:00:00+00:00',
    'authority': 4,
  },
  {
    'name': 'DeepSeek 官方搜索接口上线，按次计费 5 元/千次',
    'url': 'https://example.com/news/deepseek-search-api',
    'snippet': '官方新增 /v1/tools/search 与 /v1/tools/fetch，与对话接口共用同一个 API Key。',
    'site_name': '示例科技',
    'date': '2026-10-01T02:30:00+00:00',
    'authority': 3,
  },
];

/// 截图用主题：test 环境默认字体（FlutterTest）画不出字形，会渲染成一排空心方框。
/// ThemeData(fontFamily:) 只覆盖一部分文本样式，输入框/下拉框取的是 textTheme 里的
/// 具名样式，所以这里再 apply 一遍，保证整页都能看清。
/// SimHei 缺 U+2022，用 Arial 兜底（见 setUpAll），避免掩码圆点变豆腐块。
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

/// 截图用的假控制器：跳过查库，直接用预设值渲染（真实读取逻辑另有单测覆盖）
class _PresetSettingController extends SettingController {
  @override
  bool get isLoaded => true;

  @override
  Future<void> loadSettings() async {}
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final loader = FontLoader(family)
    ..addFont(
      Future.value(file.readAsBytesSync().buffer.asByteData()),
    );
  await loader.load();
}
