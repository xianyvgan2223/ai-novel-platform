import 'package:dio/dio.dart';
import '../../chapter_writing/service/chapter_write_service.dart';
import '../../shared/domain/chapter_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../model/outline_edit_chat_message.dart';

/// 「大纲编辑」AI 生成服务（只生成大纲，不生成正文）。
///
/// 复用「大纲转章节」的设置（模型 / 温度 / 最大长度 / 深度思考），
/// 把小说设定 + 当前事件的标题与概要 + 所属大事件 + 前后相邻事件 +
/// 剧情账本 + 伏笔清单 + 对话历史拼成请求消息，流式返回**大纲文本**。
/// 面板上「注入同批所选事件」打开时，额外注入本次一起勾选的其他事件
/// （[selectedEvents]，已在前 / 后续事件里的不重复）。
/// 提示词明确禁止输出正文（场景描写 / 对白 / 心理刻画）。
class OutlineEditService {
  /// 注入对话历史的最近条数（更早的轮次不再注入，避免上下文膨胀）
  static const int maxHistory = 16;

  /// 单条历史消息最长注入字符数（超出取头尾）
  static const int _maxMessageChars = 3000;

  final ChapterWriteService _chapterService;

  OutlineEditService({ChapterWriteService? chapterService})
      : _chapterService = chapterService ?? ChapterWriteService();

  /// 加载全局设置（API Key）与章节写作设置（模型 / 温度 / 最大长度 / 深度思考）
  Future<({String apiKey, ChapterSetting chapterSetting})> loadSettings() =>
      _chapterService.loadSettings();

  /// 流式对话（复用章节链路的流式通道，支持取消）
  Future<void> streamChat({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
    CancelToken? cancelToken,
    required void Function(Map<String, dynamic> chunk) onChunk,
    required void Function() onDone,
    required void Function(String error) onError,
  }) => _chapterService.streamWrite(
    apiKey: apiKey,
    apiParams: apiParams,
    messages: messages,
    cancelToken: cancelToken,
    onChunk: onChunk,
    onDone: onDone,
    onError: onError,
  );

  /// 非流式兜底：流式不可用（接口不兼容 / 无输出）时回退，失败返回空串
  Future<String> chatOnce({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
  }) => _chapterService.chatOnce(
    apiKey: apiKey,
    apiParams: apiParams,
    messages: messages,
  );

  /// 构建一次对话请求的消息列表：系统提示词（含当前大纲上下文）+ 历史 + 本次输入
  List<Map<String, dynamic>> buildChatMessages({
    required OutlineRecord outline,
    required String eventTitle,
    required String eventSummary,
    required bool isMajor,
    required String userInput,
    List<OutlineEditChatMessage> history = const [],
    String parentMajor = '',
    String priorMajors = '',
    String selectedEvents = '',
    String prevEvents = '',
    String nextEvents = '',
    String nextMajor = '',
    String storyState = '',
    String foreshadows = '',
  }) {
    final system = buildSystemPrompt(
      outline: outline,
      eventTitle: eventTitle,
      eventSummary: eventSummary,
      isMajor: isMajor,
      parentMajor: parentMajor,
      priorMajors: priorMajors,
      selectedEvents: selectedEvents,
      prevEvents: prevEvents,
      nextEvents: nextEvents,
      nextMajor: nextMajor,
      storyState: storyState,
      foreshadows: foreshadows,
    );
    // 历史只取最近若干条；助手消息在界面里可能很长，同样按长度裁剪
    final recent = history.length > maxHistory
        ? history.sublist(history.length - maxHistory)
        : history;
    return <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
      for (final m in recent)
        if (m.content.trim().isNotEmpty)
          {'role': m.role, 'content': _clip(m.content, _maxMessageChars)},
      {'role': 'user', 'content': userInput},
    ];
  }

  /// 系统提示词：大纲助手定位 + 输出要求 + 小说设定 + 事件上下文
  String buildSystemPrompt({
    required OutlineRecord outline,
    required String eventTitle,
    required String eventSummary,
    required bool isMajor,
    String parentMajor = '',
    String priorMajors = '',
    String selectedEvents = '',
    String prevEvents = '',
    String nextEvents = '',
    String nextMajor = '',
    String storyState = '',
    String foreshadows = '',
  }) {
    final buf = StringBuffer()
      ..writeln('你是小说大纲编辑助手，负责协助用户撰写、修改与细化**章节大纲**（事件标题与事件概要）。')
      ..writeln()
      ..writeln('输出要求：')
      ..writeln('- 用户要求写 / 改写 / 细化概要时，直接输出可填入【事件概要】的大纲文本：用简明的叙述句交代事件的起因、推进与结果，可分段或分点')
      ..writeln('- 只写大纲：禁止输出场景描写、人物对白、心理刻画等小说正文内容')
      ..writeln('- 用户要求起标题时只输出标题本身，不带「标题：」等前缀、不带书名号')
      ..writeln('- 严格按用户的要求输出结果本身，不要寒暄、解释，也不要输出 Markdown 代码块标记')
      ..writeln('- 与小说设定、所属大事件、同批所选事件及前后事件保持一致；除用户明确要求外，不改变既有剧情走向、人物设定与伏笔安排')
      ..writeln('- 篇幅与既有条目相近（通常 1-3 句；用户另有要求时从其要求）')
      ..writeln()
      ..writeln('【小说设定】')
      ..writeln('类型：${_orNone(outline.genre)}')
      ..writeln('主题：${_orNone(outline.theme)}')
      ..writeln('主角：${_orNone(outline.protagonist)}')
      ..writeln('世界观：${_orNone(outline.worldview)}')
      ..writeln()
      ..writeln('【当前事件】${isMajor ? "大事件" : "章节"} · ${_orNone(eventTitle)}');
    if (eventSummary.trim().isNotEmpty) {
      buf
        ..writeln('【当前事件概要】')
        ..writeln(eventSummary.trim());
    }
    if (parentMajor.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【所属大事件】')
        ..writeln(parentMajor.trim());
    }
    if (priorMajors.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【之前所有大事件】（当前事件之前的大事件，按时间先后排列，供保持剧情连续，勿直接复述）')
        ..writeln(priorMajors.trim());
    }
    if (selectedEvents.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【同批所选事件】（本次一起勾选编辑的其他事件，供保持衔接，勿直接复述）')
        ..writeln(selectedEvents.trim());
    }
    if (prevEvents.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【前一事件】')
        ..writeln(prevEvents.trim());
    }
    if (nextEvents.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【后续事件】')
        ..writeln(nextEvents.trim());
    }
    if (nextMajor.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【下一个大事件】（紧接着的大事件，供本事件收尾时向它衔接，勿直接复述其情节）')
        ..writeln(nextMajor.trim());
    }
    if (storyState.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【已写章节的剧情状态】（供保持剧情连续，勿直接复述）')
        ..writeln(storyState.trim());
    }
    if (foreshadows.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【伏笔清单】')
        ..writeln(foreshadows.trim());
    }
    return buf.toString();
  }

  /// 空值占位，避免提示词出现空栏目造成模型误解
  String _orNone(String value) =>
      value.trim().isEmpty ? '（未填写）' : value.trim();

  /// 超长文本裁成「头部 + 尾部」，中间用省略标记连接（按码点裁剪，不会截断 emoji）
  String _clip(String text, int max) {
    final t = text.trim();
    final runes = t.runes.toList();
    if (runes.length <= max) return t;
    final head = max ~/ 3;
    final tail = max - head;
    return '${String.fromCharCodes(runes.sublist(0, head))}'
        '\n……（中间内容省略）……\n'
        '${String.fromCharCodes(runes.sublist(runes.length - tail))}';
  }
}
