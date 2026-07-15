import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:deepseekapp/services/api_service.dart';
import 'package:deepseekapp/services/user_setting_service.dart';
import '../../../shared/models/outline_setting.dart';
import '../../../shared/models/outline_record.dart';
import '../../../shared/models/db/outline_record_db_helper.dart';
import '../../../shared/models/db/outline_db_helper.dart';

/// 大纲格式匹配页面
/// 将用户输入的大纲修改为能匹配大纲转章节的内容格式
class OutlineFormatPage extends StatefulWidget {
  const OutlineFormatPage({super.key});

  @override
  State<OutlineFormatPage> createState() => _OutlineFormatPageState();
}

class _OutlineFormatPageState extends State<OutlineFormatPage> {
  final _inputController = TextEditingController();
  final _resultController = TextEditingController();
  final _apiService = ApiService();
  CancelToken? _cancelToken;

  bool _loading = false;
  String? _error;
  bool _hasFormatted = false;
  String _title = '';

  @override
  void dispose() {
    _cancelToken?.cancel();
    _inputController.dispose();
    _resultController.dispose();
    super.dispose();
  }

  Future<void> _format() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请先输入或粘贴您的大纲内容');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _hasFormatted = false;
      _title = '';
    });

    try {
      final global = await UserSettingService.getSettings();
      if (global.apiKey.isEmpty) {
        setState(() {
          _error = '请先在设置中填写 API Key';
          _loading = false;
        });
        return;
      }

      OutlineSetting outlineSetting = const OutlineSetting();
      try {
        final row = await OutlineDbHelper().getSettings();
        if (row != null) outlineSetting = OutlineSetting.fromMap(row);
      } catch (_) {}

      final systemPrompt = outlineSetting.systemPrompt.isNotEmpty
          ? outlineSetting.systemPrompt
          : '你是一个专业的小说大纲格式化助手，请用纯文本格式输出。';

      final prompt =
          '''
你是一个专业的小说大纲格式化工具。请将用户提供的大纲内容，按照以下固定格式重新组织和输出。

固定输出格式要求（严格遵循，不要使用markdown、表格、json或任何标记符号，只输出纯文本）：

1. 第一行：书名：《xxx》（如果原内容有书名则沿用，没有则根据内容提炼一个）
2. 第二行：空行
3. 核心概念简介（30-50字，概括世界观、主角核心困境、故事最终落点）
4. 然后按三幕结构组织内容：

══ 第一幕：开端 ══
══ 大事件1：标题 ══
大事件概述（50-100字）
○ 小事件1：标题
小事件概要（30-50字）
○ 小事件2：标题
小事件概要

══ 第二幕：发展 ══
══ 大事件2：标题 ══
大事件概述
○ 小事件1：标题
小事件概要
...

══ 第三幕：高潮&结局 ══
══ 大事件N：标题 ══
大事件概述
○ 小事件1：标题
小事件概要
...

注意事项：
- 大事件用 ══ 大事件N：标题 ══ 格式
- 小事件用 ○ 小事件N：标题 格式
- 事件概要直接写在标题的下一行，不要加任何前缀符号
- 保留原文中所有有价值的情节信息，不要遗漏重要内容
- 如果原文有明确的三幕划分，请保留；如果没有，请根据内容合理划分
- 保持内容连贯，不要随意增删情节
- 事件数量根据原文内容灵活调整，不要强行凑数

用户的大纲内容如下：
---
$input
---
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
          _resultController.text = accumulated;
          // 提取书名
          if (_title.isEmpty) {
            final firstLine = accumulated
                .split('\n')
                .firstWhere((l) => l.contains('书名：'), orElse: () => '');
            if (firstLine.isNotEmpty) {
              _title = firstLine
                  .replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '')
                  .trim();
            }
          }
          if (mounted) setState(() {});
        },
        onDone: () {
          _cancelToken = null;
          if (mounted) {
            setState(() {
              _loading = false;
              _hasFormatted = true;
              if (_resultController.text.isNotEmpty &&
                  !_resultController.text.startsWith('书名：')) {
                _resultController.text =
                    '书名：《${_title.isNotEmpty ? _title : '未命名'}》\n\n${_resultController.text}';
              }
            });
          }
        },
        onError: (errorMsg) {
          _cancelToken = null;
          if (mounted) {
            setState(() {
              _error = errorMsg;
              _loading = false;
            });
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  void _cancel() {
    _cancelToken?.cancel();
    _cancelToken = null;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final content = _resultController.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '没有可保存的内容');
      return;
    }

    try {
      // 提取书名
      final firstLine = content
          .split('\n')
          .firstWhere((l) => l.contains('书名：'), orElse: () => '');
      final title = firstLine.isNotEmpty
          ? firstLine.replaceAll(RegExp(r'^(书名：|《|》|\s)*'), '').trim()
          : (_title.isNotEmpty ? _title : '未命名');

      final record = OutlineRecord(
        title: title,
        genre: '',
        theme: '',
        protagonist: '',
        worldview: '',
        content: content,
      );

      await OutlineRecordDbHelper().insert(record.toMap());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('大纲已保存，可前往「大纲转章节」使用'),
            backgroundColor: Color(0xFF4D6BFE),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '保存失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '匹配大纲格式',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 说明文字
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF4D6BFE).withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: Color(0xFF4D6BFE), size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '在此粘贴您已有的大纲，点击「AI 格式化」后系统会自动将其转换为「大纲转章节」功能所需的格式。格式化后您还可以手动编辑调整。',
                      style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 输入区域
            const Text(
              '输入大纲内容',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _inputController,
              maxLines: 10,
              decoration: InputDecoration(
                hintText: '请粘贴或输入您的大纲内容...',
                hintStyle: const TextStyle(color: Color(0xFFCCCCCC)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF4D6BFE)),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
              style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
            ),
            const SizedBox(height: 12),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _loading ? null : _format,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(_loading ? '格式化中...' : 'AI 格式化'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4D6BFE),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(
                        0xFF4D6BFE,
                      ).withValues(alpha: 0.6),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 15)),
                  ),
                ],
              ],
            ),

            // 错误提示
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            ],

            // 格式化结果
            if (_hasFormatted || _resultController.text.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '格式化结果（可编辑）',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          _resultController.text = _inputController.text;
                          setState(() => _hasFormatted = true);
                        },
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text(
                          '还原原文',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF999999),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('保存', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF4D6BFE),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _resultController,
                maxLines: 20,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF4D6BFE)),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
                style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
              ),
              const SizedBox(height: 12),
              // 保存按钮（底部大按钮）
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('保存到大纲记录'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4D6BFE),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '保存后可在「大纲转章节」中选择此大纲生成章节内容',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
