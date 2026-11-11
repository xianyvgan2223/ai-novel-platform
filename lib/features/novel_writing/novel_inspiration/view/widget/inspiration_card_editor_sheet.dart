// 小说灵感 — 人物卡编辑面板
//
// 支持人物描述（可从已有大纲的人物档案 / 主角简介导入）、各栏全屏放大编辑、
// AI 按已选大纲事件生成当前状态。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../controller/inspiration_controller.dart';
import '../../domain/inspiration_models.dart';
import '../../service/inspiration_import_service.dart';
import '../page/inspiration_text_editor_page.dart';
import 'inspiration_outline_picker.dart';
import 'inspiration_theme.dart';

Future<void> showInspirationCardEditor(
  BuildContext context, {
  required InspirationController controller,
  required int sessionId,
  InspirationCharacterCard? card,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: true,
    isDismissible: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CardEditorSheet(
      controller: controller,
      sessionId: sessionId,
      card: card,
    ),
  );
}

class _CardEditorSheet extends StatefulWidget {
  const _CardEditorSheet({
    required this.controller,
    required this.sessionId,
    this.card,
  });

  final InspirationController controller;
  final int sessionId;
  final InspirationCharacterCard? card;

  @override
  State<_CardEditorSheet> createState() => _CardEditorSheetState();
}

class _CardEditorSheetState extends State<_CardEditorSheet> {
  final InspirationImportService _import = InspirationImportService();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _personality;
  late final TextEditingController _experiences;
  late final TextEditingController _skills;
  late final TextEditingController _status;
  late bool _inject;
  bool _saving = false;
  bool _generatingStatus = false;
  bool _importingDescription = false;

  @override
  void initState() {
    super.initState();
    final c = widget.card;
    _name = TextEditingController(text: c?.name ?? '');
    _description = TextEditingController(text: c?.description ?? '');
    _personality = TextEditingController(text: c?.personality ?? '');
    _experiences = TextEditingController(text: c?.experiences ?? '');
    _skills = TextEditingController(text: c?.skills ?? '');
    _status = TextEditingController(text: c?.status ?? '');
    _inject = c?.inject ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _personality.dispose();
    _experiences.dispose();
    _skills.dispose();
    _status.dispose();
    super.dispose();
  }

  InspirationCharacterCard _currentCard() => InspirationCharacterCard(
    id: widget.card?.id,
    sessionId: widget.sessionId,
    name: _name.text.trim(),
    description: _description.text.trim(),
    personality: _personality.text.trim(),
    experiences: _experiences.text.trim(),
    skills: _skills.text.trim(),
    status: _status.text.trim(),
    inject: _inject,
  );

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      _toast('先给人物起个名字');
      return;
    }
    setState(() => _saving = true);
    await widget.controller.saveCard(_currentCard());
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _generateStatus() async {
    if (_generatingStatus) return;
    if (_name.text.trim().isEmpty) {
      _toast('先填写人物姓名');
      return;
    }
    setState(() => _generatingStatus = true);
    try {
      final status = await widget.controller.generateCardStatus(_currentCard());
      if (!mounted) return;
      _status.text = status.trim();
      setState(() {});
    } catch (e) {
      if (mounted) _toast('AI 生成状态失败：$e');
    } finally {
      if (mounted) setState(() => _generatingStatus = false);
    }
  }

  Future<void> _expandField(
    String label,
    TextEditingController ctrl,
    String hint,
  ) async {
    final text = await editInspirationText(
      context,
      title: '编辑$label',
      initialText: ctrl.text,
      hint: hint,
    );
    if (text != null && mounted) setState(() => ctrl.text = text);
  }

  Future<void> _importDescription() async {
    if (_importingDescription) return;
    setState(() => _importingDescription = true);
    try {
      final outlines = await _import.loadOutlines();
      if (!mounted) return;
      final outline = await showInspirationOutlinePicker(
        context,
        outlines: outlines,
        title: '从大纲导入人物描述',
      );
      if (outline == null || !mounted) return;
      final options = await _import.loadCharacterOptions(outline.id);
      if (!mounted) return;
      if (options.isEmpty) {
        _toast('这部大纲还没有人物资料或主角简介');
        return;
      }
      if (options.length == 1) {
        _applyCharacterOption(options.first);
        return;
      }
      final picked = await _showCharacterOptions(options);
      if (picked != null) _applyCharacterOption(picked);
    } catch (e) {
      if (mounted) _toast('读取大纲人物失败：$e');
    } finally {
      if (mounted) setState(() => _importingDescription = false);
    }
  }

  void _applyCharacterOption(InspirationCharacterOption option) {
    final desc = option.description.trim().isNotEmpty
        ? option.description.trim()
        : option.abilities.trim().isNotEmpty
        ? '能力：${option.abilities.trim()}'
        : option.personality.trim();
    if (desc.isEmpty) {
      _toast('这个人物没有可导入的描述');
      return;
    }
    setState(() => _description.text = desc);
    if (_name.text.trim().isEmpty && option.name.trim().isNotEmpty) {
      _name.text = option.name.trim();
    }
  }

  Future<InspirationCharacterOption?> _showCharacterOptions(
    List<InspirationCharacterOption> options,
  ) {
    final p = inspirationPalette(context.palette);
    return showModalBottomSheet<InspirationCharacterOption>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => InspirationTheme(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          decoration: BoxDecoration(
            color: p.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '选择人物',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: p.textTertiary,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: p.border),
                    itemBuilder: (_, i) {
                      final o = options[i];
                      final text = o.description.trim().isNotEmpty
                          ? o.description.trim()
                          : o.abilities.trim();
                      return InkWell(
                        onTap: () => Navigator.of(ctx).pop(o),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                o.name.trim().isEmpty ? '未命名人物' : o.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: p.textPrimary,
                                ),
                              ),
                              if (text.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.5,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: const TextStyle(fontSize: 12.5))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return InspirationTheme(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        decoration: BoxDecoration(
          color: p.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖动条 / 标题区：向下滑即可关闭这个底部窗口。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) > 200) {
                    FocusScope.of(context).unfocus();
                    Navigator.of(context).pop();
                  }
                },
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: p.borderStrong,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          widget.card == null ? '新增人物卡' : '编辑人物卡',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: p.textTertiary,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        TextButton(
                          onPressed: _saving ? null : _save,
                          child: Text(
                            '保存',
                            style: TextStyle(fontSize: 13, color: p.accent),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _field('姓名', _name, '如：顾泽'),
              _field(
                '人物描述',
                _description,
                '外貌 / 身份 / 背景等；可从大纲导入',
                maxLines: 3,
                onImport: _importingDescription ? null : _importDescription,
                importing: _importingDescription,
              ),
              _field('性格', _personality, '如：嘴硬心软、警惕、护短', maxLines: 2),
              _field(
                '经历过的事件',
                _experiences,
                '自己填写（可概括与本作相关的重要经历）',
                maxLines: 3,
              ),
              _field('技能', _skills, '如：尸潮感知、短刀近战', maxLines: 2),
              Row(
                children: [
                  Text(
                    '当前状态',
                    style: TextStyle(fontSize: 12.5, color: p.textSecondary),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () =>
                        _expandField('当前状态', _status, '如：刚失去同伴，正在寻找仇人'),
                    style: TextButton.styleFrom(
                      foregroundColor: p.textTertiary,
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                    ),
                    icon: const Icon(Icons.open_in_full_rounded, size: 13),
                    label: const Text('放大编辑', style: TextStyle(fontSize: 10.5)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _status,
                minLines: 3,
                maxLines: 5,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: p.textPrimary,
                ),
                decoration: _decoration(p, '如：刚失去同伴，正在寻找仇人'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _generatingStatus ? null : _generateStatus,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.accent,
                        side: BorderSide(
                          color: p.accent.withValues(alpha: 0.5),
                        ),
                        minimumSize: const Size.fromHeight(40),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                      icon: _generatingStatus
                          ? SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.accent,
                              ),
                            )
                          : const Icon(Icons.auto_awesome_rounded, size: 16),
                      label: Text(
                        _generatingStatus ? '推演状态中…' : 'AI 生成当前状态',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    children: [
                      Text(
                        '注入',
                        style: TextStyle(fontSize: 11, color: p.textTertiary),
                      ),
                      Transform.scale(
                        scale: 0.8,
                        child: Switch(
                          value: _inject,
                          activeTrackColor: p.accent,
                          onChanged: (v) => setState(() => _inject = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(AppPalette p, String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 12, color: p.textTertiary),
    filled: true,
    fillColor: p.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: p.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: p.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: p.accent),
    ),
  );

  Widget _field(
    String label,
    TextEditingController ctrl,
    String hint, {
    int maxLines = 1,
    VoidCallback? onImport,
    bool importing = false,
  }) {
    final p = inspirationPalette(context.palette);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
              ),
              const Spacer(),
              if (onImport != null || importing)
                TextButton.icon(
                  onPressed: importing ? null : onImport,
                  style: TextButton.styleFrom(
                    foregroundColor: p.textTertiary,
                    visualDensity: VisualDensity.compact,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                  ),
                  icon: importing
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.4,
                            color: p.textTertiary,
                          ),
                        )
                      : const Icon(Icons.file_download_outlined, size: 13),
                  label: const Text('从大纲导入', style: TextStyle(fontSize: 10.5)),
                ),
              TextButton.icon(
                onPressed: () => _expandField(label, ctrl, hint),
                style: TextButton.styleFrom(
                  foregroundColor: p.textTertiary,
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                ),
                icon: const Icon(Icons.open_in_full_rounded, size: 13),
                label: const Text('放大编辑', style: TextStyle(fontSize: 10.5)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            style: TextStyle(fontSize: 13, height: 1.5, color: p.textPrimary),
            decoration: _decoration(p, hint),
          ),
        ],
      ),
    );
  }
}
