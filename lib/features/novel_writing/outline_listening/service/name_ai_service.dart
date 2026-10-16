import '../../chapter_writing/service/chapter_write_service.dart';
import 'name_finder.dart';

/// AI 辅助识别大纲里的人名 / 地名（**可选**能力）。
///
/// 离线规则（`name_finder.dart`）已经能挑出大部分中文人名与地名，但它对
/// 「代号式名字」「译名」「组织简称」这类没把握。这里补一次模型调用：
/// 只把大纲正文交给模型，要它返回 JSON 数组，解析失败就当没识别到——
/// **失败绝不影响改名流程**，用户可以手填。
class OutlineNameAiService {
  final ChapterWriteService _chapterService;

  OutlineNameAiService({ChapterWriteService? chapterService})
      : _chapterService = chapterService ?? ChapterWriteService();

  /// 送给模型的正文上限（按码点）：大纲可能很长，取头尾各一半，
  /// 人名地名在开头（人物出场）与结尾（结局）出现得最多。
  static const int _maxChars = 12000;

  /// 识别一次；没有 API Key / 调用失败时返回空列表
  Future<List<OutlineNameCandidate>> detect({
    required String content,
    String title = '',
    String protagonist = '',
    String worldview = '',
  }) async {
    final text = content.trim();
    if (text.isEmpty) return const [];

    final settings = await _chapterService.loadSettings();
    if (settings.apiKey.isEmpty) return const [];

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _systemPrompt},
      {
        'role': 'user',
        'content': _userPrompt(
          title: title,
          protagonist: protagonist,
          worldview: worldview,
          content: _clip(text),
        ),
      },
    ];
    try {
      final raw = await _chapterService.chatOnce(
        apiKey: settings.apiKey,
        apiParams: <String, dynamic>{
          'model': settings.chapterSetting.model,
          'temperature': 0.2,
          'max_tokens': 2048,
          if (!settings.chapterSetting.enableThinking)
            'thinking': {'type': 'disabled'},
        },
        messages: messages,
      );
      return parseAiNameCandidates(raw);
    } catch (_) {
      // 识别失败不是错误：面板上仍然有离线规则挑出来的候选与手填入口
      return const [];
    }
  }

  static const String _systemPrompt =
      '你是中文小说编辑助手，只负责从大纲里挑出**专有名词**。\n'
      '输出要求：\n'
      '- 只输出一个 JSON 数组，不要任何解释、寒暄或 Markdown 代码块标记\n'
      '- 数组元素形如 {"name":"李云飞","type":"人名"}，type 只能是「人名」「地名」「组织」「其它」\n'
      '- 挑出所有反复出现、值得被批量改名的专有名词：人名、地名、门派 / 组织 / 势力名\n'
      '- 不要把普通名词、动作、时间词（如「第二天」「众人」）当作专名\n'
      '- 每个名字只出现一次；最多 40 条';

  String _userPrompt({
    required String title,
    required String protagonist,
    required String worldview,
    required String content,
  }) {
    final buf = StringBuffer();
    if (title.trim().isNotEmpty) buf.writeln('【书名】${title.trim()}');
    if (protagonist.trim().isNotEmpty) {
      buf.writeln('【主角】${protagonist.trim()}');
    }
    if (worldview.trim().isNotEmpty) {
      buf.writeln('【世界观】${worldview.trim()}');
    }
    buf
      ..writeln('【大纲正文】')
      ..writeln(content);
    return buf.toString();
  }

  String _clip(String text) {
    final runes = text.runes.toList();
    if (runes.length <= _maxChars) return text;
    final head = _maxChars ~/ 2;
    final tail = _maxChars - head;
    return '${String.fromCharCodes(runes.sublist(0, head))}\n'
        '……（中间内容省略）……\n'
        '${String.fromCharCodes(runes.sublist(runes.length - tail))}';
  }
}
