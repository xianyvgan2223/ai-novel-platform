// lib/features/novel_writing/chapter_writing/view/page/outline_setting_page.dart
// 章节写作设置页 — 章节专属配置（与大纲生成设置完全独立）
//
// 布局 v2（本轮重做）：与主设置页 settings_page.dart 同一套视觉语言 ——
// 浅灰页面 + 白色 16dp 圆角卡片 + 卡外分区标题（26dp 图标 chip + 标题 + 副标题），
// 全部组件 / 色值 / 尺寸都来自 core/widgets/settings_kit.dart；本文件只保留
// 「页面结构 + 业务逻辑」，不再出现行内魔法数字 / 灰框输入 / 裸 Slider。
//
// 行为与改造前完全一致：
// - initState 读 chapter_settings 表（OutlineDbHelper.getChapterSettings → fromMap）；
// - 系统提示词为空时回填默认提示词；字数范围空值回填 2000 / 3000；
// - 保存时最少/最多字数按原逻辑解析、兜底（2000/3000）并自动交换顺序；
// - 成功 SnackBar『设置已保存』+ pop；
// - 放大编辑用 kit 的 showSettingsPromptDialog：取消不变更、确定写回 controller。

import 'package:flutter/material.dart';

import '../../../../../core/config/deepseek_models.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../../../core/widgets/settings_kit.dart';
import '../../../shared/data/outline_db_helper.dart';
import '../../../shared/domain/chapter_setting.dart';

/// 章节写作设置页面 — 章节专属配置（与大纲生成设置完全独立）
class ChapterSettingPage extends StatefulWidget {
  const ChapterSettingPage({super.key});

  @override
  State<ChapterSettingPage> createState() => _ChapterSettingPageState();
}

class _ChapterSettingPageState extends State<ChapterSettingPage> {
  // 真实 API 标识由共享常量提供：flash 是 deepseek-flash，pro 是 deepseek-v4-pro
  static const _models = DeepSeekModels.selectableIds;

  double _temperature = 0.8;
  int _maxTokens = 4096;
  String _model = 'deepseek-flash';
  bool _enableThinking = true;

  /// 思考深度由大纲编辑的设置页维护；本页只负责保存时原样带回，避免被覆盖。
  String _reasoningEffort = 'high';
  bool _enableStoryState = true;

  /// 章节字数范围：字数行由 kit 的 SettingsTextRow 自己持有输入框 controller，
  /// 页面只同步保存「当前文本」；保存时仍按改造前的 `_intVal` 语义解析，
  /// 因此空串 / 非数字 / 负数都会落回 2000/3000 兜底值。
  String _chapterMinText = '2000';
  String _chapterMaxText = '3000';

  /// 章节系统提示由页面持有 controller：保存时直接读最新文本，
  /// 放大编辑弹窗也是把结果写回这个 controller（kit 不接管其生命周期）。
  final TextEditingController _chapterSystemCtrl = TextEditingController();

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
        _temperature = setting.temperature;
        _maxTokens = setting.maxTokens;
        _model = setting.model;
        _chapterSystemCtrl.text = setting.chapterSystemPrompt;
        _reasoningEffort = setting.reasoningEffort;
        _chapterMinText = '${setting.chapterMinWords}';
        _chapterMaxText = '${setting.chapterMaxWords}';
        _enableThinking = setting.enableThinking;
        _enableStoryState = setting.enableStoryState;
      }
    } catch (_) {
      // 首次启动 / widget test 下数据库插件可能不可用（MissingPluginException），
      // 落回字段默认值继续渲染即可（业务读取失败与改造前一样静默）。
    }
    if (_chapterSystemCtrl.text.trim().isEmpty) {
      _chapterSystemCtrl.text = _defaultChapterSystemPrompt();
    }
    // 字数范围为空时的 2000 / 3000 回填由字段初值 + fromMap 的默认值保证，
    // 与改造前 `text.isEmpty` 回填的最终取值一致。
    if (mounted) setState(() => _loading = false);
  }

  /// 解析字数文本：非数字或负数落回 fallback（改造前 `_intVal` 原文语义）。
  int _intVal(String text, int fallback) {
    final v = int.tryParse(text);
    return (v != null && v >= 0) ? v : fallback;
  }

  Future<void> _save() async {
    var minWords = _intVal(_chapterMinText, 2000);
    var maxWords = _intVal(_chapterMaxText, 3000);
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
      reasoningEffort: _reasoningEffort,
      enableStoryState: _enableStoryState,
      chapterMinWords: minWords,
      chapterMaxWords: maxWords,
    );
    await OutlineDbHelper().saveChapterSettings(setting.toMap());
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

  String _defaultChapterSystemPrompt() {
    return '你是一个专业的小说作家。';
  }

  /// 放大编辑：把提示词丢进 kit 的 v2 大编辑弹窗。
  /// 语义与改造前一致：取消 / 点遮罩不变更，点「确定」才写回 controller。
  void _openEnlargeEditor() {
    showSettingsPromptDialog(
      context,
      title: '编辑系统提示',
      controller: _chapterSystemCtrl,
      hint: _defaultChapterSystemPrompt(),
    );
  }

  @override
  void dispose() {
    _chapterSystemCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: SettingsAppBar(
        title: '小事件详写设置',
        // 加载中保存按钮显示为禁用态（与改造前 AppBar 的禁用语义一致）。
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
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                // ── 1. 章节系统提示 ──
                const SettingsSectionHeader(
                  icon: Icons.edit_note_rounded,
                  title: '小事件系统提示',
                  subtitle: '写小事件时使用的 AI 指令',
                  isFirst: true,
                ),
                SettingsCard(
                  children: [
                    SettingsPromptCard(
                      icon: Icons.edit_note_rounded,
                      title: '系统提示词',
                      controller: _chapterSystemCtrl,
                      hintText: _defaultChapterSystemPrompt(),
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
                      key: const ValueKey('chapter_model'),
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
                      key: const ValueKey('chapter_enable_thinking'),
                      label: '思考模式',
                      // 行副标题必须 ≤14 个汉字（kit 是单行 + 省略号），
                      // 完整旧文案放在本卡下方的 SettingsNote 里，信息不丢。
                      subtitle: '关闭后更快更省',
                      initialValue: _enableThinking,
                      onChanged: (v) => setState(() => _enableThinking = v),
                    ),
                    SettingsSwitchRow(
                      key: const ValueKey('chapter_enable_story_state'),
                      label: '剧情状态账本',
                      subtitle: '提炼状态伏笔，注入后续小事件',
                      initialValue: _enableStoryState,
                      onChanged: (v) => setState(() => _enableStoryState = v),
                    ),
                    SettingsSliderRow(
                      key: const ValueKey('chapter_temperature'),
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
                      key: const ValueKey('chapter_max_tokens'),
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
                // 思考模式 + 剧情状态账本的完整旧文案（行副标题放不下，
                // 按 spec §2.1 放进说明卡，信息不丢、也不截断）。
                const SizedBox(height: kSettingsSectionGapBot),
                const SettingsNote(
                  text: '思考模式开启后，生成前进行深度思考，输出质量更高但耗时'
                      '更长、消耗更多 token；关闭可显著加快生成速度。\n\n'
                      '剧情状态账本开启后，每写一个小事件自动提炼角色状态、伏笔与悬念，'
                      '注入后续小事件，提升小事件之间的关联度（每次额外一次轻量调用）。',
                ),

                // ── 4. 章节字数 ──
                const SettingsSectionHeader(
                  icon: Icons.format_list_numbered_rounded,
                  title: '小事件字数',
                  subtitle: '小事件字数范围，保存时自动校正顺序',
                ),
                SettingsCard(
                  children: [
                    SettingsTextRow(
                      key: const ValueKey('chapter_min_words'),
                      label: '最少字数',
                      hint: '2000',
                      keyboardType: TextInputType.number,
                      initialValue: _chapterMinText,
                      onChanged: (v) => _chapterMinText = v,
                    ),
                    SettingsTextRow(
                      key: const ValueKey('chapter_max_words'),
                      label: '最多字数',
                      hint: '3000',
                      keyboardType: TextInputType.number,
                      initialValue: _chapterMaxText,
                      onChanged: (v) => _chapterMaxText = v,
                    ),
                  ],
                ),
                // 章节字数范围的旧说明 + 保存时自动校正顺序的语义（说明卡，多行）。
                const SizedBox(height: kSettingsSectionGapBot),
                const SettingsNote(
                  text: '控制每章生成的字数范围，会注入到写作提示词中；'
                      '保存时自动校正最少/最多字数的顺序。',
                ),
              ],
            ),
    );
  }
}
