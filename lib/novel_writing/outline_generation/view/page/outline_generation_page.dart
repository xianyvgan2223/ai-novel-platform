import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../controller/outline_controller.dart';
import 'outline_setting_page.dart';
import 'outline_history_page.dart';

/// 一键生成小说大纲页面（流式输出）
class OutlineGenerationPage extends StatefulWidget {
  const OutlineGenerationPage({super.key});

  @override
  State<OutlineGenerationPage> createState() => _OutlineGenerationPageState();
}

class _OutlineGenerationPageState extends State<OutlineGenerationPage> {
  final _controller = OutlineController();
  final _majorEventCountController = TextEditingController();
  final _minorEventCountController = TextEditingController();

  static const _predefinedGenres = [
    '玄幻',
    '都市',
    '科幻',
    '仙侠',
    '奇幻',
    '悬疑',
    '言情',
    '历史',
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _majorEventCountController.text = '${_controller.majorEventCount}';
    _minorEventCountController.text = '${_controller.minorEventCount}';
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _majorEventCountController.dispose();
    _minorEventCountController.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '一键生成大纲',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: Color(0xFF4D6BFE)),
            tooltip: '历史大纲',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OutlineHistoryPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Color(0xFF4D6BFE)),
            tooltip: '大纲生成设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OutlineSettingPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: c.loading
          ? FloatingActionButton.extended(
              onPressed: () => c.cancel(),
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.stop, size: 20),
              label: const Text(
                '停止生成',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            )
          : null,
      body: CupertinoScrollbar(
        controller: c.scrollController,
        thumbVisibility: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: SingleChildScrollView(
          controller: c.scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInputSection(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: c.loading ? null : () => c.generate(),
                  icon: c.loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(c.loading ? '生成中...' : '一键生成大纲'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4D6BFE),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (c.error != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Colors.red.shade700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.error!,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (c.rawText.isNotEmpty || c.loading) ...[
                const SizedBox(height: 16),
                if (c.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${c.title}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE8ECF4)),
                  ),
                  child: SelectableText(
                    c.displayText.isEmpty ? '正在生成...' : c.displayText,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Color(0xFF444444),
                    ),
                  ),
                ),
                if (c.loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${c.stepLabel} (${c.currentStep + 1}/${c.totalSteps})',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputSection() {
    final c = _controller;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '小说设定',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _predefinedGenres.contains(c.genreController.text)
                ? c.genreController.text
                : '__custom__',
            decoration: _inputDecoration('小说类型'),
            items: [
              ..._predefinedGenres.map(
                (g) => DropdownMenuItem(value: g, child: Text(g)),
              ),
              const DropdownMenuItem(
                value: '__custom__',
                child: Row(
                  children: [
                    Icon(Icons.edit, size: 16, color: Color(0xFF4D6BFE)),
                    SizedBox(width: 6),
                    Text('自定义'),
                  ],
                ),
              ),
            ],
            onChanged: (v) async {
              if (v == '__custom__') {
                final result = await _showCustomGenreDialog(context);
                if (result != null && result.isNotEmpty) {
                  c.genreController.text = result;
                }
              } else {
                c.genreController.text = v ?? '玄幻';
              }
              setState(() {});
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: c.themeController,
            decoration: _inputDecoration('主题（如：废土世界中的 AI 觉醒）'),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.protagonistController,
                  decoration: _inputDecoration('主角设定（如：流浪剑客林墨）'),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(
                  Icons.fullscreen,
                  size: 20,
                  color: Color(0xFF4D6BFE),
                ),
                tooltip: '放大编辑',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () =>
                    _showLargeEditor(context, c.protagonistController, '主角设定'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.worldViewController,
                  decoration: _inputDecoration('世界观（如：灵力为尊的大陆，科技与魔法并存）'),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(
                  Icons.fullscreen,
                  size: 20,
                  color: Color(0xFF4D6BFE),
                ),
                tooltip: '放大编辑',
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () =>
                    _showLargeEditor(context, c.worldViewController, '世界观'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildCountRow(
            '大事件数：',
            c.majorEventCount,
            1,
            50,
            (v) => c.majorEventCount = v,
            _majorEventCountController,
          ),
          const SizedBox(height: 10),
          _buildCountRow(
            '小事件数：',
            c.minorEventCount,
            1,
            20,
            (v) => c.minorEventCount = v,
            _minorEventCountController,
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFDDE1EA)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFDDE1EA)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF4D6BFE), width: 1.5),
      ),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
    );
  }

  Widget _buildCountRow(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
    TextEditingController controller,
  ) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > min
              ? () => setState(() {
                  onChanged(value - 1);
                  controller.text = '${value - 1}';
                })
              : null,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: EdgeInsets.zero,
        ),
        SizedBox(
          width: 50,
          height: 32,
          child: TextField(
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFDDE1EA)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFDDE1EA)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: Color(0xFF4D6BFE),
                  width: 1.5,
                ),
              ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
            ),
            controller: controller,
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= min && n <= max) {
                setState(() => onChanged(n));
              }
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max
              ? () => setState(() {
                  onChanged(value + 1);
                  controller.text = '${value + 1}';
                })
              : null,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Future<void> _showLargeEditor(
    BuildContext context,
    TextEditingController controller,
    String title,
  ) async {
    await showDialog(
      context: context,
      builder: (ctx) => _LargeEditorDialog(
        initialText: controller.text,
        title: title,
        onConfirm: (text) => controller.text = text,
      ),
    );
  }

  Future<String?> _showCustomGenreDialog(BuildContext context) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => const _CustomGenreDialog(),
    );
  }
}

/// 大编辑框弹窗（独立 StatefulWidget，生命周期安全）
class _LargeEditorDialog extends StatefulWidget {
  final String initialText;
  final String title;
  final ValueChanged<String> onConfirm;

  const _LargeEditorDialog({
    required this.initialText,
    required this.title,
    required this.onConfirm,
  });

  @override
  State<_LargeEditorDialog> createState() => _LargeEditorDialogState();
}

class _LargeEditorDialogState extends State<_LargeEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _hintFor(String title) {
    switch (title) {
      case '主角设定':
        return '详细设定主角的姓名、外貌、性格、背景故事...';
      case '世界观':
        return '描述世界的规则、势力分布、力量体系、历史背景...';
      default:
        return '请输入详细内容...';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 13, height: 1.5),
                decoration: InputDecoration(
                  hintText: _hintFor(widget.title),
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFBBBBBB),
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: () {
                  widget.onConfirm(_controller.text);
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4D6BFE),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '确认',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义小说类型输入弹窗
class _CustomGenreDialog extends StatefulWidget {
  const _CustomGenreDialog();

  @override
  State<_CustomGenreDialog> createState() => _CustomGenreDialogState();
}

class _CustomGenreDialogState extends State<_CustomGenreDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '自定义小说类型',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '输入自定义类型（如：赛博朋克、末日废土...）',
                hintStyle: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFFBBBBBB),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop(_controller.text.trim());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4D6BFE),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text(
                  '确定',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
