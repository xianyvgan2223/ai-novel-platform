import 'package:flutter/material.dart';

import 'package:deepseekapp/core/config/deepseek_models.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/core/widgets/settings_kit.dart';
import 'package:deepseekapp/features/novel_writing/shared/data/outline_db_helper.dart';
import 'package:deepseekapp/features/novel_writing/shared/domain/chapter_setting.dart';

/// 大纲编辑「AI 生成」设置页。
///
/// 大纲编辑的 AI 生成复用「章节写作设置」里的模型 / 温度 / 最大生成长度 /
/// 思考模式（数据来自 `chapter_settings`），所以这里改的也是同一份设置；
/// 「思考深度」只作用于大纲编辑 AI，不影响章节写作。
/// 页面上用说明文字明确告知，避免用户以为改的是一套独立参数。
///
/// 大纲编辑的系统提示由 `OutlineEditService.buildSystemPrompt` 根据当前大纲、
/// 事件与前后上下文动态生成，因此本页不提供系统提示编辑。
class OutlineEditAiSettingPage extends StatefulWidget {
  const OutlineEditAiSettingPage({super.key});

  @override
  State<OutlineEditAiSettingPage> createState() =>
      _OutlineEditAiSettingPageState();
}

class _OutlineEditAiSettingPageState extends State<OutlineEditAiSettingPage> {
  static const _models = DeepSeekModels.selectableIds;

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-flash';
  bool _enableThinking = true;
  String _reasoningEffort = 'high';

  /// 保存时保留章节写作页自己的其它字段（系统提示、字数、剧情状态账本），
  /// 只覆盖本页展示的四个 AI 参数。
  ChapterSetting _base = const ChapterSetting();
  bool _loading = true;

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
        _base = setting;
        _temperature = setting.temperature;
        _maxTokens = setting.maxTokens;
        _model = setting.model;
        _enableThinking = setting.enableThinking;
        _reasoningEffort = setting.reasoningEffort;
      }
    } catch (_) {
      // 首次启动 / widget test 下数据库不可用：沿用字段默认值继续渲染
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final next = _base.copyWith(
      model: _model,
      temperature: _temperature,
      maxTokens: _maxTokens,
      enableThinking: _enableThinking,
      reasoningEffort: _reasoningEffort,
    );
    await OutlineDbHelper().saveChapterSettings(next.toMap());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pop();
    }
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
        title: 'AI 生成设置',
        onSave: _save,
        saveEnabled: !_loading,
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: p.accent))
          : ListView(
              padding: EdgeInsets.only(
                top: 2,
                left: kSettingsCardMarginH,
                right: kSettingsCardMarginH,
                bottom: 40 + MediaQuery.paddingOf(context).bottom,
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                // ── 模型 ──
                const SettingsSectionHeader(
                  icon: Icons.memory_rounded,
                  title: '模型选择',
                  subtitle: '大纲编辑 AI 生成使用的模型',
                  isFirst: true,
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

                // ── 思考设置 ──
                const SettingsSectionHeader(
                  icon: Icons.psychology_alt_rounded,
                  title: '思考设置',
                  subtitle: '控制大纲生成时的推理深度',
                ),
                SettingsCard(
                  children: [
                    SettingsSwitchRow(
                      label: '思考模式',
                      subtitle: '关闭后更快更省',
                      initialValue: _enableThinking,
                      onChanged: (v) => setState(() => _enableThinking = v),
                    ),
                    SettingsSelectRow(
                      label: '思考深度',
                      value: _reasoningEffort,
                      options: const [
                        SettingsSelectOption('low', '低（更快）'),
                        SettingsSelectOption('high', '标准（推荐）'),
                        SettingsSelectOption('max', '最高（更细）'),
                      ],
                      onChanged: (v) => setState(() => _reasoningEffort = v),
                    ),
                  ],
                ),
                const SettingsNote(
                  text: '思考深度越高，推理更充分，但耗时与消耗的 token 也更多；'
                      '关闭「思考模式」时该设置不生效。',
                ),

                // ── 生成参数 ──
                const SettingsSectionHeader(
                  icon: Icons.tune_rounded,
                  title: '生成参数',
                  subtitle: '控制大纲的创造性与单次输出长度',
                ),
                SettingsCard(
                  children: [
                    SettingsSliderRow(
                      label: '温度',
                      subtitle: '数值越高越有创造性（0~2.0）',
                      value: _temperature,
                      min: 0,
                      max: 2,
                      divisions: 40,
                      valueLabel: (v) => v.toStringAsFixed(1),
                      onChanged: (v) => setState(() => _temperature = v),
                    ),
                    SettingsTextRow(
                      label: '最大生成长度',
                      hint: '1 ~ 384000',
                      keyboardType: TextInputType.number,
                      initialValue: '$_maxTokens',
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null && n >= 1 && n <= 384000) {
                          setState(() => _maxTokens = n);
                        }
                      },
                    ),
                  ],
                ),

                const SettingsNote(
                  text: '模型、温度、最大生成长度与思考模式与「章节写作设置」共用；'
                      '思考深度目前只用于大纲编辑 AI。'
                      '大纲编辑的系统提示由当前大纲、事件与前后上下文自动生成，不在此编辑。',
                ),
              ],
            ),
    );
  }
}
