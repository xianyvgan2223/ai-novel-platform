import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../controller/outline_format_controller.dart';

/// 大纲格式匹配页面
/// 将用户输入的大纲修改为能匹配大纲转章节的内容格式
class OutlineFormatPage extends StatefulWidget {
  const OutlineFormatPage({super.key});

  @override
  State<OutlineFormatPage> createState() => _OutlineFormatPageState();
}

class _OutlineFormatPageState extends State<OutlineFormatPage> {
  final _controller = OutlineFormatController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  Future<void> _handleSave() async {
    final ok = await _controller.save();
    if (!ok || !mounted) return;
    final p = context.palette;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '大纲已保存，可前往「大纲转章节」使用',
          style: TextStyle(color: p.onAccent),
        ),
        backgroundColor: p.accent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = _controller;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text(
          '匹配大纲格式',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: p.surface,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 说明文字
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.accentSoft,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: p.accent.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: p.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '在此粘贴您已有的大纲，点击「AI 格式化」后系统会自动将其转换为「大纲转章节」功能所需的格式。格式化后您还可以手动编辑调整。',
                      style: TextStyle(fontSize: 13, color: p.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 输入区域
            const Text(
              '输入大纲内容',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c.inputController,
              maxLines: 10,
              decoration: InputDecoration(
                hintText: '请粘贴或输入您的大纲内容...',
                hintStyle: TextStyle(color: p.textTertiary),
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
                contentPadding: const EdgeInsets.all(12),
              ),
              style: TextStyle(fontSize: 14, color: p.textPrimary),
            ),
            const SizedBox(height: 12),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: c.loading ? null : c.format,
                    icon: c.loading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: p.onAccent,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(c.loading ? '格式化中...' : 'AI 格式化'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: p.onAccent,
                      disabledBackgroundColor: p.accent.withValues(alpha: 0.6),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (c.loading) ...[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: c.cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.danger,
                      side: BorderSide(color: p.danger),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('取消', style: TextStyle(fontSize: 15)),
                  ),
                ],
              ],
            ),

            // 错误提示
            if (c.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.dangerSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  c.error!,
                  style: TextStyle(color: p.danger, fontSize: 13),
                ),
              ),
            ],

            // 格式化结果
            if (c.hasFormatted || c.resultController.text.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '格式化结果（可编辑）',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          c.resultController.text = c.inputController.text;
                          c.hasFormatted = true;
                          setState(() {});
                        },
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text(
                          '还原原文',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: p.textTertiary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _handleSave,
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('保存', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          foregroundColor: p.accent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: c.resultController,
                maxLines: 20,
                decoration: InputDecoration(
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
                  contentPadding: const EdgeInsets.all(12),
                ),
                style: TextStyle(fontSize: 13, color: p.textPrimary),
              ),
              const SizedBox(height: 12),
              // 保存按钮（底部大按钮）
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _handleSave,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('保存到大纲记录'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '保存后可在「大纲转章节」中选择此大纲生成章节内容',
                style: TextStyle(fontSize: 12, color: p.textTertiary),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
