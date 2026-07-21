// lib/pet/chat/pet_chat_controller.dart
// 宠物聊天控制器 — 支持流式对话 + 宠物状态联动 + 一键创建备忘录

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../../services/api_service.dart';
import '../../services/user_setting_service.dart';
import '../../services/memo_service.dart';
import '../../models/user_setting.dart';
import '../../models/memo.dart';
import '../providers/pet_provider.dart';

/// 宠物聊天消息（简化版，不含会话管理）
class PetChatMessage {
  final bool isUser;
  final String content;
  final String? thinkingText;
  final String timestamp;

  const PetChatMessage({
    required this.isUser,
    required this.content,
    this.thinkingText,
    required this.timestamp,
  });
}

/// 聊天情绪表情 — 悬浮球根据用户输入和AI回复实时切换
enum ChatExpression {
  excited, // 用户很兴奋/开心 → 超开心表情
  happy, // 用户友善/暖心 → 开心表情
  neutral, // 默认待机
  sad, // 用户负面/生气 → 低落表情
  thinking; // AI思考中/流式输出

  String get label {
    switch (this) {
      case ChatExpression.excited:
        return '兴奋';
      case ChatExpression.happy:
        return '开心';
      case ChatExpression.neutral:
        return '普通';
      case ChatExpression.sad:
        return '低落';
      case ChatExpression.thinking:
        return '思考';
    }
  }
}

/// 宠物聊天控制器
class PetChatController extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final PetController _petController;

  // 备忘录正则 — 匹配 【MEMO_START】...【MEMO_END】或 [MEMO_START]...[MEMO_END]
  static final RegExp _memoRegex = RegExp(
    r'[【\[]MEMO_START[】\]](.+?)[【\[]MEMO_END[】\]]',
  );
  static const String _memoFieldSep = r'||';

  // 宠物系统提示词（含备忘录创建说明）
  static const String _petSystemPrompt =
      '你是用户的宠物伙伴，名字叫"小宠"。你非常可爱、活泼、忠诚，喜欢和用户玩耍、撒娇。'
      '你会根据用户的语气和内容调整回应方式：用户开心时你也很开心，用户低落时你会温柔安慰。'
      '请用简短、可爱的语言回应，适当使用拟声词（如"呜呜~"、"喵~"、"汪汪~"），'
      '表现出宠物独有的情感和依恋。回复要热情但自然，不要过于复杂。\n\n'
      '【备忘录能力】当用户要求你帮忙记录事情时（如"记录明天下午3点开会""备忘买生活用品"），'
      '请识别用户的备忘内容，在回复末尾附加以下格式（不要显示给用户看，仅做数据标记）：\n'
      '【MEMO_START】标题||内容||优先级(low/medium/high)||分类【MEMO_END】\n'
      '例如用户说"记录明天下午3点和产品开会"，你可以附加：\n'
      '【MEMO_START】和产品开会||明天下午3点||medium||工作【MEMO_END】';

  PetChatMessage? _assistantMessage;
  final List<PetChatMessage> _messages = [];
  bool _isLoading = false;
  bool _hasInitialized = false;
  CancelToken? _cancelToken;
  ChatExpression _currentExpression = ChatExpression.neutral;

  PetChatController(this._petController);

  List<PetChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  String get streamingText => _assistantMessage?.content ?? '';
  ChatExpression get currentExpression => _currentExpression;

  /// 初始化欢迎消息
  void initWelcome() {
    if (_hasInitialized) return;
    _hasInitialized = true;
    _messages.add(
      PetChatMessage(
        isUser: false,
        content: '你好呀！我是小宠，终于等到你啦～ 🐾\n有什么想和我聊的吗？我可以陪你聊天、帮你记录备忘哦！',
        timestamp: DateTime.now().toIso8601String(),
      ),
    );
    notifyListeners();
  }

  /// 发送消息
  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isLoading) return;

    // 添加用户消息
    final userMsg = PetChatMessage(
      isUser: true,
      content: trimmed,
      timestamp: DateTime.now().toIso8601String(),
    );
    _messages.add(userMsg);
    _isLoading = true;
    _assistantMessage = null;
    // 根据用户输入切换表情
    _currentExpression = _analyzeUserExpression(trimmed);
    notifyListeners();

    try {
      // 加载用户设置
      final setting = await UserSettingService.getSettings();
      if (setting.apiKey.isEmpty) {
        _onError('请先在设置中填写 API Key');
        return;
      }

      // 构建上下文
      final msgs = _buildMessages(setting);

      _cancelToken = CancelToken();

      String accumulatedContent = '';
      String accumulatedThinking = '';

      await _apiService.streamChat(
        apiKey: setting.apiKey,
        apiParams: setting.toApiParams(),
        messages: msgs,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;

          final choice = choices[0] as Map<String, dynamic>;
          final delta = choice['delta'] as Map<String, dynamic>?;

          if (delta != null) {
            final content = delta['content'] as String? ?? '';
            final reasoning = delta['reasoning_content'] as String? ?? '';
            accumulatedContent += content;
            accumulatedThinking += reasoning;

            _assistantMessage = PetChatMessage(
              isUser: false,
              content: _cleanMemoMarkers(accumulatedContent),
              thinkingText: accumulatedThinking.isNotEmpty
                  ? accumulatedThinking
                  : null,
              timestamp: DateTime.now().toIso8601String(),
            );
            notifyListeners();
          }
        },
        onDone: () {
          if (accumulatedContent.isNotEmpty) {
            // 尝试创建备忘录
            String displayContent = accumulatedContent;
            try {
              displayContent = _tryCreateMemo(accumulatedContent);
            } catch (_) {}

            _messages.add(
              PetChatMessage(
                isUser: false,
                content: displayContent,
                thinkingText: accumulatedThinking.isNotEmpty
                    ? accumulatedThinking
                    : null,
                timestamp: DateTime.now().toIso8601String(),
              ),
            );
            // 分析情绪，更新宠物状态
            _updatePetStateFromChat(text, accumulatedContent);
          }
          _assistantMessage = null;
          _isLoading = false;
          _cancelToken = null;
          notifyListeners();
        },
        onError: (error) => _onError(error),
        cancelToken: _cancelToken,
      );
    } catch (e) {
      _onError('发送失败：$e');
    }
  }

  /// 中断当前输出
  void cancelRequest() {
    if (!_isLoading || _cancelToken == null) return;
    _cancelToken!.cancel();
    _cancelToken = null;
    _isLoading = false;
    notifyListeners();
  }

  /// 构建 API 消息列表（保留最近上下文，含思考内容）
  List<Map<String, dynamic>> _buildMessages(UserSetting setting) {
    final msgs = <Map<String, dynamic>>[];

    msgs.add({'role': 'system', 'content': _petSystemPrompt});

    // 包含欢迎消息 + 最近对话（最多 20 条，保证上下文充足）
    final relevantMessages = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages;

    for (final m in relevantMessages) {
      String content = m.content;
      if (m.thinkingText != null && m.thinkingText!.isNotEmpty) {
        content = '[思考过程: ${m.thinkingText}]\n$content';
      }
      msgs.add({'role': m.isUser ? 'user' : 'assistant', 'content': content});
    }

    return msgs;
  }

  /// 从回复中解析并创建备忘录，返回去掉标记的显示文本
  String _tryCreateMemo(String response) {
    final match = _memoRegex.firstMatch(response);
    if (match == null) return response;

    final raw = match.group(1) ?? '';
    final parts = raw.split(_memoFieldSep);

    if (parts.isEmpty || parts[0].trim().isEmpty) return response;

    final title = parts[0].trim();
    final content = parts.length > 1 ? parts[1].trim() : '';
    final priorityStr = parts.length > 2
        ? parts[2].trim().toLowerCase()
        : 'medium';
    final category = parts.length > 3 ? parts[3].trim() : '';

    final priority = MemoPriority.values.firstWhere(
      (p) => p.name == priorityStr,
      orElse: () => MemoPriority.medium,
    );

    final now = DateTime.now();
    final memo = Memo(
      title: title,
      content: content,
      priority: priority,
      category: category,
      createdAt: now,
      updatedAt: now,
    );

    // 异步创建（不阻塞主流程）
    MemoService.insert(memo);

    // 去掉标记、替换为确认文案
    return response.replaceAll(match.group(0)!, '');
  }

  /// 临时清理，流式渲染时去掉标记
  String _cleanMemoMarkers(String text) {
    return text.replaceAll(_memoRegex, '');
  }

  /// 分析用户输入文本 → 聊天表情
  ChatExpression _analyzeUserExpression(String text) {
    final positive = [
      '爱',
      '喜欢',
      '乖',
      '好棒',
      '开心',
      '抱',
      '摸',
      '陪',
      '玩',
      '暖',
      '可爱',
      '漂亮',
      '最',
      '棒',
      '好',
      '亲',
      '么么',
    ];
    final excited = ['太棒', '超', '非常好', '特别', '兴奋', '激动', '开心死了', '太好了'];
    final negative = [
      '烦',
      '走开',
      '不要',
      '讨厌',
      '生气',
      '滚',
      '坏',
      '笨',
      '丑',
      '不乖',
      '别烦',
      '伤心',
      '难过',
      '骂',
      '傻',
      '蠢',
      '垃圾',
      '废物',
      '打死',
      '揍',
      '白痴',
      '脑残',
      '有病',
      '滚蛋',
      '死开',
      '闭嘴',
      '烦人',
      '可恶',
      '去死',
      '该死',
      '受不了',
    ];

    if (excited.any((w) => text.contains(w))) return ChatExpression.excited;
    if (negative.any((w) => text.contains(w))) return ChatExpression.sad;
    if (positive.any((w) => text.contains(w))) return ChatExpression.happy;
    return ChatExpression.neutral;
  }

  /// 根据聊天内容更新宠物状态 + 聊天表情
  void _updatePetStateFromChat(String userText, String responseText) {
    final positiveUserWords = [
      '爱',
      '喜欢',
      '乖',
      '好',
      '棒',
      '开心',
      '抱',
      '摸',
      '陪',
      '玩',
      '吃',
      '散步',
      '出门',
      '暖',
      '可爱',
      '漂亮',
      '最',
    ];
    final positiveResponseWords = [
      '开心',
      '高兴',
      '撒娇',
      '摇尾巴',
      '扑',
      '蹭',
      '舔',
      '兴奋',
      '欢乐',
    ];
    final negativeUserWords = [
      '烦',
      '走开',
      '不要',
      '讨厌',
      '生气',
      '滚',
      '坏',
      '笨',
      '丑',
      '不乖',
      '别烦',
      '骂',
      '傻',
      '蠢',
      '垃圾',
      '废物',
      '打死',
      '揍',
      '白痴',
      '滚蛋',
      '闭嘴',
      '烦人',
      '可恶',
      '去死',
      '该死',
    ];

    final userPositive = positiveUserWords.any((w) => userText.contains(w));
    final responsePositive = positiveResponseWords.any(
      (w) => responseText.contains(w),
    );
    final userNegative = negativeUserWords.any((w) => userText.contains(w));

    if (userNegative) {
      _petController.updateMood(-10);
      _petController.updateIntimacy(-5);
      _currentExpression = ChatExpression.sad;
    } else if (userPositive || responsePositive) {
      _petController.addGrowth(5);
      _petController.updateMood(8);
      _petController.updateIntimacy(3);
      _currentExpression = ChatExpression.happy;
    } else {
      _petController.updateMood(2);
      _currentExpression = ChatExpression.neutral;
    }
  }

  void _onError(String message) {
    _messages.add(
      PetChatMessage(
        isUser: false,
        content: '呜呜~ $message',
        timestamp: DateTime.now().toIso8601String(),
      ),
    );
    _isLoading = false;
    _assistantMessage = null;
    _cancelToken = null;
    notifyListeners();
  }
}
