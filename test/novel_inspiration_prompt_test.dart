import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/novel_inspiration/domain/inspiration_models.dart';
import 'package:deepseekapp/features/novel_writing/novel_inspiration/service/inspiration_service.dart';

/// 「小说灵感」的提示词与数据模型约束：
/// - 推演格式按作者本轮指令，不强制正文；
/// - 只注入勾选的人物卡、只注入选中的大纲事件；
/// - 对话上下文只带已采用的推演结果。
void main() {
  group('数据模型', () {
    test('设置默认并发生成 3 个', () {
      const s = InspirationSettings();
      expect(s.concurrency, 3);
      expect(s.model, 'deepseek-flash');
    });

    test('设置从数据库读回并钳制并发范围', () {
      final s = InspirationSettings.fromMap({
        'model': 'deepseek-v4-pro',
        'temperature': 1.1,
        'max_tokens': 8192,
        'system_prompt': '自定义',
        'enable_thinking': 0,
        'concurrency': 99,
      });
      expect(s.model, 'deepseek-v4-pro');
      expect(s.temperature, 1.1);
      expect(s.maxTokens, 8192);
      expect(s.systemPrompt, '自定义');
      expect(s.enableThinking, isFalse);
      expect(s.concurrency, 10);
    });

    test('导入事件快照可 JSON 往返', () {
      const events = [
        InspirationOutlineEvent(
          chapterId: 7,
          type: 'major',
          title: '旧宅第一夜',
          summary: '他搬进旧宅。',
          majorNumber: 2,
        ),
        InspirationOutlineEvent(
          chapterId: 8,
          type: 'minor',
          title: '门闩',
          summary: '门闩上多了划痕。',
          majorNumber: 2,
          minorNumber: 1,
        ),
      ];
      final decoded = InspirationOutlineEvent.decodeList(
        InspirationOutlineEvent.encodeList(events),
      );
      expect(decoded.length, 2);
      expect(decoded[1].minorNumber, 1);
      expect(decoded[0].chapterId, 7);
    });
  });

  group('系统提示词', () {
    test('不强制正文，按作者本轮指令输出，并注入世界观 / 主题', () {
      final prompt = NovelInspirationPromptTemplate.buildSystemPrompt(
        settings: const InspirationSettings(),
        worldView: '废土世界',
        theme: '从孑然一身到有人围着',
      );
      expect(prompt, contains('严格按照作者本轮指令'));
      expect(prompt, contains('要求大纲、分析、方案'));
      expect(prompt, isNot(contains('只输出小说正文')));
      expect(prompt, contains('废土世界'));
      expect(prompt, contains('从孑然一身到有人围着'));
    });

    test('只注入勾选的人物卡；未勾选的不出现', () {
      final prompt = NovelInspirationPromptTemplate.buildSystemPrompt(
        settings: const InspirationSettings(),
        cards: const [
          InspirationCharacterCard(
            sessionId: 1,
            name: '顾泽',
            description: '旧城幸存者，靠短刀和侦查活下来',
            personality: '嘴硬心软',
            status: '刚失去同伴',
            inject: true,
          ),
          InspirationCharacterCard(
            sessionId: 1,
            name: '秘密反派',
            personality: '阴狠',
            inject: false,
          ),
        ],
      );
      expect(prompt, contains('顾泽'));
      expect(prompt, contains('旧城幸存者'));
      expect(prompt, contains('嘴硬心软'));
      expect(prompt, contains('刚失去同伴'));
      expect(prompt, isNot(contains('秘密反派')));
    });

    test('只注入选中的大纲事件，且标注为范围限制', () {
      final prompt = NovelInspirationPromptTemplate.buildSystemPrompt(
        settings: const InspirationSettings(),
        events: const [
          InspirationOutlineEvent(
            type: 'major',
            title: '旧宅第一夜',
            summary: '他搬进旧宅。',
          ),
        ],
      );
      expect(prompt, contains('旧宅第一夜'));
      expect(prompt, contains('不要提前写后续事件'));
      expect(prompt, isNot(contains('另一件没选中的事')));
    });

    test('设置了自定义系统提示词时替换默认提示词', () {
      final prompt = NovelInspirationPromptTemplate.buildSystemPrompt(
        settings: const InspirationSettings(systemPrompt: '我是自定义提示词'),
      );
      expect(prompt, contains('我是自定义提示词'));
      expect(prompt, isNot(contains('你是一位中文小说作家，正在和作者一起推演小说剧情。')));
      // 输出规则仍然追加，但不再强制正文
      expect(prompt, contains('严格按照作者本轮指令'));
      expect(prompt, isNot(contains('只输出小说正文')));
    });
  });

  group('对话模式', () {
    test('系统提示注入对话设定与已采用推演结果，不要求续写正文', () {
      final prompt = NovelInspirationPromptTemplate.buildChatSystemPrompt(
        settings: const InspirationSettings(),
        worldView: '废土世界',
        theme: '求生',
        deductionResults: const ['第一轮推演：主角进入废土城市。'],
      );
      expect(prompt, contains('小说创作助手'));
      expect(prompt, contains('废土世界'));
      expect(prompt, contains('第一轮推演：主角进入废土城市。'));
      expect(prompt, isNot(contains('只输出小说正文')));
    });

    test('对话历史按顺序注入，当前输入在最后；不包含推演分支内容', () {
      final messages = NovelInspirationPromptTemplate.buildChatMessages(
        settings: const InspirationSettings(),
        deductionResults: const ['已采用推演结果 A'],
        history: const [
          InspirationChatMessage(
            sessionId: 1,
            role: 'user',
            content: '这个主角动机够吗？',
          ),
          InspirationChatMessage(
            sessionId: 1,
            role: 'assistant',
            content: '动机可以再补一笔。',
          ),
        ],
        userText: '怎么补？',
      );
      expect(messages.length, 4); // system + 2 history + 当前
      expect(messages[1]['content'], '这个主角动机够吗？');
      expect(messages[2]['content'], '动机可以再补一笔。');
      expect(messages.last['content'], '怎么补？');
      expect(
        (messages.first['content'] as String).contains('已采用推演结果 A'),
        isTrue,
      );
      expect(
        (messages.first['content'] as String).contains('未采用推演分支'),
        isFalse,
      );
    });
  });

  group('生成消息', () {
    test('对话只注入已采用的结果；当前指令在最后', () {
      final messages = NovelInspirationPromptTemplate.buildGenerateMessages(
        settings: const InspirationSettings(),
        history: const [(instruction: '上一条指令', result: '上一条被采用的正文')],
        instruction: '继续往下写',
        variantIndex: 1,
        variantCount: 3,
      );
      expect(messages.length, 4); // system + (user + assistant) + 当前 user
      expect(messages[0]['role'], 'system');
      expect(messages[1]['content'], '上一条指令');
      expect(messages[2]['content'], '上一条被采用的正文');
      expect(messages.last['content'], contains('继续往下写'));
      expect(messages.last['content'], contains('第 1 个候选推演'));
    });

    test('只生成 1 个推演时不追加候选说明', () {
      final messages = NovelInspirationPromptTemplate.buildGenerateMessages(
        settings: const InspirationSettings(),
        instruction: '写一段',
        variantIndex: 1,
        variantCount: 1,
      );
      expect(messages.last['content'], '写一段');
    });

    test('合并消息包含所有待合并推演，格式按用户指令', () {
      final messages = NovelInspirationPromptTemplate.buildMergeMessages(
        settings: const InspirationSettings(),
        instruction: '推进剧情',
        branches: const ['版本一正文', '版本二正文'],
      );
      final user = messages.last['content'] as String;
      expect(user, contains('版本一正文'));
      expect(user, contains('版本二正文'));
      expect(user, contains('合并成一个结果'));
      expect(user, contains('格式与详略严格按照'));
      expect(user, isNot(contains('只输出合并后的正文')));
    });

    test('合并消息包含用户附加的合并要求', () {
      final messages = NovelInspirationPromptTemplate.buildMergeMessages(
        settings: const InspirationSettings(),
        instruction: '推进剧情',
        branches: const ['版本一正文', '版本二正文'],
        mergeRequirement: '保留主角第一人称视角',
      );
      final user = messages.last['content'] as String;
      expect(user, contains('额外要求（优先遵守）'));
      expect(user, contains('保留主角第一人称视角'));
    });

    test('对话式段落改写：保留历史结果，并允许空要求使用默认改写', () {
      final first = NovelInspirationPromptTemplate.buildSegmentChatMessages(
        settings: const InspirationSettings(),
        fullText: '完整正文',
        selectedText: '选中段落',
        instruction: '',
      );
      expect((first.last['content'] as String), contains('把选中段落改写得更完整、更有画面感'));

      final second = NovelInspirationPromptTemplate.buildSegmentChatMessages(
        settings: const InspirationSettings(),
        fullText: '完整正文',
        selectedText: '选中段落',
        turns: const [(instruction: '第一版：更紧张', result: '第一版结果')],
        instruction: '再克制一点',
      );
      final user = second.last['content'] as String;
      expect(user, contains('再克制一点'));
      expect(second.any((m) => m['content'] == '第一版结果'), isTrue);
    });

    test('段落改写消息包含完整正文、选中段落与要求', () {
      final messages = NovelInspirationPromptTemplate.buildSegmentMessages(
        settings: const InspirationSettings(),
        fullText: '第一段。第二段。第三段。',
        selectedText: '第二段。',
        instruction: '写得更紧张',
      );
      final user = messages.last['content'] as String;
      expect(user, contains('第一段。第二段。第三段。'));
      expect(user, contains('第二段。'));
      expect(user, contains('写得更紧张'));
      expect(user, contains('只输出改写后的选中段落'));
    });
  });

  group('人物卡状态', () {
    test('只依据选中注入的事件生成状态', () {
      final messages = NovelInspirationPromptTemplate.buildCardStatusMessages(
        worldView: '废土世界',
        theme: '求生',
        card: const InspirationCharacterCard(
          sessionId: 1,
          name: '顾泽',
          description: '旧城幸存者',
          personality: '警惕',
          skills: '短刀',
        ),
        events: const [
          InspirationOutlineEvent(
            type: 'minor',
            title: '旧宅第一夜',
            summary: '他失去了同伴。',
          ),
        ],
      );
      final user = messages.last['content'] as String;
      expect(user, contains('顾泽'));
      expect(user, contains('旧城幸存者'));
      expect(user, contains('旧宅第一夜'));
      expect(user, contains('他失去了同伴。'));
      expect(user, contains('当前的状态'));
    });
  });

  test('事件 JSON 解码坏数据时返回空列表，不崩', () {
    expect(InspirationOutlineEvent.decodeList('not json'), isEmpty);
    expect(InspirationOutlineEvent.decodeList(jsonEncode({'a': 1})), isEmpty);
  });
}
