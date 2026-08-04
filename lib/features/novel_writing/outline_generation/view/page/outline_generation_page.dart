import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../controller/outline_controller.dart';
import '../../../shared/domain/outline_record.dart';
import 'outline_setting_page.dart';
import 'outline_history_page.dart';

/// 一键生成小说大纲页面（流式输出）
class OutlineGenerationPage extends StatefulWidget {
  /// 从历史大纲「重新生成」时带入的小说设定，页面加载后回填到输入区，由用户手动点击生成
  final OutlineRecord? initialRecord;

  const OutlineGenerationPage({super.key, this.initialRecord});

  @override
  State<OutlineGenerationPage> createState() => _OutlineGenerationPageState();
}

class _OutlineGenerationPageState extends State<OutlineGenerationPage> {
  final _controller = OutlineController();
  final _majorEventCountController = TextEditingController();
  final _minorEventCountController = TextEditingController();
  final _checkpointCtrl = TextEditingController();
  String? _lastCheckpointSync; // 已同步到检查点编辑器的文本（避免覆盖用户输入）
  bool _hasDraft = false;

  static const _inspirations =
      <({String theme, String protagonist, String worldview})>[
        (
          theme: '废土世界中 AI 觉醒并追寻人性',
          protagonist: '曾经的顶级黑客「零」，失去记忆后在世界裂隙中挣扎求生',
          worldview: '核战后的地球被 AI 穹顶覆盖，人类生活在隔离舱中',
        ),
        (
          theme: '现代都市中的古老妖物与守护者',
          protagonist: '表面是普通大学生的灵力传承者「苏禾」',
          worldview: '现代都市暗藏妖界入口，维持两界平衡的古老契约即将失效',
        ),
        (
          theme: '星辰大海中的文明接力',
          protagonist: '年轻舰长「陆沉舟」，背负旧纪元全部文明的数据库',
          worldview: '人类文明消亡后，意识上传至深空舰队寻找新家园',
        ),
        (
          theme: '武侠世界的机关术复兴',
          protagonist: '被逐出师门的机关天才「唐小柒」',
          worldview: '机关术没落的武林，机械傀儡与内力并存的江湖',
        ),
      ];

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
    _applyInitialRecord();
    _majorEventCountController.text = '${_controller.majorEventCount}';
    _minorEventCountController.text = '${_controller.minorEventCount}';
    _refreshDraft();
  }

  /// 将历史大纲的小说设定回填到输入区
  void _applyInitialRecord() {
    final init = widget.initialRecord;
    if (init == null) return;
    if (init.genre.trim().isNotEmpty) {
      _controller.genreController.text = init.genre.trim();
    }
    if (init.theme.trim().isNotEmpty) {
      _controller.themeController.text = init.theme.trim();
    }
    if (init.protagonist.trim().isNotEmpty) {
      _controller.protagonistController.text = init.protagonist.trim();
    }
    if (init.worldview.trim().isNotEmpty) {
      _controller.worldViewController.text = init.worldview.trim();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _majorEventCountController.dispose();
    _minorEventCountController.dispose();
    _checkpointCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    final msg = _controller.consumeMessage();
    if (msg != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
        );
    }
    // 检查点文本同步：进入/更新检查点时覆盖编辑器，用户输入期间不覆盖
    final cpText = _controller.checkpointText;
    if (_controller.checkpointKind != null) {
      if (cpText != _lastCheckpointSync) {
        _lastCheckpointSync = cpText;
        _checkpointCtrl.text = cpText;
      }
    } else if (_lastCheckpointSync != null) {
      _lastCheckpointSync = null;
      _checkpointCtrl.clear();
    }
  }

  Future<void> _refreshDraft() async {
    final has = await _controller.checkPendingDraft();
    if (mounted) setState(() => _hasDraft = has);
  }

  Future<void> _onResume() async {
    await _controller.resume();
    await _refreshDraft();
  }

  void _randomInspiration() {
    final idea = _inspirations[Random().nextInt(_inspirations.length)];
    _controller.themeController.text = idea.theme;
    _controller.protagonistController.text = idea.protagonist;
    _controller.worldViewController.text = idea.worldview;
    setState(() {});
  }

  Future<void> _onCancelPressed() async {
    await _controller.cancel();
    if (!mounted) return;
    await _refreshDraft();
    if (!mounted) return;
    if (_controller.rawText.trim().isEmpty) return;
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消生成'),
        content: const Text('已生成部分内容，要保存到历史大纲吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (save == true) {
      await _controller.savePartial();
    }
  }

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
              onPressed: _onCancelPressed,
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
                  onPressed: (c.loading || c.paused)
                      ? null
                      : () async {
                          await c.generate();
                          await _refreshDraft();
                        },
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
              if (c.warning != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Colors.amber.shade800,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.warning!,
                          style: TextStyle(
                            color: Colors.amber.shade800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (c.bubbles.isNotEmpty ||
                  c.displayText.isNotEmpty ||
                  c.loading) ...[
                const SizedBox(height: 16),
                if (c.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      c.title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                // 已提交的多气泡（步骤结果 / 失败尝试的思考与输出）
                for (final b in c.bubbles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBubble(
                      label: b.label,
                      content: b.content,
                      isError: b.isError,
                    ),
                  ),
                // 回退：无气泡但有历史/预览内容（如断点续跑恢复）
                if (c.bubbles.isEmpty &&
                    c.displayText.isNotEmpty &&
                    c.liveText.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBubble(
                      label: null,
                      content: c.displayText,
                      isError: false,
                    ),
                  ),
                // 实时流式气泡
                if (c.liveText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBubble(
                      label: '生成中',
                      content: c.liveText,
                      isError: false,
                    ),
                  )
                else if (c.loading)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildBubble(
                      label: '生成中',
                      content: '正在生成...',
                      isError: false,
                    ),
                  ),
                if (c.loading) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: c.progress,
                      minHeight: 4,
                      backgroundColor: const Color(0xFFE8ECF4),
                      color: const Color(0xFF4D6BFE),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.progressText,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (c.lastStepSummary != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '最近完成：${c.lastStepSummary}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ),
                ],
              ],
              if (c.paused && c.checkpointKind != null) ...[
                const SizedBox(height: 12),
                _buildCheckpointCard(),
              ],
              if (_hasDraft && !c.loading && !c.paused) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _onResume,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('继续上次未完成的生成'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF4D6BFE),
                      side: const BorderSide(color: Color(0xFF4D6BFE)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
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
          Row(
            children: [
              const Text(
                '小说设定',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF4D6BFE),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _randomInspiration,
                icon: const Icon(Icons.casino, size: 16),
                label: const Text('随机灵感', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            // 用 initialValue 而非已废弃的 value；外部改动时 FormField 会同步内部值
            initialValue: _predefinedGenres.contains(c.genreController.text)
                ? c.genreController.text
                : (c.genreController.text.trim().isEmpty
                      ? '__custom__'
                      : c.genreController.text),
            decoration: _inputDecoration('小说类型'),
            items: [
              ..._predefinedGenres.map(
                (g) => DropdownMenuItem(value: g, child: Text(g)),
              ),
              // 自定义类型：回显已输入的值，避免确认后只能看到「自定义」字样。
              // 注意：下拉按钮闭合态在无界宽度下布局所有 item，
              // 子项不能用 Flexible/Expanded（会触发 unbounded flex 布局异常导致空白），
              // 因此用 mainAxisSize.min + ConstrainedBox 控制省略号。
              if (!_predefinedGenres.contains(c.genreController.text) &&
                  c.genreController.text.trim().isNotEmpty)
                DropdownMenuItem(
                  value: c.genreController.text,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.edit,
                        size: 16,
                        color: Color(0xFF4D6BFE),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          c.genreController.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
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
            null, // 无上限，数量多时生成耗时相应变长
            (v) => c.majorEventCount = v,
            _majorEventCountController,
          ),
          const SizedBox(height: 10),
          _buildCountRow(
            '小事件数：',
            c.minorEventCount,
            1,
            10,
            (v) => c.minorEventCount = v,
            _minorEventCountController,
          ),
          const SizedBox(height: 6),
          Text(
            '预计约 ${c.estimatedApiCalls} 次 AI 调用，大事件数较多时耗时较长',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
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

  /// 检查点暂停卡片：可编辑三幕骨架文本 + 重新生成/继续/取消
  Widget _buildCheckpointCard() {
    final c = _controller;
    final isSkeleton = c.checkpointKind == 'skeleton';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF0D9A8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.pause_circle_outline,
                size: 18,
                color: Color(0xFFB8860B),
              ),
              const SizedBox(width: 6),
              Text(
                isSkeleton ? '粗骨架已生成 · 检查点' : '大事件已生成 · 检查点',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7A5C00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '可编辑下方内容或重新生成，确认后手动点击「继续」',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _checkpointCtrl,
            maxLines: null,
            minLines: 6,
            style: const TextStyle(fontSize: 12, height: 1.5),
            decoration: InputDecoration(
              hintText: isSkeleton ? '编辑三幕粗骨架...' : '编辑大事件概述...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: c.regenerateCheckpoint,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新生成'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => c.continueCheckpoint(_checkpointCtrl.text),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('继续'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4D6BFE),
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton.icon(
              onPressed: _onCancelPressed,
              icon: const Icon(Icons.stop, size: 16),
              label: const Text('取消生成', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountRow(
    String label,
    int value,
    int min,
    int? max,
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
              if (n != null && n >= min && (max == null || n <= max)) {
                setState(() => onChanged(n));
              }
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          onPressed: max == null || value < max
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

  /// 渲染单个生成内容气泡
  Widget _buildBubble({
    String? label,
    required String content,
    required bool isError,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFFF3F3) : const Color(0xFFF8F9FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError ? const Color(0xFFFFD6D6) : const Color(0xFFE8ECF4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null && label.isNotEmpty) ...[
            Row(
              children: [
                Icon(
                  isError ? Icons.error_outline : Icons.auto_awesome,
                  size: 13,
                  color: isError
                      ? const Color(0xFFE5484D)
                      : const Color(0xFF4D6BFE),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isError
                          ? const Color(0xFFE5484D)
                          : const Color(0xFF4D6BFE),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          SelectableText(
            content.isEmpty ? '（无内容）' : content,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF444444),
            ),
          ),
        ],
      ),
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
      // 键盘弹出时把整个弹窗上移，避免输入框被键盘遮挡、看不到自己输入的内容
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: const _CustomGenreDialog(),
      ),
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
        child: SingleChildScrollView(
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
      ),
    );
  }
}
