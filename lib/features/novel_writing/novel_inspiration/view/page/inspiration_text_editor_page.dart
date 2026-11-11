// 小说灵感 — 通用全屏文本编辑页（世界观 / 主题 / 人物卡各栏「放大编辑」用）
//
// 黑色极简、字号比列表页更大，适合长文本编辑；返回编辑后的文本。

import 'package:flutter/material.dart';

import 'package:deepseekapp/core/theme/app_palette.dart';
import '../widget/inspiration_theme.dart';

class InspirationTextEditorPage extends StatefulWidget {
  const InspirationTextEditorPage({
    super.key,
    required this.title,
    required this.initialText,
    this.hint = '',
  });

  final String title;
  final String initialText;
  final String hint;

  @override
  State<InspirationTextEditorPage> createState() =>
      _InspirationTextEditorPageState();
}

class _InspirationTextEditorPageState extends State<InspirationTextEditorPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = inspirationPalette(context.palette);
    final count = _ctrl.text.characters.length;
    return InspirationTheme(
      child: Scaffold(
        backgroundColor: p.background,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(Icons.close_rounded, size: 20, color: p.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            widget.title,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
              child: Text(
                '完成',
                style: TextStyle(fontSize: 13, color: p.textPrimary),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.8,
                    color: p.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: widget.hint.isEmpty ? null : widget.hint,
                    hintStyle: TextStyle(fontSize: 13, color: p.textTertiary),
                    isCollapsed: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.border)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
              child: SafeArea(
                top: false,
                child: Text(
                  '$count 字',
                  style: TextStyle(fontSize: 10, color: p.textTertiary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开全屏编辑页；取消返回 null。
Future<String?> editInspirationText(
  BuildContext context, {
  required String title,
  required String initialText,
  String hint = '',
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => InspirationTextEditorPage(
        title: title,
        initialText: initialText,
        hint: hint,
      ),
    ),
  );
}
