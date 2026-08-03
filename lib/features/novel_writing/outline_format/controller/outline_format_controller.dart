import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../service/outline_format_service.dart';
import '../../shared/domain/outline_record.dart';

/// 大纲格式匹配控制器，管理业务逻辑与状态
class OutlineFormatController extends ChangeNotifier {
  final inputController = TextEditingController();
  final resultController = TextEditingController();
  final OutlineFormatService _service;

  bool loading = false;
  String? error;
  bool hasFormatted = false;
  String title = '';

  CancelToken? _cancelToken;

  OutlineFormatController({OutlineFormatService? service})
    : _service = service ?? OutlineFormatService();

  /// 执行 AI 格式化
  Future<void> format() async {
    final input = inputController.text.trim();
    if (input.isEmpty) {
      error = '请先输入或粘贴您的大纲内容';
      notifyListeners();
      return;
    }

    loading = true;
    error = null;
    hasFormatted = false;
    title = '';
    notifyListeners();

    try {
      final settings = await _service.loadSettings();
      if (settings.apiKey.isEmpty) {
        error = '请先在设置中填写 API Key';
        loading = false;
        notifyListeners();
        return;
      }

      final systemPrompt = OutlineFormatPromptTemplate.buildSystemPrompt(
        settings.outlineSetting.systemPrompt,
      );
      final prompt = OutlineFormatPromptTemplate.buildFormatPrompt(input);

      String accumulated = '';
      _cancelToken = CancelToken();

      await _service.streamFormat(
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
          resultController.text = accumulated;
          // 提取书名
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
        },
        onDone: () {
          _cancelToken = null;
          loading = false;
          hasFormatted = true;
          if (resultController.text.isNotEmpty &&
              !resultController.text.startsWith('书名：')) {
            resultController.text =
                '书名：《${title.isNotEmpty ? title : '未命名'}》\n\n${resultController.text}';
          }
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

  /// 取消当前格式化
  void cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    loading = false;
    notifyListeners();
  }

  /// 保存格式化结果到大纲记录，成功返回 true
  Future<bool> save() async {
    final content = resultController.text.trim();
    if (content.isEmpty) {
      error = '没有可保存的内容';
      notifyListeners();
      return false;
    }

    try {
      // 提取书名
      final firstLine = content
          .split('\n')
          .firstWhere((l) => l.contains('书名：'), orElse: () => '');
      final recordTitle = firstLine.isNotEmpty
          ? firstLine.replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '').trim()
          : (title.isNotEmpty ? title : '未命名');

      // 从格式化后的大纲中提炼伏笔清单（失败或未配置 Key 时保持为空）
      String foreshadows = '';
      try {
        final settings = await _service.loadSettings();
        if (settings.apiKey.isNotEmpty) {
          foreshadows = await _service.extractForeshadows(
            apiKey: settings.apiKey,
            apiParams: {
              'model': settings.outlineSetting.model,
              'temperature': 0.3,
              'max_tokens': settings.outlineSetting.maxTokens,
            },
            outlineContent: content,
          );
        }
      } catch (_) {}

      final record = OutlineRecord(
        title: recordTitle,
        genre: '',
        theme: '',
        protagonist: '',
        worldview: '',
        content: content,
        foreshadows: foreshadows,
      );

      await _service.saveRecord(record);
      return true;
    } catch (e) {
      error = '保存失败：$e';
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    inputController.dispose();
    resultController.dispose();
    super.dispose();
  }
}
