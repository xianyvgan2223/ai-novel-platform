// 小说灵感 — 世界观 / 主题编辑页
//
// 支持手写、从已有大纲导入、以及逐栏放大到全屏编辑；只影响本灵感会话。

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import '../../controller/inspiration_controller.dart';
import '../../service/inspiration_import_service.dart';
import '../widget/inspiration_outline_picker.dart';
import '../widget/inspiration_theme.dart';
import 'inspiration_text_editor_page.dart';

class InspirationWorldThemeEditPage extends StatefulWidget {
  const InspirationWorldThemeEditPage({super.key, required this.controller});

  final InspirationController controller;

  @override
  State<InspirationWorldThemeEditPage> createState() =>
      _InspirationWorldThemeEditPageState();
}

class _InspirationWorldThemeEditPageState
    extends State<InspirationWorldThemeEditPage> {
  final InspirationImportService _import = InspirationImportService();
  late final TextEditingController _worldCtrl;
  late final TextEditingController _themeCtrl;
  bool _saving = false;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _worldCtrl = TextEditingController(
      text: widget.controller.session?.worldView ?? '',
    );
    _themeCtrl = TextEditingController(
      text: widget.controller.session?.theme ?? '',
    );
  }

  @override
  void dispose() {
    _worldCtrl.dispose();
    _themeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.controller.saveWorldTheme(
      worldView: _worldCtrl.text,
      theme: _themeCtrl.text,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _importFromOutline() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final outlines = await _import.loadOutlines();
      if (!mounted) return;
      final picked = await showInspirationOutlinePicker(
        context,
        outlines: outlines,
        title: '导入世界观与主题',
      );
      if (picked == null || !mounted) return;
      if (picked.worldview.trim().isNotEmpty) {
        _worldCtrl.text = picked.worldview.trim();
      }
      if (picked.theme.trim().isNotEmpty) {
        _themeCtrl.text = picked.theme.trim();
      }
      setState(() {});
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _expandWorld() async {
    final text = await editInspirationText(
      context,
      title: '世界观',
      initialText: _worldCtrl.text,
      hint: '写清世界规则、时代背景、力量体系等',
    );
    if (text != null && mounted) setState(() => _worldCtrl.text = text);
  }

  Future<void> _expandTheme() async {
    final text = await editInspirationText(
      context,
      title: '主题',
      initialText: _themeCtrl.text,
      hint: '一句话写清故事的核心主题',
    );
    if (text != null && mounted) setState(() => _themeCtrl.text = text);
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    return InspirationTheme(
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(Icons.close_rounded, size: 20, color: p.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            '世界观与主题',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: Text(
                '保存',
                style: TextStyle(fontSize: 13, color: p.textPrimary),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _importing ? null : _importFromOutline,
                style: TextButton.styleFrom(
                  foregroundColor: p.textSecondary,
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                ),
                icon: _importing
                    ? SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: p.textTertiary,
                        ),
                      )
                    : const Icon(Icons.file_download_outlined, size: 15),
                label: const Text('从大纲导入', style: TextStyle(fontSize: 11.5)),
              ),
            ),
            _label(p, '世界观', _expandWorld),
            const SizedBox(height: 6),
            _largeField(p, _worldCtrl, minLines: 8, hint: '写清世界规则、时代背景、力量体系等'),
            const SizedBox(height: 22),
            _label(p, '主题', _expandTheme),
            const SizedBox(height: 6),
            _largeField(p, _themeCtrl, minLines: 4, hint: '一句话写清故事的核心主题'),
          ],
        ),
      ),
    );
  }

  Widget _label(AppPalette p, String text, VoidCallback onExpand) {
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: p.textSecondary,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: onExpand,
          style: TextButton.styleFrom(
            foregroundColor: p.textTertiary,
            visualDensity: VisualDensity.compact,
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          ),
          icon: const Icon(Icons.open_in_full_rounded, size: 13),
          label: const Text('放大编辑', style: TextStyle(fontSize: 10.5)),
        ),
      ],
    );
  }

  Widget _largeField(
    AppPalette p,
    TextEditingController ctrl, {
    required int minLines,
    required String hint,
  }) {
    return TextField(
      controller: ctrl,
      minLines: minLines,
      maxLines: 24,
      style: TextStyle(fontSize: 13, height: 1.7, color: p.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 12, color: p.textTertiary),
        filled: true,
        fillColor: p.surface,
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.borderStrong),
        ),
      ),
    );
  }
}
