// lib/features/novel_writing/outline_generation/view/page/outline_setting_page.dart
// 大纲生成设置页 — 大纲专属配置（与章节写作设置完全独立）
//
// 布局 v2（本轮重做）：与主设置页 settings_page.dart 同一套视觉语言 ——
// 浅灰页面 + 白色 16dp 圆角卡片 + 卡外分区标题（26dp 图标 chip + 标题 + 副标题），
// 全部组件 / 色值 / 尺寸都来自 core/widgets/settings_kit.dart；本文件只保留
// 「页面结构 + 业务逻辑」，不再出现行内魔法数字 / 灰框输入 / 裸 Slider。
//
// 行为与改造前完全一致：
// - initState 读 outline_settings 表（OutlineDbHelper.getSettings → fromMap）；
// - 系统提示词为空时回填默认提示词；maxTokens 的显示值来自读库结果；
// - 保存走「读旧行 copyWith 只覆盖本页字段」，保留其余字段的数据库原值；
// - 成功 SnackBar『设置已保存』+ pop；
// - 放大编辑用 kit 的 showSettingsPromptDialog：取消不变更、确定写回 controller。

import 'package:flutter/material.dart';

import '../../../../../core/config/deepseek_models.dart';
import '../../../../../core/widgets/settings_kit.dart';
import '../../../shared/data/outline_db_helper.dart';
import '../../../shared/domain/outline_setting.dart';

/// 大纲生成设置页面 — 大纲专属配置（与章节写作设置完全独立）
class OutlineSettingPage extends StatefulWidget {
  const OutlineSettingPage({super.key});

  @override
  State<OutlineSettingPage> createState() => _OutlineSettingPageState();
}

class _OutlineSettingPageState extends State<OutlineSettingPage> {
  // 真实 API 标识由共享常量提供：flash 是 deepseek-flash，pro 是 deepseek-v4-pro
  static const _models = DeepSeekModels.selectableIds;

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-flash';
  bool _enableThinking = true;
  bool _pauseAfterSkeleton = false;
  bool _pauseAfterEvents = false;
  bool _pauseAfterMinor = false;

  /// 系统提示词由页面持有 controller：保存时直接读最新文本，
  /// 放大编辑弹窗也是把结果写回这个 controller（kit 不接管其生命周期）。
  final TextEditingController _systemCtrl = TextEditingController();

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
        _pauseAfterMinor = setting.pauseAfterMinor;
        _systemCtrl.text = setting.systemPrompt;
      }
    } catch (_) {
      // 首次启动 / widget test 下数据库插件可能不可用（MissingPluginException），
      // 落回字段默认值继续渲染即可（业务读取失败与改造前一样静默）。
    }
    if (_systemCtrl.text.trim().isEmpty) {
      _systemCtrl.text = _defaultSystemPrompt();
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
      pauseAfterMinor: _pauseAfterMinor,
      systemPrompt: _systemCtrl.text,
    );
    await OutlineDbHelper().saveSettings(setting.toMap());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设置已保存'),
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  String _defaultSystemPrompt() {
    return '你是一个专业的小说大纲生成助手，请用纯文本格式输出。';
  }

  /// 放大编辑：把提示词丢进 kit 的 v2 大编辑弹窗。
  /// 语义与改造前一致：取消 / 点遮罩不变更，点「确定」才写回 controller。
  void _openEnlargeEditor() {
    showSettingsPromptDialog(
      context,
      title: '编辑系统提示',
      controller: _systemCtrl,
      hint: _defaultSystemPrompt(),
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
      backgroundColor: kSettingsPageBg,
      appBar: SettingsAppBar(
        title: '大纲生成设置',
        // 加载中保存按钮显示为禁用态（与改造前 AppBar 的禁用语义一致）。
        onSave: _save,
        saveEnabled: !_loading,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kSettingsPrimary))
          : ListView(
              padding: EdgeInsets.only(
                top: 2,
                left: kSettingsCardMarginH,
                right: kSettingsCardMarginH,
                bottom: 40 + MediaQuery.paddingOf(context).bottom,
              ),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                // ── 1. 系统提示 ──
                const SettingsSectionHeader(
                  icon: Icons.edit_note_rounded,
                  title: '系统提示',
                  subtitle: '一键生成大纲时使用的 AI 指令',
                  isFirst: true,
                ),
                SettingsCard(
                  children: [
                    SettingsPromptCard(
                      icon: Icons.edit_note_rounded,
                      title: '系统提示词',
                      controller: _systemCtrl,
                      hintText: _defaultSystemPrompt(),
                      minLines: 4,
                      maxLines: 8,
                      onExpand: _openEnlargeEditor,
                    ),
                  ],
                ),

                // ── 2. 模型 ──
                // 分区标题用「模型选择」，避免与卡片内唯一的行标签「模型」上下重复。
                const SettingsSectionHeader(
                  icon: Icons.memory_rounded,
                  title: '模型选择',
                ),
                SettingsCard(
                  children: [
                    SettingsSelectRow(
                      key: const ValueKey('outline_model'),
                      label: '模型',
                      value: _model,
                      options: [
                        for (final id in _models)
                          SettingsSelectOption(
                            id,
                            DeepSeekModels.toDisplayName(id) ?? id,
                          ),
                      ],
                      onChanged: (v) => setState(() => _model = v),
                    ),
                  ],
                ),

                // ── 3. 生成参数 ──
                const SettingsSectionHeader(
                  icon: Icons.tune_rounded,
                  title: '生成参数',
                  subtitle: '影响生成速度、精度与输出长度',
                ),
                SettingsCard(
                  children: [
                    SettingsSwitchRow(
                      key: const ValueKey('outline_enable_thinking'),
                      label: '思考模式',
                      // 行副标题必须 ≤14 个汉字（kit 是单行 + 省略号），
                      // 完整旧文案放在本卡下方的 SettingsNote 里，信息不丢。
                      subtitle: '关闭后更快更省',
                      initialValue: _enableThinking,
                      onChanged: (v) => setState(() => _enableThinking = v),
                    ),
                    SettingsSliderRow(
                      key: const ValueKey('outline_temperature'),
                      label: '温度',
                      subtitle: '数值越高越有创造性',
                      value: _temperature,
                      min: 0,
                      max: 2,
                      divisions: 40,
                      // 温度步长 0.05，真机习惯看一位小数。
                      valueLabel: (v) => v.toStringAsFixed(1),
                      onChanged: (v) => setState(() => _temperature = v),
                    ),
                    SettingsTextRow(
                      key: const ValueKey('outline_max_tokens'),
                      label: '最大生成长度',
                      hint: '1 ~ 384000',
                      keyboardType: TextInputType.number,
                      initialValue: '$_maxTokens',
                      // 钳制语义与改造前一致：只有 1..384000 的整数才更新内存值，
                      // 非法输入不写入（保存时仍用最后一次合法值）。
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n >= 1 && n <= 384000) {
                          setState(() => _maxTokens = n);
                        }
                      },
                    ),
                  ],
                ),
                // 思考模式的完整旧文案（行副标题放不下，按 spec §2.1 放进说明卡）
                const SizedBox(height: kSettingsSectionGapBot),
                const SettingsNote(
                  text: '思考模式关闭后，模型不再先进行推理思考，max_tokens 全部用于'
                      '正式内容，生成更快更省；复杂任务精度可能略降。',
                ),

                // ── 4. 生成检查点 ──
                const SettingsSectionHeader(
                  icon: Icons.pause_circle_outline_rounded,
                  title: '生成检查点',
                  subtitle: '阶段完成后暂停，可编辑后继续',
                ),
                SettingsCard(
                  children: [
                    SettingsSwitchRow(
                      key: const ValueKey('outline_pause_after_skeleton'),
                      label: '粗骨架检查点',
                      subtitle: '三幕骨架完成后暂停',
                      initialValue: _pauseAfterSkeleton,
                      onChanged: (v) =>
                          setState(() => _pauseAfterSkeleton = v),
                    ),
                    SettingsSwitchRow(
                      key: const ValueKey('outline_pause_after_events'),
                      label: '大事件检查点',
                      subtitle: '大事件精写完成后暂停',
                      initialValue: _pauseAfterEvents,
                      onChanged: (v) => setState(() => _pauseAfterEvents = v),
                    ),
                    SettingsSwitchRow(
                      key: const ValueKey('outline_pause_after_minor'),
                      label: '小事件检查点',
                      subtitle: '小事件全部展开后暂停',
                      initialValue: _pauseAfterMinor,
                      onChanged: (v) => setState(() => _pauseAfterMinor = v),
                    ),
                  ],
                ),
                // 三个检查点的完整旧说明（行副标题放不下，按 spec §2.1 放进说明卡）
                const SizedBox(height: kSettingsSectionGapBot),
                const SettingsNote(
                  text: '开启后对应阶段生成完成即暂停，可编辑或重新生成该阶段内容，'
                      '再手动点击「继续」推进后续流程。',
                ),
              ],
            ),
    );
  }
}
