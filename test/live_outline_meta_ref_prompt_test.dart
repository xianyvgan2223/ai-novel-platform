// 「一键生成大纲」的真模型验证：展开（步骤 3）时，即使全局骨架里满是
// 「大事件52 / 大事件99」这类编号，大事件概述与小事件概要里也**不允许**出现
// 「第几章 / 大事件N / N与M埋的」编号引用。
//
// 默认跳过（无 DS_LIVE_API_KEY 时），避免日常跑测试计费：
//   PowerShell:  $env:DS_LIVE_API_KEY='sk-xxxx'; flutter test test/live_outline_meta_ref_prompt_test.dart
//   Bash:        DS_LIVE_API_KEY=sk-xxxx flutter test test/live_outline_meta_ref_prompt_test.dart
//
// 目的：用**真模型**验证提示词规则生效，而不是只对着提示词字符串做断言。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/core/config/deepseek_models.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_chunk_normalizer.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_meta_refs.dart';
import 'package:deepseekapp/features/novel_writing/outline_generation/service/outline_service.dart';

String get _apiKey {
  final fromEnv = Platform.environment['DS_LIVE_API_KEY']?.trim() ?? '';
  if (fromEnv.isNotEmpty) return fromEnv;
  return const String.fromEnvironment('DS_LIVE_API_KEY').trim();
}

/// 长纲里常见的上下文：全局骨架里每个大事件都带编号，且此前埋了若干伏笔。
String get _globalSummary => '''
书名：《天下第一尸兄世界》

完整三幕骨架：
══ 第一幕：开端 ══
══ 大事件52：旧宅第一夜 ══
他搬进旧宅的第一夜把门闩上又拔出来——埋长线伏笔：旧铁条。
══ 大事件54：只学会一种接受方式 ══
他从小只学会一种接受方式：被人护着。埋长线伏笔：接受善意。
══ 大事件70：药与食盒 ══
她每天把药熬好放在门口，他从不端进去。埋长线伏笔：自己熬的药。
══ 大事件74：续尽则断 ══
他的内力像一根续到尽头的线，断而有限。埋长线伏笔：续尽则断。
══ 大事件88：旧台补法 ══
旧台补法的缺口没有补全，师门只剩半卷手记。埋长线伏笔：失传的补法。

══ 第二幕：发展 ══
══ 大事件90：不给他转的机会 ══
姜黎把话说死，不给他转的机会。埋长线伏笔：欠着的那句话。
══ 大事件91：那一场 ══
卓青梧说「等你续上了，我们再打真的」。埋长线伏笔：欠着的那一场。

══ 第三幕：高潮&结局 ══
══ 大事件99：终章·把药喝完 ══
他喝下自己熬的那碗药，把食盒提进去一口一口喝完——从被护着，到能自己过日子、
也肯被人护着。这一块是全书的收束点。
''';

/// 精写后的大事件概述：App 侧归一化要求最终正文逐字保留它（模型不得重写）。
const String _overview =
    '他喝下自己熬的那碗药，把食盒提进去一口一口喝完——从被护着，到能自己过日子、'
    '也肯被人护着。这一块是全书的收束点：所有埋下的旧物与旧话，都在这里收口。';

String get _actContent => '''
══ 大事件99：终章·把药喝完 ══
$_overview
''';

void main() {
  final apiKey = _apiKey;
  if (apiKey.isEmpty) {
    test('真模型验证（未提供 DS_LIVE_API_KEY，跳过）', () {
      // ignore: avoid_print
      print('跳过：设置环境变量 DS_LIVE_API_KEY 后重跑');
    });
    return;
  }

  test('展开终章：正文无编号引用，且大事件概述逐字保留、小事件完整输出', () async {
    final prompt = OutlinePromptTemplate.buildStep3Prompt(
      genre: '都市异能',
      theme: '从孑然一身的杀神活成一个被人围着抢的普通人',
      protagonist: '顾泽，低武世界的天下第一，穿越尸兄世界',
      worldview: 'H市尸潮爆发，幸存者在废墟里挣扎求生',
      majorEventCount: 9,
      minorEventCount: 2,
      title: '天下第一尸兄世界',
      actContent: _actContent,
      actIndex: 3,
      globalSummary: _globalSummary,
      previousContent: '上一块结束时：他把那根旧铁条从门框上退下来，放在门槛边，'
          '没有重新闩上；姜黎站在门外没有走，也没有说话。',
    );

    final raw = await _generate(
      apiKey: apiKey,
      systemPrompt: OutlinePromptTemplate.defaultSystemPrompt,
      userPrompt: prompt,
    );
    // ignore: avoid_print
    print('==== 模型输出（尾部 1200 字）====\n'
        '${raw.length > 1200 ? raw.substring(raw.length - 1200) : raw}\n'
        '==== 输出结束 ====');

    // 模型必须还认得这一块大事件（否则说明格式失败，断言没有意义）
    expect(raw, contains('大事件99'));

    // 核心断言：正文（标题行之外）不允许残留编号引用
    expect(
      OutlineMetaRefCleaner.hasNumberReference(raw),
      isFalse,
      reason: '展开正文里仍出现「第N章 / 大事件N / N与M埋的」编号引用：\n$raw',
    );
    // 具体禁例再兜一遍（hasNumberReference 之外的显式检查）
    expect(RegExp(r'第\s*\d+\s*[章回节]').hasMatch(raw), isFalse);
    expect(RegExp(r'\d+\s*[与和、]\s*\d+\s*埋').hasMatch(raw), isFalse);

    // App 侧归一化（修复「小事件没把大事件全部内容包括到」）：
    // 大事件概述取骨架原文、逐字保留；模型只提供小事件部分
    final normalized = OutlineChunkNormalizer.normalize(
      expected: [(title: '终章·把药喝完', summary: _overview)],
      modelText: raw,
    );
    expect(normalized, isNotNull, reason: '模型输出应能切出大事件块');
    final composed = normalized!.single;
    expect(composed.summary, _overview);
    expect(composed.minorsBody, isNotEmpty, reason: '模型应输出小事件');
    expect(
      OutlineMetaRefCleaner.hasNumberReference(composed.minorsBody),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 走生产同一条链路（ApiService.streamChat）做一次流式请求
Future<String> _generate({
  required String apiKey,
  required String systemPrompt,
  required String userPrompt,
}) async {
  final service = OutlineService();
  final buf = StringBuffer();
  final completer = Completer<void>();
  await service.streamGenerate(
    apiKey: apiKey,
    apiParams: <String, dynamic>{
      'model': DeepSeekModels.flashId,
      'temperature': 0.3,
      'max_tokens': 3000,
      'stream': true,
      // 结构化/纯文本都行：这里要的是正文，纯文本即可
      'thinking': {'type': 'disabled'},
    },
    messages: [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ],
    onChunk: (chunk) {
      final choices = chunk['choices'] as List?;
      if (choices == null || choices.isEmpty) return;
      final delta = choices[0]['delta'] as Map<String, dynamic>?;
      final content = delta?['content'] as String?;
      if (content != null && content.isNotEmpty) buf.write(content);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (msg) {
      if (!completer.isCompleted) completer.completeError(Exception(msg));
    },
  );
  await completer.future;
  return buf.toString();
}
