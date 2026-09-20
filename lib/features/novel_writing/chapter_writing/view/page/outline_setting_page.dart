import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/chapter_setting.dart';
import '../../../shared/data/outline_db_helper.dart';

/// 章节写作设置页面 — 章节专属配置（与大纲生成设置完全独立）
class ChapterSettingPage extends StatefulWidget {
  const ChapterSettingPage({super.key});

  @override
  State<ChapterSettingPage> createState() => _ChapterSettingPageState();
}

class _ChapterSettingPageState extends State<ChapterSettingPage> {
  static const _models = ['deepseek-v4-flash', 'deepseek-v4-pro'];

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-v4-flash';
  final TextEditingController _chapterSystemCtrl = TextEditingController();
  final TextEditingController _maxTokensCtrl = TextEditingController();
  final TextEditingController _chapterMinCtrl = TextEditingController();
  final TextEditingController _chapterMaxCtrl = TextEditingController();

  bool _loading = true;
  bool _enableThinking = true;
  bool _enableStoryState = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final row = await OutlineDbHelper().getChapterSettings();
      if (row != null) {
        final setting = ChapterSetting.fromMap(row);
        _temperature = setting.temperature;
        _maxTokens = setting.maxTokens;
        _model = setting.model;
        _chapterSystemCtrl.text = setting.chapterSystemPrompt;
        _maxTokensCtrl.text = '${setting.maxTokens}';
        _chapterMinCtrl.text = '${setting.chapterMinWords}';
        _chapterMaxCtrl.text = '${setting.chapterMaxWords}';
        _enableThinking = setting.enableThinking;
        _enableStoryState = setting.enableStoryState;
      }
    } catch (_) {}
    if (_chapterSystemCtrl.text.trim().isEmpty) {
      _chapterSystemCtrl.text = _defaultChapterSystemPrompt();
    }
    if (_maxTokensCtrl.text.isEmpty) {
      _maxTokensCtrl.text = '$_maxTokens';
    }
    if (_chapterMinCtrl.text.isEmpty) _chapterMinCtrl.text = '2000';
    if (_chapterMaxCtrl.text.isEmpty) _chapterMaxCtrl.text = '3000';
    if (mounted) setState(() => _loading = false);
  }

  int _intVal(TextEditingController ctrl, int fallback) {
    final v = int.tryParse(ctrl.text);
    return (v != null && v >= 0) ? v : fallback;
  }

  Future<void> _save() async {
    var minWords = _intVal(_chapterMinCtrl, 2000);
    var maxWords = _intVal(_chapterMaxCtrl, 3000);
    if (minWords > maxWords) {
      final t = minWords;
      minWords = maxWords;
      maxWords = t;
    }
    final setting = ChapterSetting(
      temperature: _temperature,
      maxTokens: _maxTokens,
      model: _model,
      chapterSystemPrompt: _chapterSystemCtrl.text,
      enableThinking: _enableThinking,
      enableStoryState: _enableStoryState,
      chapterMinWords: minWords,
      chapterMaxWords: maxWords,
    );
    await OutlineDbHelper().saveChapterSettings(setting.toMap());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pop();
    }
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
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(editCtrl);
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
              if (!closeDialogSafely(ctx)) return;
              targetCtrl.text = editCtrl.text;
              scheduleControllerDispose(editCtrl);
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
    _chapterSystemCtrl.dispose();
    _maxTokensCtrl.dispose();
    _chapterMinCtrl.dispose();
    _chapterMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '章节写作设置',
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
                //  章节字数范围
                // ════════════════════════════════════════
                const Text(
                  '章节字数',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '控制每章生成的字数范围，会注入到写作提示词中',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 12),
                _buildWordRangeRow(
                  label: '单章字数',
                  minCtrl: _chapterMinCtrl,
                  maxCtrl: _chapterMaxCtrl,
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
                //  剧情状态账本开关
                // ════════════════════════════════════════
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '剧情状态账本',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF333333),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '每写一章后自动提炼角色状态、伏笔与悬念，注入后续章节，提升章节关联度（每章额外一次轻量调用）',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _enableStoryState,
                      activeTrackColor: const Color(0xFF4D6BFE),
                      onChanged: (v) => setState(() => _enableStoryState = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ════════════════════════════════════════
                //  深度思考开关
                // ════════════════════════════════════════
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '深度思考',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF333333),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '生成前进行深度思考，输出质量更高但耗时更长、消耗更多 token；关闭可显著加快生成速度',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _enableThinking,
                      activeTrackColor: const Color(0xFF4D6BFE),
                      onChanged: (v) => setState(() => _enableThinking = v),
                    ),
                  ],
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

  /// 最少/最多字数输入行
  Widget _buildWordRangeRow({
    required String label,
    required TextEditingController minCtrl,
    required TextEditingController maxCtrl,
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
              hintText: '2000',
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
              hintText: '3000',
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
}
