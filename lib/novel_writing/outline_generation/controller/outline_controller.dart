import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/outline_service.dart';
import '../../shared/models/outline_record.dart';

/// 大纲生成控制器，管理业务逻辑与状态
class OutlineController extends ChangeNotifier {
  final genreController = TextEditingController(text: '玄幻');
  final themeController = TextEditingController();
  final protagonistController = TextEditingController();
  final worldViewController = TextEditingController();
  final scrollController = ScrollController();
  final OutlineService _outlineService;

  int majorEventCount = 5;
  int minorEventCount = 3;
  bool loading = false;
  String? error;
  String rawText = '';
  String title = '';
  CancelToken? _cancelToken;

  OutlineController({OutlineService? outlineService})
    : _outlineService = outlineService ?? OutlineService();

  /// 取消当前生成
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    genreController.dispose();
    themeController.dispose();
    protagonistController.dispose();
    worldViewController.dispose();
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
      // 1. 通过服务层加载设置
      final settings = await _outlineService.loadSettings();
      if (settings.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }

      // 2. 通过提示词模板构建消息
      final systemPrompt = OutlinePromptTemplate.buildSystemPrompt(
        settings.outlineSetting.systemPrompt,
      );
      final prompt = OutlinePromptTemplate.buildUserPrompt(
        genre: genreController.text,
        theme: themeController.text,
        protagonist: protagonistController.text,
        worldview: worldViewController.text,
        majorEventCount: majorEventCount,
        minorEventCount: minorEventCount,
        outlineSetting: settings.outlineSetting,
      );

      // 3. 调用流式 API
      String accumulated = '';
      _cancelToken = CancelToken();

      await _outlineService.streamGenerate(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.outlineSetting.model,
          'temperature': settings.outlineSetting.temperature,
          'max_tokens': settings.outlineSetting.maxTokens,
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
          // 4. 通过服务层保存到历史记录
          if (rawText.isNotEmpty) {
            final record = OutlineRecord(
              title: title,
              genre: genreController.text,
              theme: themeController.text,
              protagonist: protagonistController.text,
              worldview: worldViewController.text,
              content: rawText,
            );
            _outlineService.saveRecord(record);
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
