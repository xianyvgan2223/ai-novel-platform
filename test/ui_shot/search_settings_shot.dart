import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/setting_controller.dart';
import 'package:deepseekapp/features/chat/presentation/settings_page.dart';
import 'package:deepseekapp/features/chat/presentation/widgets/search_sources_card.dart';

/// 「联网搜索设置」+「搜索来源卡片」的**截图工具**：文件名不以 `_test` 结尾，
/// `flutter test` 不会自动跑它。改动搜索设置项或来源卡片后用它出图肉眼核对：
///
///     flutter test --update-goldens test/ui_shot/search_settings_shot.dart
///
/// 输出在 test/ui_shot/shots/：
///   11 设置页·联网搜索=关闭
///   12 设置页·联网搜索=DeepSeek 官方搜索（含"抓取网页正文"开关）
///   13 设置页·联网搜索=百度千帆（含百度 Key 输入框）
///   14 来源卡片·收起态（历史消息气泡）
///   15 来源卡片·展开态（DeepSeek 结果：标题 / 站点·日期 / 摘要 / 链接）
void main() {
  setUpAll(() async {
    // 测试环境默认字体画不出中文与图标，这里临时挂系统中文字体 + SDK 自带图标字体
    await _loadFont('SimHei', r'C:\Windows\Fonts\simhei.ttf');
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    if (flutterRoot.isNotEmpty) {
      await _loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'materialicons-regular.otf',
      );
    }
  });

  testWidgets('设置页·联网搜索=关闭', (tester) async {
    await _pumpSettings(tester, engine: 'off');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/11_settings_search_off.png'),
    );
  });

  testWidgets('设置页·联网搜索=DeepSeek 官方搜索', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'deepseek',
      apiKey: 'sk-1234567890abcdef',
      searchNeedContent: false,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/12_settings_search_deepseek.png'),
    );
  });

  testWidgets('设置页·联网搜索=百度千帆', (tester) async {
    await _pumpSettings(
      tester,
      engine: 'baidu',
      baiduApiKey: 'bce-v3-abcdef123456',
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/13_settings_search_baidu.png'),
    );
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
ThemeData _cjkTheme() {
  final base = ThemeData(fontFamily: 'SimHei');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'SimHei'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'SimHei'),
  );
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required String engine,
  String apiKey = '',
  String baiduApiKey = '',
  bool searchNeedContent = true,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final ctrl = _PresetSettingController()
    ..setApiKey(apiKey)
    ..setBaiduApiKey(baiduApiKey)
    ..setSearchEngine(engine)
    ..setSearchNeedContent(searchNeedContent);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [settingProvider.overrideWith((ref) => ctrl)],
      child: MaterialApp(
        theme: _cjkTheme(),
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
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
