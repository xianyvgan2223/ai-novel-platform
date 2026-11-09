import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

/// 「大纲编辑」小说设定的编辑结果（书名为空时由调用方兜底）。
class OutlineSettingsDraft {
  final String title;
  final String genre;
  final String theme;
  final String protagonist;
  final String worldview;

  const OutlineSettingsDraft({
    required this.title,
    required this.genre,
    required this.theme,
    required this.protagonist,
    required this.worldview,
  });
}

/// 打开「小说设定」底部弹层：书名 / 类型 / 主题 / 主角简介 / 世界观。
///
/// 返回用户点「保存」时的内容；取消 / 下滑关闭返回 null。
/// 这里只收集文本，真正落库由调用方负责（页面知道当前记录 id、还要同步
/// 大纲正文里的书名行并刷新标题）。
Future<OutlineSettingsDraft?> showOutlineSettingsEditSheet(
  BuildContext context, {
  required OutlineSettingsDraft initial,
}) {
  return showModalBottomSheet<OutlineSettingsDraft>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _OutlineSettingsEditSheet(initial: initial),
  );
}

class _OutlineSettingsEditSheet extends StatefulWidget {
  final OutlineSettingsDraft initial;

  const _OutlineSettingsEditSheet({required this.initial});

  @override
  State<_OutlineSettingsEditSheet> createState() =>
      _OutlineSettingsEditSheetState();
}

class _OutlineSettingsEditSheetState extends State<_OutlineSettingsEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _genreCtrl;
  late final TextEditingController _themeCtrl;
  late final TextEditingController _protagonistCtrl;
  late final TextEditingController _worldviewCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initial.title);
    _genreCtrl = TextEditingController(text: widget.initial.genre);
    _themeCtrl = TextEditingController(text: widget.initial.theme);
    _protagonistCtrl = TextEditingController(text: widget.initial.protagonist);
    _worldviewCtrl = TextEditingController(text: widget.initial.worldview);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _genreCtrl.dispose();
    _themeCtrl.dispose();
    _protagonistCtrl.dispose();
    _worldviewCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      OutlineSettingsDraft(
        title: _titleCtrl.text.trim(),
        genre: _genreCtrl.text.trim(),
        theme: _themeCtrl.text.trim(),
        protagonist: _protagonistCtrl.text.trim(),
        worldview: _worldviewCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: p.borderStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '小说设定',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 20, color: p.textTertiary),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '修改后保存：书名会同步到列表标题与大纲正文的「书名」行',
                  style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(
                      controller: _titleCtrl,
                      label: '书名',
                      hint: '这部作品的名字',
                      singleLine: true,
                    ),
                    _field(
                      controller: _genreCtrl,
                      label: '类型',
                      hint: '如：玄幻 / 都市 / 悬疑',
                      singleLine: true,
                    ),
                    _field(
                      controller: _themeCtrl,
                      label: '主题',
                      hint: '故事的核心主题',
                      singleLine: true,
                    ),
                    _field(
                      controller: _protagonistCtrl,
                      label: '主角简介',
                      hint: '主角人设、身份、目标等',
                      minLines: 3,
                      maxLines: 6,
                    ),
                    _field(
                      controller: _worldviewCtrl,
                      label: '世界观',
                      hint: '世界规则、势力、时代背景等',
                      minLines: 3,
                      maxLines: 8,
                    ),
                  ],
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.textSecondary,
                          side: BorderSide(color: p.borderStrong),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('取消', style: TextStyle(fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: p.accent,
                          foregroundColor: p.onAccent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool singleLine = false,
    int minLines = 1,
    int maxLines = 1,
  }) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            minLines: singleLine ? 1 : minLines,
            maxLines: singleLine ? 1 : maxLines,
            keyboardType: singleLine
                ? TextInputType.text
                : TextInputType.multiline,
            style: TextStyle(fontSize: 13.5, color: p.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12.5, color: p.textTertiary),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: p.borderStrong),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: p.borderStrong),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: p.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
