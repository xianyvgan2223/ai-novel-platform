import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../model/battle_model.dart';
import '../../model/db/battle_db_helper.dart';
import '../../service/battle_ai_service.dart';

/// 战斗场景设置页面 — 温度、最大长度、模型选择
class BattleSettingPage extends StatefulWidget {
  const BattleSettingPage({super.key});

  @override
  State<BattleSettingPage> createState() => _BattleSettingPageState();
}

class _BattleSettingPageState extends State<BattleSettingPage> {
  static const _models = ['deepseek-v4-flash', 'deepseek-v4-pro'];

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-v4-flash';
  final TextEditingController _systemCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final row = await BattleDbHelper().getSettings();
      if (row != null) {
        final setting = BattleSetting.fromMap(row);
        _temperature = setting.temperature;
        _maxTokens = setting.maxTokens;
        _model = setting.model;
        _systemCtrl.text = setting.systemPrompt;
      }
    } catch (_) {}
    // 如果系统提示为空，填入默认提示词方便用户编辑修改
    if (_systemCtrl.text.trim().isEmpty) {
      _systemCtrl.text = BattleAiService.buildSystemPrompt();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final setting = BattleSetting(
      temperature: _temperature,
      maxTokens: _maxTokens,
      model: _model,
      systemPrompt: _systemCtrl.text,
    );
    await BattleDbHelper().saveSettings(setting.toMap());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pop();
    }
  }

  /// 弹出大编辑框方便编辑系统提示
  void _showEnlargeDialog() {
    final editCtrl = TextEditingController(text: _systemCtrl.text);
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
              hintText: BattleAiService.buildSystemPrompt(),
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
              _systemCtrl.text = editCtrl.text;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text(
              '确定',
              style: TextStyle(fontSize: 12, color: Color(0xFFFF5722)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '战斗设置',
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
              style: TextStyle(fontSize: 14, color: Color(0xFFFF5722)),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 系统提示 ──
                const Text(
                  '系统提示 (System Prompt)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '自定义 AI 的指令，为空时使用默认战斗提示',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _systemCtrl,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: BattleAiService.buildSystemPrompt(),
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
                      onPressed: () => _showEnlargeDialog(),
                    ),
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 24),

                // ── 模型选择 ──
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
                                  activeColor: const Color(0xFFFF5722),
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

                // ── 温度 ──
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
                  activeColor: const Color(0xFFFF5722),
                  label: _temperature.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _temperature = v),
                ),
                Text(
                  _temperature.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFF5722),
                  ),
                ),
                const SizedBox(height: 24),

                // ── 最大长度 ──
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
                Slider(
                  value: _maxTokens.toDouble(),
                  min: 512,
                  max: 8192,
                  divisions: 15,
                  activeColor: const Color(0xFFFF5722),
                  label: _maxTokens.toString(),
                  onChanged: (v) => setState(() => _maxTokens = v.round()),
                ),
                Text(
                  '$_maxTokens',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFF5722),
                  ),
                ),
              ],
            ),
    );
  }
}
