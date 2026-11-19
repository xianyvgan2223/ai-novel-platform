import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../../../core/config/route_names.dart';
import '../../controller/battle_controller.dart';
import '../../model/battle_model.dart';
import '../../model/db/battle_db_helper.dart';
import 'battle_setting_page.dart';

/// 战斗场景编辑页面 — 查看并修改已生成的内容
class BattleEditPage extends StatefulWidget {
  final int sceneId;
  final BattleController controller;

  const BattleEditPage({
    super.key,
    required this.sceneId,
    required this.controller,
  });

  @override
  State<BattleEditPage> createState() => _BattleEditPageState();
}

class _BattleEditPageState extends State<BattleEditPage> {
  final TextEditingController _skillsCtrl = TextEditingController();
  final TextEditingController _sceneCtrl = TextEditingController();
  final TextEditingController _resultCtrl = TextEditingController();
  final TextEditingController _aiResultCtrl = TextEditingController();
  bool _loading = true;
  int? _sceneId;

  @override
  void initState() {
    super.initState();
    _loadScene();
  }

  Future<void> _loadScene() async {
    try {
      final row = await BattleDbHelper().getScene(widget.sceneId);
      if (row != null) {
        final scene = BattleScene.fromMap(row);
        _sceneId = scene.id;
        _skillsCtrl.text = scene.characterSkills;
        _sceneCtrl.text = scene.battleSceneDesc;
        _resultCtrl.text = scene.battleResult;
        _aiResultCtrl.text = scene.aiResult;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_sceneId == null) return;
    await widget.controller.saveSceneEdit(_sceneId!, {
      'character_skills': _skillsCtrl.text,
      'battle_scene_desc': _sceneCtrl.text,
      'battle_result': _resultCtrl.text,
      'ai_result': _aiResultCtrl.text,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('修改已保存'),
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.of(context).pop(true); // 返回 true 表示有修改
    }
  }

  @override
  void dispose() {
    _skillsCtrl.dispose();
    _sceneCtrl.dispose();
    _resultCtrl.dispose();
    _aiResultCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text(
          '编辑战斗场景',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: p.surface,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              size: 20,
              color: p.textSecondary,
            ),
            tooltip: '战斗设置',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  // 命名路由：让全局悬浮球在战斗设置页隐藏
                  settings: const RouteSettings(name: kBattleSettingsRouteName),
                  builder: (_) => const BattleSettingPage(),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          TextButton(
            onPressed: _loading ? null : _save,
            child: Text(
              '保存',
              style: TextStyle(fontSize: 14, color: p.accent),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 用户输入：技能 ──
                  const _SectionLabel('双方人物技能'),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _skillsCtrl,
                    maxLines: 3,
                    decoration: _editDecoration(context),
                  ),
                  const SizedBox(height: 16),

                  // ── 用户输入：场景 ──
                  const _SectionLabel('战斗场景'),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _sceneCtrl,
                    maxLines: 3,
                    decoration: _editDecoration(context),
                  ),
                  const SizedBox(height: 16),

                  // ── 用户输入：结果 ──
                  const _SectionLabel('战斗结果'),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _resultCtrl,
                    maxLines: 2,
                    decoration: _editDecoration(context),
                  ),
                  const SizedBox(height: 24),

                  // ── AI 生成内容 ──
                  Row(
                    children: [
                      const _SectionLabel('AI 生成内容'),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          _aiResultCtrl.clear();
                        },
                        icon: const Icon(Icons.clear, size: 14),
                        label: const Text('清空', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          foregroundColor: p.textTertiary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _aiResultCtrl,
                    maxLines: 20,
                    decoration: _editDecoration(context).copyWith(
                      hintText: 'AI 生成的内容，可手动修改...',
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.7,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  InputDecoration _editDecoration(BuildContext context) {
    final p = context.palette;
    return InputDecoration(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.borderStrong),
      ),
      contentPadding: const EdgeInsets.all(12),
      filled: true,
      fillColor: p.surfaceMuted,
      isDense: false,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: p.textSecondary,
      ),
    );
  }
}
