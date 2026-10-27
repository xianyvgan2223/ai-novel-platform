/// 战斗场景设置页面 — 系统提示、模型、温度、最大生成长度
///
/// 视觉：与主设置页 v2 完全一致（浅灰页面 + 白色圆角卡片 + 卡外分区标题），
/// 组件 / 色值 / 尺寸全部来自 core/widgets/settings_kit.dart：
/// - 主色统一为 [kSettingsPrimary]（去掉了旧版橙色 #FF5722：保存胶囊 / 滑杆 /
///   选中态 / 数值全部走主色）；
/// - 系统提示改成焦点输入卡（填充输入框 + 放大编辑），不再画大段浅灰框；
/// - 模型从单选列表改成整行可点的下拉选择；
/// - 温度 / 最大生成长度从「裸 Slider + 下方大号数字」改成
///   SettingsSliderRow（标签 + 右上角主色数值 + 全宽滑杆）。
///
/// 行为与改造前一致：initState 调 BattleDbHelper.getSettings → BattleSetting.fromMap
/// 回填；空提示词填 BattleAiService.buildSystemPrompt()；保存用 BattleSetting +
/// saveSettings，SnackBar『设置已保存』后 pop。
library;

import 'package:flutter/material.dart';

import '../../../../../core/config/deepseek_models.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../../../core/widgets/settings_kit.dart';
import '../../model/battle_model.dart';
import '../../model/db/battle_db_helper.dart';
import '../../service/battle_ai_service.dart';

class BattleSettingPage extends StatefulWidget {
  const BattleSettingPage({super.key});

  @override
  State<BattleSettingPage> createState() => _BattleSettingPageState();
}

class _BattleSettingPageState extends State<BattleSettingPage> {
  // 真实 API 标识由共享常量提供：flash 是 deepseek-flash，pro 是 deepseek-v4-pro
  static const _models = DeepSeekModels.selectableIds;

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-flash';
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

  /// 放大编辑：替换旧的自绘 AlertDialog，改用 kit 的 v2 大编辑弹窗。
  /// 语义不变：取消不变更，确定才把文本写回 controller。
  void _openEnlargeEditor() {
    showSettingsPromptDialog(
      context,
      title: '编辑系统提示',
      controller: _systemCtrl,
      hint: BattleAiService.buildSystemPrompt(),
    );
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final modelOptions = [
      for (final id in _models)
        SettingsSelectOption(id, DeepSeekModels.toDisplayName(id) ?? id),
    ];

    return Scaffold(
      backgroundColor: p.background,
      appBar: SettingsAppBar(
        title: '战斗设置',
        // 与改造前一致：加载中「保存」仍占位，但置灰不可点。
        onSave: _save,
        saveEnabled: !_loading,
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: p.accent),
            )
          : ListView(
              padding: EdgeInsets.only(
                top: 2,
                left: kSettingsCardMarginH,
                right: kSettingsCardMarginH,
                bottom: 40 + MediaQuery.paddingOf(context).bottom,
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                // ── 1. 系统提示 ──
                const SettingsSectionHeader(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: '系统提示',
                  subtitle: '自定义 AI 的战斗指令，留空使用默认',
                  isFirst: true,
                ),
                SettingsCard(
                  children: [
                    SettingsPromptCard(
                      icon: Icons.edit_note_rounded,
                      title: '系统提示词',
                      controller: _systemCtrl,
                      hintText: BattleAiService.buildSystemPrompt(),
                      minLines: 5,
                      maxLines: 10,
                      onExpand: _openEnlargeEditor,
                    ),
                  ],
                ),

                // ── 2. 模型选择（分区标题与行标签分开，避免同名重复）──
                const SettingsSectionHeader(
                  icon: Icons.memory_rounded,
                  title: '模型选择',
                  subtitle: '选择战斗场景生成使用的模型',
                ),
                SettingsCard(
                  children: [
                    SettingsSelectRow(
                      label: '模型',
                      value: _model,
                      options: modelOptions,
                      onChanged: (v) => setState(() => _model = v),
                    ),
                  ],
                ),

                // ── 3. 生成参数 ──
                const SettingsSectionHeader(
                  icon: Icons.tune_rounded,
                  title: '生成参数',
                  subtitle: '影响战斗描写的创造性与长度',
                ),
                SettingsCard(
                  children: [
                    SettingsSliderRow(
                      label: '温度',
                      // 旧版副标题「数值越高，输出越有创造性（0.0 ~ 2.0）」：
                      // 单行副标题要 ≤14 汉字（spec §2.1），这里压缩成
                      // 「…（0~2.0）」，取值范围信息不丢。
                      subtitle: '数值越高，输出越有创造性（0~2.0）',
                      value: _temperature,
                      min: 0,
                      max: 2,
                      divisions: 40,
                      valueLabel: (v) => v.toStringAsFixed(1),
                      onChanged: (v) => setState(() => _temperature = v),
                    ),
                    SettingsSliderRow(
                      label: '最大生成长度',
                      subtitle: '单次生成的最大 token 数',
                      value: _maxTokens.toDouble(),
                      min: 512,
                      max: 8192,
                      divisions: 15,
                      valueLabel: (v) => v.round().toString(),
                      onChanged: (v) =>
                          setState(() => _maxTokens = v.round()),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
