import 'package:flutter/material.dart';
import '../../model/outline_setting.dart';
import '../../model/db/outline_db_helper.dart';

/// 大纲生成设置页面 — 温度、最大长度、模型选择、系统提示、字数配置
class OutlineSettingPage extends StatefulWidget {
  const OutlineSettingPage({super.key});

  @override
  State<OutlineSettingPage> createState() => _OutlineSettingPageState();
}

class _OutlineSettingPageState extends State<OutlineSettingPage> {
  static const _models = ['deepseek-v4-flash', 'deepseek-v4-pro'];

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-v4-flash';
  final TextEditingController _systemCtrl = TextEditingController();
  final TextEditingController _chapterSystemCtrl = TextEditingController();
  final TextEditingController _maxTokensCtrl = TextEditingController();

  // 字数配置
  final TextEditingController _conceptMinCtrl = TextEditingController();
  final TextEditingController _conceptMaxCtrl = TextEditingController();
  final TextEditingController _majorEventMinCtrl = TextEditingController();
  final TextEditingController _majorEventMaxCtrl = TextEditingController();
  final TextEditingController _minorEventMinCtrl = TextEditingController();
  final TextEditingController _minorEventMaxCtrl = TextEditingController();
  final TextEditingController _summaryMaxCtrl = TextEditingController();

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final row = await OutlineDbHelper().getSettings();
      if (row != null) {
        final setting = OutlineSetting.fromMap(row);
        _temperature = setting.temperature;
        _maxTokens = setting.maxTokens;
        _model = setting.model;
        _systemCtrl.text = setting.systemPrompt;
        _chapterSystemCtrl.text = setting.chapterSystemPrompt;
        _maxTokensCtrl.text = '${setting.maxTokens}';
        _conceptMinCtrl.text = '${setting.conceptMinWords}';
        _conceptMaxCtrl.text = '${setting.conceptMaxWords}';
        _majorEventMinCtrl.text = '${setting.majorEventMinWords}';
        _majorEventMaxCtrl.text = '${setting.majorEventMaxWords}';
        _minorEventMinCtrl.text = '${setting.minorEventMinWords}';
        _minorEventMaxCtrl.text = '${setting.minorEventMaxWords}';
        _summaryMaxCtrl.text = '${setting.summaryMaxWords}';
      }
    } catch (_) {}
    if (_systemCtrl.text.trim().isEmpty) {
      _systemCtrl.text = _defaultSystemPrompt();
    }
    if (_chapterSystemCtrl.text.trim().isEmpty) {
      _chapterSystemCtrl.text = _defaultChapterSystemPrompt();
    }
    if (_maxTokensCtrl.text.isEmpty) {
      _maxTokensCtrl.text = '$_maxTokens';
    }
    // 字数默认值填充
    if (_conceptMinCtrl.text.isEmpty) _conceptMinCtrl.text = '30';
    if (_conceptMaxCtrl.text.isEmpty) _conceptMaxCtrl.text = '50';
    if (_majorEventMinCtrl.text.isEmpty) _majorEventMinCtrl.text = '50';
    if (_majorEventMaxCtrl.text.isEmpty) _majorEventMaxCtrl.text = '100';
    if (_minorEventMinCtrl.text.isEmpty) _minorEventMinCtrl.text = '30';
    if (_minorEventMaxCtrl.text.isEmpty) _minorEventMaxCtrl.text = '50';
    if (_summaryMaxCtrl.text.isEmpty) _summaryMaxCtrl.text = '80';
    if (mounted) setState(() => _loading = false);
  }

  int _intVal(TextEditingController ctrl, int fallback) {
    final v = int.tryParse(ctrl.text);
    return (v != null && v >= 0) ? v : fallback;
  }

  Future<void> _save() async {
    final setting = OutlineSetting(
      temperature: _temperature,
      maxTokens: _maxTokens,
      model: _model,
      systemPrompt: _systemCtrl.text,
      chapterSystemPrompt: _chapterSystemCtrl.text,
      conceptMinWords: _intVal(_conceptMinCtrl, 30),
      conceptMaxWords: _intVal(_conceptMaxCtrl, 50),
      majorEventMinWords: _intVal(_majorEventMinCtrl, 50),
      majorEventMaxWords: _intVal(_majorEventMaxCtrl, 100),
      minorEventMinWords: _intVal(_minorEventMinCtrl, 30),
      minorEventMaxWords: _intVal(_minorEventMaxCtrl, 50),
      summaryMaxWords: _intVal(_summaryMaxCtrl, 80),
    );
    await OutlineDbHelper().saveSettings(setting.toMap());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pop();
    }
  }

  String _defaultSystemPrompt() {
    return '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';
  }

  String _defaultChapterSystemPrompt() {
    return '你是一个专业的小说作家。';
  }

  void _showEnlargeDialog({
    required TextEditingController targetCtrl,
    required String hintText,
    required Color accentColor,
  }) {
    final editCtrl = TextEditingController(text: targetCtrl.text);
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text(
          '编辑系统提示',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: screenHeight * 0.72,
            maxWidth: screenWidth * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle: const TextStyle(
                fontSize: 13,
                color: Color(0xFFBBBBBB),
                height: 1.5,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 10, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => editCtrl.dispose(),
              );
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              targetCtrl.text = editCtrl.text;
              Navigator.of(ctx).pop();
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => editCtrl.dispose(),
              );
            },
            child: Text(
              '确定',
              style: TextStyle(fontSize: 12, color: accentColor),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    _chapterSystemCtrl.dispose();
    _maxTokensCtrl.dispose();
    _conceptMinCtrl.dispose();
    _conceptMaxCtrl.dispose();
    _majorEventMinCtrl.dispose();
    _majorEventMaxCtrl.dispose();
    _minorEventMinCtrl.dispose();
    _minorEventMaxCtrl.dispose();
    _summaryMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '大纲/章节设置',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _loading ? null : _save,
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ════════════════════════════════════════
                //  字数配置
                // ════════════════════════════════════════
                const Text(
                  '字数配置',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '控制生成大纲中各部分内容的字数范围',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 12),

                // 核心概念简介
                _buildWordRangeRow(
                  label: '核心概念简介',
                  minCtrl: _conceptMinCtrl,
                  maxCtrl: _conceptMaxCtrl,
                  hint: '30-50字',
                ),
                const SizedBox(height: 12),

                // 大事件概述
                _buildWordRangeRow(
                  label: '大事件概述',
                  minCtrl: _majorEventMinCtrl,
                  maxCtrl: _majorEventMaxCtrl,
                  hint: '50-100字',
                ),
                const SizedBox(height: 12),

                // 小事件概要
                _buildWordRangeRow(
                  label: '小事件概要',
                  minCtrl: _minorEventMinCtrl,
                  maxCtrl: _minorEventMaxCtrl,
                  hint: '30-50字',
                ),
                const SizedBox(height: 12),

                // 人物成长总结
                _buildSingleWordRow(
                  label: '人物成长总结',
                  ctrl: _summaryMaxCtrl,
                  hint: '80字内',
                  suffix: '字以内',
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  大纲生成系统提示
                // ════════════════════════════════════════
                const Text(
                  '大纲生成 · 系统提示',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '一键生成大纲时使用的 AI 指令',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _systemCtrl,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: _defaultSystemPrompt(),
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFBBBBBB),
                      height: 1.5,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                    filled: true,
                    fillColor: const Color(0xFFFAFAFA),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: '放大编辑',
                      color: const Color(0xFF999999),
                      onPressed: () => _showEnlargeDialog(
                        targetCtrl: _systemCtrl,
                        hintText: _defaultSystemPrompt(),
                        accentColor: const Color(0xFF4D6BFE),
                      ),
                    ),
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  章节写作系统提示
                // ════════════════════════════════════════
                const Text(
                  '章节写作 · 系统提示',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '大纲转章节写正文时使用的 AI 指令',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _chapterSystemCtrl,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: _defaultChapterSystemPrompt(),
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFBBBBBB),
                      height: 1.5,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                    filled: true,
                    fillColor: const Color(0xFFFAFAFA),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: '放大编辑',
                      color: const Color(0xFF999999),
                      onPressed: () => _showEnlargeDialog(
                        targetCtrl: _chapterSystemCtrl,
                        hintText: _defaultChapterSystemPrompt(),
                        accentColor: const Color(0xFF4D6BFE),
                      ),
                    ),
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  模型选择
                // ════════════════════════════════════════
                const Text(
                  'AI 模型',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 8),
                Column(
                  children: _models
                      .map(
                        (m) => InkWell(
                          onTap: () => setState(() => _model = m),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Radio<String>(
                                  value: m,
                                  groupValue: _model,
                                  activeColor: const Color(0xFF4D6BFE),
                                  onChanged: (v) {
                                    if (v != null) setState(() => _model = v);
                                  },
                                ),
                                const SizedBox(width: 4),
                                Text(m, style: const TextStyle(fontSize: 14)),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  温度
                // ════════════════════════════════════════
                const Text(
                  '温度 (Temperature)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '数值越高，输出越有创造性（0.0 ~ 2.0）',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                Slider(
                  value: _temperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  activeColor: const Color(0xFF4D6BFE),
                  label: _temperature.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _temperature = v),
                ),
                Text(
                  _temperature.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  最大长度
                // ════════════════════════════════════════
                const Text(
                  '最大生成长度 (Max Tokens)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '单次生成的最大 token 数',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _maxTokensCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '输入最大 token 数',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                    filled: true,
                    fillColor: const Color(0xFFFAFAFA),
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1 && n <= 384000) {
                      setState(() => _maxTokens = n);
                    }
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildWordRangeRow({
    required String label,
    required TextEditingController minCtrl,
    required TextEditingController maxCtrl,
    required String hint,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 105,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
          ),
        ),
        const Text(
          '最少',
          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 56,
          child: TextField(
            controller: minCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '30',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 6,
              ),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          '字',
          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
        const SizedBox(width: 8),
        const Text(
          '最多',
          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 56,
          child: TextField(
            controller: maxCtrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '50',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 6,
              ),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          '字',
          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
      ],
    );
  }

  Widget _buildSingleWordRow({
    required String label,
    required TextEditingController ctrl,
    required String hint,
    required String suffix,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 105,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
          ),
        ),
        SizedBox(
          width: 56,
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: hint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 6,
              ),
              filled: true,
              fillColor: const Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          suffix,
          style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
      ],
    );
  }
}
