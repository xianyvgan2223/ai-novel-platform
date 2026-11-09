import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';

import 'dialog_utils.dart';

/// 导入 txt 前的确认弹窗：显示文件名、字数、识别到的事件数与前几行预览，
/// 并允许修改书名。
///
/// 返回最终书名（点「导入」），取消 / 点空白返回 null。
Future<String?> showOutlineTxtImportDialog(
  BuildContext context, {
  required String fileName,
  required String initialTitle,
  required int charCount,
  required int eventCount,
  required String preview,
  String settingSummary = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _OutlineTxtImportDialog(
      fileName: fileName,
      initialTitle: initialTitle,
      charCount: charCount,
      eventCount: eventCount,
      preview: preview,
      settingSummary: settingSummary,
    ),
  );
}

class _OutlineTxtImportDialog extends StatefulWidget {
  final String fileName;
  final String initialTitle;
  final int charCount;
  final int eventCount;
  final String preview;

  /// v2 结构化文件识别到的设定摘要（旧版纯正文 txt 为空串）
  final String settingSummary;

  const _OutlineTxtImportDialog({
    required this.fileName,
    required this.initialTitle,
    required this.charCount,
    required this.eventCount,
    required this.preview,
    required this.settingSummary,
  });

  @override
  State<_OutlineTxtImportDialog> createState() =>
      _OutlineTxtImportDialogState();
}

class _OutlineTxtImportDialogState extends State<_OutlineTxtImportDialog> {
  late final TextEditingController _titleCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
  }

  /// 取消 / 点空白：只关弹窗，不返回书名。
  void _cancel() {
    if (!closeDialogSafely(context)) return;
    _disposeLater();
  }

  /// 确认导入：返回最终书名（空输入退回默认书名，不拿空串当书名）。
  void _submit() {
    final title = _titleCtrl.text.trim();
    if (!closeDialogSafely(
      context,
      result: title.isEmpty ? widget.initialTitle : title,
    )) {
      return;
    }
    _disposeLater();
  }

  void _disposeLater() {
    // 弹窗退场动画结束前 dispose 会让仍挂载的 TextField 用到已释放的控制器
    scheduleControllerDispose(_titleCtrl);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final noEvents = widget.eventCount <= 0;
    return AlertDialog(
      backgroundColor: p.surface,
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      title: Text(
        '导入大纲 txt',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 15,
                    color: p.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.fileName,
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '书名',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _titleCtrl,
                autofocus: false,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                style: TextStyle(fontSize: 14, color: p.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '给这部作品起个名字',
                  hintStyle: TextStyle(color: p.textTertiary, fontSize: 13),
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
              const SizedBox(height: 10),
              Text(
                '共 ${widget.charCount} 字 · 识别到 ${widget.eventCount} 个事件',
                style: TextStyle(fontSize: 11.5, color: p.textTertiary),
              ),
              if (widget.settingSummary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '已识别小说设定：${widget.settingSummary}',
                    style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (noEvents)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    // 黄色系提示：调色板没有 warningSoft，用 warning 淡底；
                    // 夜间模式提高透明度，保证仍能看出是警示色
                    color: p.warning.withValues(alpha: p.isDark ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '没有识别到大纲事件，仍可导入后手动整理',
                    style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                  ),
                ),
              // 正文预览：只是让用户确认选对了文件，不在这里编辑
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.preview,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: p.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          style: TextButton.styleFrom(
            foregroundColor: p.textSecondary,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('取消', style: TextStyle(fontSize: 13)),
        ),
        TextButton(
          onPressed: _submit,
          style: TextButton.styleFrom(
            foregroundColor: p.accent,
            visualDensity: VisualDensity.compact,
          ),
          child: const Text(
            '导入',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
