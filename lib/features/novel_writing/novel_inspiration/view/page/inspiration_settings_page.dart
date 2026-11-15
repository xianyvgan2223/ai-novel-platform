// 小说灵感 — 设置页
//
// 结构参考「一键生成大纲」设置页；去掉生成检查点，改为「并发生成数量」
// （一次同时生成几个推演，默认 3）。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/config/deepseek_models.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/core/widgets/settings_kit.dart';

import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../../service/inspiration_service.dart';
import '../widget/inspiration_theme.dart';

class InspirationSettingsPage extends StatefulWidget {
  const InspirationSettingsPage({super.key, required this.controller});

  final InspirationController controller;

  @override
  State<InspirationSettingsPage> createState() =>
      _InspirationSettingsPageState();
}

class _InspirationSettingsPageState extends State<InspirationSettingsPage> {
  static const _models = DeepSeekModels.selectableIds;

  late final TextEditingController _systemCtrl;
  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-flash';
  bool _enableThinking = true;
  String _reasoningEffort = 'high';
  String _ttsVoice = 'stella';
  String _ttsEngineId = 'auto';
  double _ttsRate = 1.0;
  bool _showScrollToBottom = true;
  int _concurrency = 3;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.controller.settings;
    _temperature = s.temperature;
    _maxTokens = s.maxTokens;
    _model = DeepSeekModels.toApiId(s.model);
    _enableThinking = s.enableThinking;
    _reasoningEffort = s.reasoningEffort;
    _ttsVoice = s.ttsVoice;
    _ttsEngineId = s.ttsEngineId;
    _ttsRate = s.ttsRate.clamp(0.75, 4.0);
    _showScrollToBottom = s.showScrollToBottom;
    _concurrency = s.concurrency.clamp(1, 10);
    _systemCtrl = TextEditingController(
      text: s.systemPrompt.trim().isEmpty
          ? NovelInspirationPromptTemplate.defaultSystemPrompt
          : s.systemPrompt,
    );
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.controller.saveSettings(
      InspirationSettings(
        model: _model,
        temperature: _temperature,
        maxTokens: _maxTokens,
        systemPrompt: _systemCtrl.text.trim(),
        enableThinking: _enableThinking,
        reasoningEffort: _reasoningEffort,
        ttsVoice: _ttsVoice,
        ttsEngineId: _ttsEngineId,
        ttsRate: _ttsRate,
        showScrollToBottom: _showScrollToBottom,
        concurrency: _concurrency,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    return InspirationTheme(
      child: SettingsAccent(
        color: p.accent,
        soft: p.accentSoft,
        child: Scaffold(
          backgroundColor: p.background,
          appBar: SettingsAppBar(title: '小说灵感设置', onSave: _save),
          body: ListView(
            padding: EdgeInsets.only(
              top: 2,
              left: kSettingsCardMarginH,
              right: kSettingsCardMarginH,
              bottom: 40 + MediaQuery.paddingOf(context).bottom,
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              const SettingsSectionHeader(
                icon: Icons.edit_note_rounded,
                title: '系统提示',
                subtitle: '小说灵感推演时使用的 AI 指令',
                isFirst: true,
              ),
              SettingsCard(
                children: [
                  SettingsPromptCard(
                    icon: Icons.edit_note_rounded,
                    title: '系统提示词',
                    controller: _systemCtrl,
                    hintText:
                        NovelInspirationPromptTemplate.defaultSystemPrompt,
                    minLines: 4,
                    maxLines: 8,
                    onExpand: _openEnlargeEditor,
                  ),
                ],
              ),
              const SettingsSectionHeader(
                icon: Icons.memory_rounded,
                title: '模型选择',
              ),
              SettingsCard(
                children: [
                  SettingsSelectRow(
                    key: const ValueKey('inspiration_model'),
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
              const SettingsSectionHeader(
                icon: Icons.tune_rounded,
                title: '生成参数',
                subtitle: '影响生成速度、精度与输出长度',
              ),
              SettingsCard(
                children: [
                  SettingsSwitchRow(
                    key: const ValueKey('inspiration_enable_thinking'),
                    label: '思考模式',
                    subtitle: '关闭后更快更省',
                    help: '开启后模型先进行推理，再输出推演正文；关闭时请求会显式发送 thinking=disabled。',
                    initialValue: _enableThinking,
                    onChanged: (v) => setState(() => _enableThinking = v),
                  ),
                  SettingsSelectRow(
                    key: const ValueKey('inspiration_reasoning_effort'),
                    label: '思考强度',
                    value: _reasoningEffort,
                    help: 'none 关闭思考；low 快速；high 默认；max 最深。仅思考模式开启时生效。',
                    options: const [
                      SettingsSelectOption('none', 'none · 关闭'),
                      SettingsSelectOption('low', 'low · 快速'),
                      SettingsSelectOption('high', 'high · 默认'),
                      SettingsSelectOption('max', 'max · 最深'),
                    ],
                    onChanged: (v) => setState(() {
                      _reasoningEffort = v;
                      if (v == 'none') _enableThinking = false;
                    }),
                  ),
                  SettingsSliderRow(
                    key: const ValueKey('inspiration_temperature'),
                    label: '温度',
                    subtitle: '数值越高越有创造性',
                    value: _temperature,
                    min: 0,
                    max: 2,
                    divisions: 40,
                    valueLabel: (v) => v.toStringAsFixed(1),
                    onChanged: (v) => setState(() => _temperature = v),
                  ),
                  SettingsTextRow(
                    key: const ValueKey('inspiration_max_tokens'),
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
              const SettingsSectionHeader(
                icon: Icons.volume_up_rounded,
                title: '朗读引擎',
                subtitle: '系统 TTS、本地离线语音或 DeepSeek',
              ),
              SettingsCard(
                children: [
                  SettingsSelectRow(
                    key: const ValueKey('inspiration_tts_engine'),
                    label: '朗读引擎',
                    value: _ttsEngineId,
                    help:
                        '跟随系统：优先调用手机 TTS，系统没有可用引擎时自动用 App 内置离线语音；'
                        '内置离线：强制使用 App 自带模型；DeepSeek：使用官方在线语音。',
                    options: const [
                      SettingsSelectOption(
                        'auto',
                        '跟随系统（本地兜底）',
                        shortLabel: '跟随系统',
                      ),
                      SettingsSelectOption(
                        'builtin',
                        'App 内置离线语音',
                        shortLabel: '内置离线',
                      ),
                      SettingsSelectOption(
                        'deepseek:stella',
                        'DeepSeek · 海星女声',
                        shortLabel: 'DeepSeek 海星',
                      ),
                      SettingsSelectOption(
                        'deepseek:tide',
                        'DeepSeek · 暗潮男声',
                        shortLabel: 'DeepSeek 暗潮',
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _ttsEngineId = v;
                      // 兼容旧字段：DeepSeek 音色同时写到 ttsVoice。
                      if (v == 'deepseek:stella') _ttsVoice = 'stella';
                      if (v == 'deepseek:tide') _ttsVoice = 'tide';
                    }),
                  ),
                  SettingsSelectRow(
                    key: const ValueKey('inspiration_tts_rate'),
                    label: '朗读语速',
                    value: _ttsRate.toString(),
                    help:
                        '0.75x ~ 4.0x。系统 TTS 使用系统语速；DeepSeek WAV 由原生播放层变速。',
                    options: const [
                      SettingsSelectOption('0.75', '0.75x'),
                      SettingsSelectOption('1.0', '1.0x'),
                      SettingsSelectOption('1.25', '1.25x'),
                      SettingsSelectOption('1.5', '1.5x'),
                      SettingsSelectOption('2.0', '2.0x'),
                      SettingsSelectOption('2.5', '2.5x'),
                      SettingsSelectOption('3.0', '3.0x'),
                      SettingsSelectOption('4.0', '4.0x'),
                    ],
                    onChanged: (v) => setState(() {
                      _ttsRate = (double.tryParse(v) ?? 1.0).clamp(0.75, 4.0);
                    }),
                  ),
                ],
              ),
              const SettingsSectionHeader(
                icon: Icons.vertical_align_bottom_rounded,
                title: '阅读体验',
                subtitle: '控制长对话里的回到底部按钮',
              ),
              SettingsCard(
                children: [
                  SettingsSwitchRow(
                    key: const ValueKey('inspiration_show_scroll_to_bottom'),
                    label: '显示「回到底部」',
                    subtitle: '只在没有到底时显示，到底自动隐藏',
                    initialValue: _showScrollToBottom,
                    onChanged: (v) =>
                        setState(() => _showScrollToBottom = v),
                  ),
                ],
              ),
              const SettingsSectionHeader(
                icon: Icons.grid_view_rounded,
                title: '并发生成',
                subtitle: '一次同时推演几个方向',
              ),
              SettingsCard(
                children: [
                  SettingsSliderRow(
                    key: const ValueKey('inspiration_concurrency'),
                    label: '并发生成数量',
                    subtitle: '默认 3',
                    value: _concurrency.toDouble(),
                    min: 1,
                    max: 6,
                    divisions: 5,
                    valueLabel: (v) => '${v.round()} 个',
                    onChanged: (v) =>
                        setState(() => _concurrency = v.round().clamp(1, 6)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEnlargeEditor() {
    showSettingsPromptDialog(
      context,
      title: '编辑系统提示',
      controller: _systemCtrl,
      hint: NovelInspirationPromptTemplate.defaultSystemPrompt,
      accentColor: inspirationPalette(context.palette).accent,
    );
  }
}
