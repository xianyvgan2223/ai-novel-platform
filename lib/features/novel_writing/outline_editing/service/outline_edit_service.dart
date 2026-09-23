import 'package:dio/dio.dart';
import '../../chapter_writing/service/chapter_write_service.dart';
import '../../shared/domain/chapter_setting.dart';
import '../../shared/domain/outline_record.dart';
import '../model/outline_edit_chat_message.dart';

/// 「大纲编辑」AI 生成服务。
///
/// 复用「大纲转章节」的设置（模型/温度/最大长度/深度思考/章节系统提示），
/// 负责把小说设定 + 当前章节（含编辑框中尚未保存的内容）+ 对话历史
/// 拼成请求消息，并以流式方式返回生成结果。
class OutlineEditService {
  /// 注入对话历史的最近条数（更早的轮次不再注入，避免上下文膨胀）
  static const int maxHistory = 16;

  /// 单条历史消息最长注入字符数（超出取头尾）
  static const int _maxMessageChars = 4000;

  /// 当前章节正文最长注入字符数（超出取头尾）
  static const int _maxContentChars = 12000;

  final ChapterWriteService _chapterService;

  OutlineEditService({ChapterWriteService? chapterService})
      : _chapterService = chapterService ?? ChapterWriteService();

  /// 加载全局设置（API Key）与章节写作设置
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

  /// 非流式兜底：流式不可用（接口不兼容/无输出）时回退，失败返回空串
  Future<String> chatOnce({
    required String apiKey,
    required Map<String, dynamic> apiParams,
    required List<Map<String, dynamic>> messages,
  }) => _chapterService.chatOnce(
    apiKey: apiKey,
    apiParams: apiParams,
    messages: messages,
  );

  /// 构建一次对话请求的消息列表：系统提示词（含最新正文快照）+ 历史 + 本次输入
  List<Map<String, dynamic>> buildChatMessages({
    required OutlineRecord outline,
    required String eventTitle,
    required String eventSummary,
    required bool isMajor,
    required String userInput,
    List<OutlineEditChatMessage> history = const [],
    String parentMajor = '',
    String prevSummary = '',
    String storyState = '',
    String foreshadows = '',
    String chapterContent = '',
    String rolePrompt = '',
  }) {
    final system = buildSystemPrompt(
      rolePrompt: rolePrompt,
      outline: outline,
      eventTitle: eventTitle,
      eventSummary: eventSummary,
      isMajor: isMajor,
      parentMajor: parentMajor,
      prevSummary: prevSummary,
      storyState: storyState,
      foreshadows: foreshadows,
      chapterContent: chapterContent,
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

  /// 系统提示词：角色定位 + 输出要求 + 小说设定 + 当前事件上下文 + 最新正文
  String buildSystemPrompt({
    required OutlineRecord outline,
    required String eventTitle,
    required String eventSummary,
    required bool isMajor,
    String parentMajor = '',
    String prevSummary = '',
    String storyState = '',
    String foreshadows = '',
    String chapterContent = '',
    String rolePrompt = '',
  }) {
    final role = rolePrompt.trim().isEmpty
        ? '你是专业的小说编辑与写作助手，负责协助用户撰写、修改、续写与润色章节内容。'
        : rolePrompt.trim();
    final buf = StringBuffer()
      ..writeln(role)
      ..writeln()
      ..writeln('输出要求：')
      ..writeln('- 严格按用户的要求输出，直接给出可以放进正文的结果文本，不要寒暄、解释或输出 Markdown 代码块标记')
      ..writeln('- 用户要求「续写/接着写」时，从【当前章节正文】的结尾继续往下写，不要重复已有内容')
      ..writeln('- 用户要求「润色/修改/扩写/精简」时，输出处理后的完整正文，不要只给片段')
      ..writeln('- 与小说设定、大纲和上下文保持一致；除用户明确要求外，不改变既有剧情走向、人物设定与伏笔安排')
      ..writeln(isMajor
          ? '- 当前事件是大事件（结构节点，通常没有正文），用户要求生成内容时请输出事件概述而非正文'
          : '- 语言平实自然，避免堆砌辞藻与空泛抒情')
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
        ..writeln('【事件概要】')
        ..writeln(eventSummary.trim());
    }
    if (parentMajor.trim().isNotEmpty) {
      buf
        ..writeln('【所属大事件】')
        ..writeln(parentMajor.trim());
    }
    if (prevSummary.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【上一章小结】')
        ..writeln(prevSummary.trim());
    }
    if (storyState.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【全局剧情状态】')
        ..writeln(storyState.trim());
    }
    if (foreshadows.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【伏笔清单】')
        ..writeln(foreshadows.trim());
    }
    buf
      ..writeln()
      ..writeln(isMajor ? '【当前事件概述（编辑框中最新内容）】' : '【当前章节正文（编辑框中最新内容）】')
      ..writeln(
        chapterContent.trim().isEmpty
            ? '（暂无内容）'
            : _clip(chapterContent, _maxContentChars),
      );
    return buf.toString();
  }

  /// 空值占位，避免提示词出现空栏目造成模型误解
  String _orNone(String value) => value.trim().isEmpty ? '（未填写）' : value.trim();

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
