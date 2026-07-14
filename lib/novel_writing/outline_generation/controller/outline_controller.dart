import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../model/outline_setting.dart';
import '../model/outline_record.dart';
import '../model/db/outline_db_helper.dart';
import '../model/db/outline_record_db_helper.dart';

/// 大纲生成控制器，管理业务逻辑与状态
class OutlineController extends ChangeNotifier {
  final genreController = TextEditingController(text: '玄幻');
  final themeController = TextEditingController();
  final protagonistController = TextEditingController();
  final scrollController = ScrollController();
  final _apiService = ApiService();

  int majorEventCount = 5;
  int minorEventCount = 3;
  bool loading = false;
  String? error;
  String rawText = '';
  String title = '';
  CancelToken? _cancelToken;

  /// 取消当前生成
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    loading = false;
    notifyListeners();
  }

  void dispose() {
    genreController.dispose();
    themeController.dispose();
    protagonistController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 50),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> generate() async {
    if (themeController.text.trim().isEmpty ||
        protagonistController.text.trim().isEmpty) {
      error = '请填写主题和主角设定';
      notifyListeners();
      return;
    }

    loading = true;
    error = null;
    rawText = '';
    title = '';
    notifyListeners();

    try {
      final global = await UserSettingService.getSettings();
      if (global.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }

      // 读取专属大纲设置，找不到时使用默认值
      OutlineSetting outlineSetting = const OutlineSetting();
      try {
        final row = await OutlineDbHelper().getSettings();
        if (row != null) outlineSetting = OutlineSetting.fromMap(row);
      } catch (_) {}

      final systemPrompt = outlineSetting.systemPrompt.isNotEmpty
          ? outlineSetting.systemPrompt
          : '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';

      final prompt =
          '''
你是一位资深小说编辑。请根据以下设定生成一份完整的小说大纲。

类型：${genreController.text}
主题：${themeController.text}
主角：${protagonistController.text}
主事件（大事件）数量：$majorEventCount
每个主事件下小事件数量：$minorEventCount

要求：
1. 用第一行输出小说标题，格式：书名：《xxx》
2. 第二行空行后，写一段核心概念简介（50字以内）
3. 按三幕式结构（开端、发展、高潮/结局）组织主事件
4. 每个主事件下包含若干小事件，格式如下：

   ══ 大事件X：标题 ══
   大事件概述（50-100字）
   ○ 小事件1：标题
     小事件概要（30-50字）
   ○ 小事件2：标题
     小事件概要（30-50字）

5. 每幕之间用 ══ 第一幕：开端 ══ 这样的分隔线隔开
6. 确保情节有起承转合，人物有成长弧线
7. 直接用纯文本输出，不要使用 JSON 或 Markdown 格式
''';

      String accumulated = '';

      _cancelToken = CancelToken();

      await _apiService.streamChat(
        apiKey: global.apiKey,
        apiParams: {
          'model': outlineSetting.model,
          'temperature': outlineSetting.temperature,
          'max_tokens': outlineSetting.maxTokens,
          'stream': true,
        },
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': prompt},
        ],
        cancelToken: _cancelToken,
        onChunk: (chunk) {
          final choices = chunk['choices'] as List?;
          if (choices == null || choices.isEmpty) return;

          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) return;

          final content = delta['content'] as String?;
          if (content == null || content.isEmpty) return;

          accumulated += content;
          rawText = accumulated;
          if (title.isEmpty) {
            final firstLine = accumulated
                .split('\n')
                .firstWhere((l) => l.contains('书名：'), orElse: () => '');
            if (firstLine.isNotEmpty) {
              title = firstLine
                  .replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '')
                  .trim();
            }
          }
          notifyListeners();
          scrollToBottom();
        },
        onDone: () {
          _cancelToken = null;
          // 自动保存到历史记录
          if (rawText.isNotEmpty) {
            final record = OutlineRecord(
              title: title,
              genre: genreController.text,
              theme: themeController.text,
              protagonist: protagonistController.text,
              content: rawText,
            );
            OutlineRecordDbHelper().insert(record.toMap());
          }
          loading = false;
          notifyListeners();
        },
        onError: (errorMsg) {
          _cancelToken = null;
          error = errorMsg;
          loading = false;
          notifyListeners();
        },
      );
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      loading = false;
      notifyListeners();
    }
  }
}
