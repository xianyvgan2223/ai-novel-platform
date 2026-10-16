// 联网搜索来源裁决 + 设置读写单元测试
//
// 覆盖三件事：
//   1. UserSetting 对 search_engine / search_need_content 的读写与历史兼容；
//   2. ChatController 的来源裁决（deepseek 不再被降级成百度）；
//   3. 按来源校验鉴权 Key。

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/config/user_setting.dart';
import 'package:deepseekapp/features/chat/application/chat_controller.dart';

void main() {
  group('UserSetting 搜索字段', () {
    test('默认关闭联网搜索（不能替用户打开花钱的外部请求）', () {
      const s = UserSetting();
      expect(s.searchEngine, UserSetting.searchEngineOff);
      expect(s.searchNeedContent, isTrue, reason: '抓取正文默认开启，答得更准');
    });

    test('toMap / fromMap 往返保留来源与抓取正文开关', () {
      const s = UserSetting(
        searchEngine: UserSetting.searchEngineDeepseek,
        searchNeedContent: false,
        searchCount: 8,
        searchFreshness: 'pw',
      );
      final back = UserSetting.fromMap(s.toMap());
      expect(back.searchEngine, UserSetting.searchEngineDeepseek);
      expect(back.searchNeedContent, isFalse);
      expect(back.searchCount, 8);
      expect(back.searchFreshness, 'pw');
    });

    test('copyWith 能单独改抓取正文开关', () {
      const s = UserSetting(searchEngine: UserSetting.searchEngineDeepseek);
      expect(s.copyWith(searchNeedContent: false).searchNeedContent, isFalse);
      expect(
        s.copyWith(searchNeedContent: false).searchEngine,
        UserSetting.searchEngineDeepseek,
        reason: '改一个字段不该影响另一个',
      );
    });

    group('历史数据兼容（老库没有 search_engine 列）', () {
      test('web_search=1 → 按百度处理', () {
        final s = UserSetting.fromMap({'web_search': 1});
        expect(s.searchEngine, UserSetting.searchEngineBaidu);
      });

      test('web_search=0 → 关闭（不再被误解成"百度已开启"）', () {
        final s = UserSetting.fromMap({'web_search': 0});
        expect(s.searchEngine, UserSetting.searchEngineOff);
      });

      test('两个字段都没有 → 关闭', () {
        final s = UserSetting.fromMap({});
        expect(s.searchEngine, UserSetting.searchEngineOff);
      });

      test('有 search_engine 列时以列为准，压过布尔量', () {
        final s = UserSetting.fromMap({
          'web_search': 0,
          'search_engine': UserSetting.searchEngineDeepseek,
        });
        expect(s.searchEngine, UserSetting.searchEngineDeepseek);
      });

      test('search_need_content 列缺失时默认开启', () {
        expect(UserSetting.fromMap({}).searchNeedContent, isTrue);
        expect(
          UserSetting.fromMap({'search_need_content': 0}).searchNeedContent,
          isFalse,
        );
      });
    });
  });

  group('搜索来源裁决', () {
    test('deepseek 不再被降级成百度（官方搜索接口已上线）', () {
      const s = UserSetting(searchEngine: UserSetting.searchEngineDeepseek);
      expect(
        ChatController.effectiveSearchEngine(s),
        UserSetting.searchEngineDeepseek,
      );
    });

    test('百度 / 关闭 原样返回', () {
      expect(
        ChatController.effectiveSearchEngine(
          const UserSetting(searchEngine: UserSetting.searchEngineBaidu),
        ),
        UserSetting.searchEngineBaidu,
      );
      expect(
        ChatController.effectiveSearchEngine(
          const UserSetting(searchEngine: UserSetting.searchEngineOff),
        ),
        UserSetting.searchEngineOff,
      );
    });

    test('脏值按历史 web_search 布尔量裁决，两个都没有时关闭', () {
      expect(
        ChatController.effectiveSearchEngine(
          const UserSetting(searchEngine: 'garbage', webSearch: true),
        ),
        UserSetting.searchEngineBaidu,
      );
      expect(
        ChatController.effectiveSearchEngine(
          const UserSetting(searchEngine: '', webSearch: false),
        ),
        UserSetting.searchEngineOff,
      );
    });
  });

  group('按来源校验鉴权 Key', () {
    test('百度来源缺百度 Key → 提示填百度 API Key', () {
      const s = UserSetting(
        searchEngine: UserSetting.searchEngineBaidu,
        apiKey: 'sk-main',
      );
      expect(ChatController.searchKeyWarning(s), contains('百度 API Key'));
    });

    test('百度来源有 Key → 无提示（DeepSeek Key 与此无关）', () {
      const s = UserSetting(
        searchEngine: UserSetting.searchEngineBaidu,
        baiduApiKey: 'bce-v3-xxx',
      );
      expect(ChatController.searchKeyWarning(s), isNull);
    });

    test('DeepSeek 来源只认主 API Key，不要求百度 Key', () {
      const ok = UserSetting(
        searchEngine: UserSetting.searchEngineDeepseek,
        apiKey: 'sk-main',
      );
      expect(ChatController.searchKeyWarning(ok), isNull);

      const missing = UserSetting(
        searchEngine: UserSetting.searchEngineDeepseek,
        baiduApiKey: 'bce-v3-xxx', // 填了百度 Key 也不算数
      );
      expect(
        ChatController.searchKeyWarning(missing),
        contains('DeepSeek API Key'),
      );
    });

    test('关闭搜索时不检查任何 Key', () {
      expect(
        ChatController.searchKeyWarning(
          const UserSetting(searchEngine: UserSetting.searchEngineOff),
        ),
        isNull,
      );
    });
  });

  group('多路查询结果合并', () {
    Map<String, dynamic> r(String title, String url) => {'name': title, 'url': url};

    test('按链接去重，轮流取以保证每一路都有代表', () {
      final merged = ChatController.mergeSearchResults(
        [
          [r('a1', 'https://a/1'), r('a2', 'https://a/2')],
          [r('b1', 'https://b/1'), r('a2重复', 'https://a/2')],
        ],
        maxTotal: 10,
      );
      expect(merged.map((e) => e['url']).toList(), [
        'https://a/1',
        'https://b/1',
        'https://a/2',
      ]);
    });

    test('总条数受 maxTotal 限制', () {
      final merged = ChatController.mergeSearchResults(
        [
          List.generate(5, (i) => r('a$i', 'https://a/$i')),
          List.generate(5, (i) => r('b$i', 'https://b/$i')),
        ],
        maxTotal: 3,
      );
      expect(merged, hasLength(3));
    });

    test('链接为空时用标题+序号做键，不会把不同结果误判成重复', () {
      final merged = ChatController.mergeSearchResults(
        [
          [r('无链接1', ''), r('无链接2', '')],
        ],
        maxTotal: 10,
      );
      expect(merged, hasLength(2));
    });

    test('某一路为空时只返回另一路的结果', () {
      final merged = ChatController.mergeSearchResults(
        [
          [r('a1', 'https://a/1')],
          [],
        ],
        maxTotal: 10,
      );
      expect(merged, hasLength(1));
    });
  });

  group('web_search 工具定义', () {
    Map<String, dynamic> fn(UserSetting s, String engine) =>
        ChatController.buildWebSearchTool(s, engine)['function']
            as Map<String, dynamic>;

    final today = DateTime.now();
    final todayText =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    test('描述里带当前日期（模型会用错年份去搜旧闻）', () {
      final desc = fn(const UserSetting(), UserSetting.searchEngineDeepseek)['description'] as String;
      expect(desc, contains(todayText));
      expect(desc, contains('正确的年份'));
    });

    test('DeepSeek 来源额外给出 site:/after: 等查询语法', () {
      final desc = fn(
        const UserSetting(searchEngine: UserSetting.searchEngineDeepseek),
        UserSetting.searchEngineDeepseek,
      )['description'] as String;
      expect(desc, contains('site:'));
      expect(desc, contains('after:'));
      expect(desc, contains('lang:'));
    });

    test('百度来源不带 DeepSeek 专有语法，但同样带日期', () {
      final desc = fn(const UserSetting(), UserSetting.searchEngineBaidu)['description'] as String;
      expect(desc, contains(todayText));
      expect(desc, isNot(contains('site:')));
    });

    test('top_k 上限：DeepSeek 按官方 50 钳制，百度用设置值', () {
      final deep = fn(
        const UserSetting(
          searchEngine: UserSetting.searchEngineDeepseek,
          searchCount: 999,
        ),
        UserSetting.searchEngineDeepseek,
      );
      final baidu = fn(
        const UserSetting(searchCount: 999),
        UserSetting.searchEngineBaidu,
      );
      String topKDesc(Map<String, dynamic> f) =>
          ((f['parameters'] as Map)['properties'] as Map)['top_k']['description']
              as String;
      expect(topKDesc(deep), contains('范围1-50'));
      expect(topKDesc(baidu), contains('范围1-999'));
    });

    test('工具名保持 web_search，不破坏既有流程', () {
      expect(
        fn(const UserSetting(), UserSetting.searchEngineDeepseek)['name'],
        'web_search',
      );
    });
  });
}
