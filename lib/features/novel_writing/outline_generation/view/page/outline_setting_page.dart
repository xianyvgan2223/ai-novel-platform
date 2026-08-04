import 'package:flutter/material.dart';
import '../../../shared/domain/outline_setting.dart';
import '../../../shared/data/outline_db_helper.dart';

/// 大纲生成设置页面 — 大纲专属配置（与章节写作设置完全独立）
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
  bool _enableThinking = true;
  bool _pauseAfterSkeleton = false;
  bool _pauseAfterEvents = false;
  final TextEditingController _systemCtrl = TextEditingController();
  final TextEditingController _maxTokensCtrl = TextEditingController();

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
        _enableThinking = setting.enableThinking;
        _pauseAfterSkeleton = setting.pauseAfterSkeleton;
        _pauseAfterEvents = setting.pauseAfterEvents;
        _systemCtrl.text = setting.systemPrompt;
        _maxTokensCtrl.text = '${setting.maxTokens}';
      }
    } catch (_) {}
    if (_systemCtrl.text.trim().isEmpty) {
      _systemCtrl.text = _defaultSystemPrompt();
    }
    if (_maxTokensCtrl.text.isEmpty) {
      _maxTokensCtrl.text = '$_maxTokens';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    // 只覆盖本页保留的字段，其余字段保留数据库原值（章节设置已独立成表，互不影响）
    final existing = await OutlineDbHelper().getSettings();
    final base = existing != null
        ? OutlineSetting.fromMap(existing)
        : const OutlineSetting();
    final setting = base.copyWith(
      temperature: _temperature,
      maxTokens: _maxTokens,
      model: _model,
      enableThinking: _enableThinking,
      pauseAfterSkeleton: _pauseAfterSkeleton,
      pauseAfterEvents: _pauseAfterEvents,
      systemPrompt: _systemCtrl.text,
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
    _maxTokensCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '大纲生成设置',
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
                //  思考模式
                // ════════════════════════════════════════
                const Text(
                  '思考模式',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '关闭后模型不再先进行推理思考，max_tokens 全部用于正式内容，生成更快更省；复杂任务精度可能略降',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _enableThinking ? '开启思考' : '关闭思考',
                    style: const TextStyle(fontSize: 14),
                  ),
                  value: _enableThinking,
                  activeTrackColor: const Color(0xFF4D6BFE),
                  onChanged: (v) => setState(() => _enableThinking = v),
                ),
                const SizedBox(height: 24),

                // ════════════════════════════════════════
                //  生成检查点
                // ════════════════════════════════════════
                const Text(
                  '生成检查点',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '开启后，对应阶段生成完成即暂停，可编辑或重新生成该阶段内容，再手动点击「继续」',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('粗骨架检查点', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '三幕粗骨架生成完成后暂停，可编辑/重新生成骨架再继续',
                    style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                  ),
                  value: _pauseAfterSkeleton,
                  activeTrackColor: const Color(0xFF4D6BFE),
                  onChanged: (v) =>
                      setState(() => _pauseAfterSkeleton = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('大事件检查点', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '大事件精写（含伏笔账本）完成后暂停，可编辑/重新生成大事件再继续',
                    style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                  ),
                  value: _pauseAfterEvents,
                  activeTrackColor: const Color(0xFF4D6BFE),
                  onChanged: (v) => setState(() => _pauseAfterEvents = v),
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
}
