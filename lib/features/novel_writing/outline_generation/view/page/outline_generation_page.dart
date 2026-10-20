import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../../../../core/config/route_names.dart';
import '../../background/outline_generation_session.dart';
import '../../controller/outline_controller.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_record.dart';
import 'outline_setting_page.dart';
import 'outline_history_list_page.dart';

/// 一键生成小说大纲页面（流式输出）
class OutlineGenerationPage extends StatefulWidget {
  /// 从历史大纲「重新生成」时带入的小说设定，页面加载后回填到输入区，由用户手动点击生成
  final OutlineRecord? initialRecord;

  /// 局部重新生成模式：'skeleton'（编辑粗骨）| 'events'（编辑大事件）。
  /// 传入后页面自动从 [initialRecord] 解析骨架并进入对应检查点供编辑，
  /// 继续后仅重新生成对应下游内容，并另存为新大纲（不覆盖原记录）。
  final String? reeditKind;

  /// 是否由「通知栏生成进度」点击打开。
  ///
  /// 为 true 时优先挂回会话里「已生成完但还没看过」的那份结果；
  /// 从菜单普通进入则不挂旧结果（生成中的会话仍会挂回，不允许并发出两份生成）。
  final bool fromNotification;

  const OutlineGenerationPage({
    super.key,
    this.initialRecord,
    this.reeditKind,
    this.fromNotification = false,
  });

  /// 当前打开的生成页实例数。
  ///
  /// 通知点击时 app 层据此判断「生成页是否已经在前台」：已在前台就只把 App
  /// 拉到前面，不再 push 第二个页面；否则从任意页面点通知都能回到生成详情。
  static int openInstanceCount = 0;

  @override
  State<OutlineGenerationPage> createState() => _OutlineGenerationPageState();
}

class _OutlineGenerationPageState extends State<OutlineGenerationPage>
    with WidgetsBindingObserver {
  /// 生成状态由进程级会话持有（见 [OutlineGenerationSession]）：
  /// 页面关闭时不取消生成，重新进入 / 点通知回来都挂回同一份状态。
  late OutlineController _controller;

  /// 本页拿到的是已有会话（true）还是新建的（false）。
  /// 已有会话时不能再用 initialRecord 覆盖输入，也不能重复触发局部重新生成。
  late bool _attachedExisting;

  final _majorEventCountController = TextEditingController();
  final _minorEventCountController = TextEditingController();
  final _checkpointCtrl = TextEditingController();
  String? _lastCheckpointSync; // 已同步到检查点编辑器的文本（避免覆盖用户输入）
  bool _hasDraft = false;
  late final bool _isReedit; // 是否处于历史大纲「局部重新生成」模式
  late final bool _isContinue; // 是否处于未完成大纲「继续生成」模式

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
    WidgetsBinding.instance.addObserver(this);
    OutlineGenerationPage.openInstanceCount++;
    // 历史大纲「重新生成 / 继续生成」必须用全新实例；普通进入优先复用现有
    // 会话——生成中的会话无论从哪里进都要挂回（不允许并发两份生成），
    // 已生成完的结果只在「点通知回来」时挂回。
    final attach = OutlineGenerationSession.instance.acquireForPage(
      preferExisting: widget.fromNotification,
    );
    _controller = attach.controller;
    _attachedExisting = attach.attachedExisting;
    _controller.addListener(_onChanged);
    if (!_attachedExisting) _applyInitialRecord();
    _majorEventCountController.text = '${_controller.majorEventCount}';
    _minorEventCountController.text = '${_controller.minorEventCount}';
    _isReedit =
        !_attachedExisting &&
        widget.initialRecord != null &&
        widget.reeditKind != null;
    _isContinue = _isReedit && widget.reeditKind == 'continue';
    if (_isReedit) {
      // 下一帧再启动历史大纲局部重新生成/继续生成，避免 initState 期间触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_isContinue) {
          _controller.continueFromRecord(widget.initialRecord!);
        } else {
          _controller.regenerateFromRecord(
            widget.initialRecord!,
            kind: widget.reeditKind!,
          );
        }
      });
    }
    _refreshDraft();
    _restoreScrollPosition();
  }

  /// 重新挂回已有会话时恢复离开前的滚动位置（点通知回来能直接看到刚才那段内容）。
  void _restoreScrollPosition() {
    final offset = _controller.detachedScrollOffset;
    if (offset == null || offset <= 0) return;
    _controller.detachedScrollOffset = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.scrollController.hasClients) return;
      final max = _controller.scrollController.position.maxScrollExtent;
      _controller.scrollController.jumpTo(offset.clamp(0.0, max));
    });
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
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onChanged);
    // 退出页面前把检查点编辑立即落盘，防止意外返回/退出丢失用户更改
    _controller.flushCheckpointSync();
    // 记录滚动位置后归还会话：生成中 / 检查点等待中会保留控制器（生成继续跑），
    // 只有空闲（完成/取消/失败）才真正 dispose。
    if (_controller.scrollController.hasClients) {
      _controller.detachedScrollOffset = _controller.scrollController.offset;
    }
    OutlineGenerationSession.instance.detachFromPage(_controller);
    if (OutlineGenerationPage.openInstanceCount > 0) {
      OutlineGenerationPage.openInstanceCount--;
    }
    _majorEventCountController.dispose();
    _minorEventCountController.dispose();
    _checkpointCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退后台/进程被杀前冲刷未落盘的检查点编辑，防止最后一段输入丢失
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _controller.flushCheckpointSync();
    }
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

  // 气泡 Widget 实例缓存：内容未变化的气泡复用同一实例，
  // Flutter 对 identical 的旧实例会跳过 rebuild/layout，避免流式更新时
  // 每 300ms 全量重建几十个大段 SelectableText 导致卡顿。
  String? _bubbleCacheKey;
  List<Widget> _bubbleCacheWidgets = const [];

  List<Widget> _bubbleWidgetsFor(List<OutlineStepBubble> bubbles) {
    final key = StringBuffer();
    for (final b in bubbles) {
      key
        ..write(b.label)
        ..write('\u0001')
        ..write(b.isError ? '1' : '0')
        ..write('\u0001')
        ..write(b.content)
        ..write('\u0002');
    }
    final k = key.toString();
    if (k == _bubbleCacheKey) return _bubbleCacheWidgets;
    _bubbleCacheKey = k;
    _bubbleCacheWidgets = List.unmodifiable([
      for (final b in bubbles)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RepaintBoundary(
            child: _buildBubble(
              label: b.label,
              content: b.content,
              isError: b.isError,
            ),
          ),
        ),
    ]);
    return _bubbleCacheWidgets;
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
        title: Text(
          _isContinue ? '继续生成' : (_isReedit ? '局部重新生成' : '一键生成大纲'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
              MaterialPageRoute(builder: (_) => const OutlineHistoryListPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Color(0xFF4D6BFE)),
            tooltip: '大纲生成设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                // 命名路由：让全局悬浮球在大纲生成设置页隐藏（见 route_names.dart）
                settings: const RouteSettings(name: kOutlineSettingsRouteName),
                builder: (_) => const OutlineSettingPage(),
              ),
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
              // 局部重新生成模式：显示可编辑的「小说设定」卡片（类型/主题/主角/世界观），
              // 隐藏大/小事件数与「一键生成」按钮，直接进入检查点编辑
              if (_isReedit) ...[
                _buildReeditSettingCard(),
                const SizedBox(height: 12),
              ],
              if (!_isReedit) ...[
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
              ],
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
                // 缓存复用实例：流式更新时未变化的气泡直接跳过重建
                ..._bubbleWidgetsFor(c.bubbles),
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
                // 实时流式气泡：每 300ms 更新，用 RepaintBoundary 隔离重绘，
                // 用普通 Text 而非 SelectableText（后者布局成本高，流式期间不可选也无妨）
                if (c.liveText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: RepaintBoundary(
                      child: _buildBubble(
                        label: '生成中',
                        content: c.liveText,
                        isError: false,
                        selectable: false,
                      ),
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
              if (!_isReedit && _hasDraft && !c.loading && !c.paused) ...[
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

  /// 局部重新生成模式的「小说设定」卡片：类型/主题/主角设定/世界观 可直接编辑。
  /// 修改后点「继续」按新设定重新生成下游内容，并随另存的新大纲记录保存；
  /// 不含大/小事件数（数量决定骨架结构，由检查点内容控制）。
  Widget _buildReeditSettingCard() {
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
            '小说设定（可修改）',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '修改世界观 / 主角设定后点「继续」，将按新设定重新生成后续内容并保存到新大纲',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c.genreController,
            decoration: _inputDecoration('小说类型'),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.themeController,
                  decoration: _inputDecoration('主题（如：废土世界中的 AI 觉醒）'),
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
                    _showLargeEditor(context, c.themeController, '主题'),
              ),
            ],
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
                  decoration: _inputDecoration(
                    '世界观（如：灵力为尊的大陆，科技与魔法并存）',
                  ),
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.requirementController,
                  decoration: _inputDecoration(
                    '要求提示词（如：节奏快、不要后宫、每个大事件都要有爽点）',
                  ),
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
                    _showLargeEditor(context, c.requirementController, '要求提示词'),
              ),
            ],
          ),
        ],
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.themeController,
                  decoration: _inputDecoration('主题（如：废土世界中的 AI 觉醒）'),
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
                    _showLargeEditor(context, c.themeController, '主题'),
              ),
            ],
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: c.requirementController,
                  decoration: _inputDecoration(
                    '要求提示词（如：节奏快、不要后宫、每个大事件都要有爽点）',
                  ),
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
                    _showLargeEditor(context, c.requirementController, '要求提示词'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '要求提示词会注入到定调、粗骨架、精写大事件、展开小事件的每一步',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
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

  /// 检查点暂停卡片：可编辑当前阶段内容 + 返回上一步/重新生成/继续/取消
  Widget _buildCheckpointCard() {
    final c = _controller;
    final kind = c.checkpointKind;
    final isTitle = kind == 'title';
    final isSkeleton = kind == 'skeleton';
    final canBack = !isTitle; // 书名/概念检查点没有上一步
    final canForward = c.checkpointBackSource != null; // 从返回状态恢复时提供「下一步」反悔
    final String cardTitle;
    final String cardDesc;
    final String fieldHint;
    if (isTitle) {
      cardTitle = '书名与核心概念 · 检查点';
      cardDesc = '可编辑书名与核心概念，确认后手动点击「继续」';
      fieldHint = '编辑书名与核心概念...';
    } else if (isSkeleton) {
      cardTitle = _isReedit ? '重新编辑粗骨 · 局部重新生成' : '粗骨架已生成 · 检查点';
      cardDesc = '可编辑下方内容、返回上一步或重新生成，确认后手动点击「继续」';
      fieldHint = '编辑三幕粗骨架...';
    } else if (kind == 'minor') {
      cardTitle = '小事件已生成 · 检查点';
      cardDesc = '全部小事件已展开，可编辑全文、返回上一步或重新生成，确认后手动点击「继续」';
      fieldHint = '编辑全部展开内容...';
    } else {
      cardTitle = _isReedit ? '重新编辑大事件 · 局部重新生成' : '大事件已生成 · 检查点';
      cardDesc = '可编辑下方内容、返回上一步或重新生成，确认后手动点击「继续」';
      fieldHint = '编辑大事件概述...';
    }
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
                cardTitle,
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
            cardDesc,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          if (_isReedit) ...[
            const SizedBox(height: 4),
            Text(
              _isContinue ? '继续生成后将另存为新大纲，不会覆盖原记录' : '重新生成后将另存为新大纲，不会覆盖原记录',
              style: const TextStyle(fontSize: 11, color: Color(0xFFB8860B)),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _checkpointCtrl,
            maxLines: null,
            minLines: 6,
            style: const TextStyle(fontSize: 12, height: 1.5),
            decoration: InputDecoration(
              hintText: fieldHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              filled: true,
              fillColor: Colors.white,
              isDense: true,
            ),
            // 编辑内容实时同步到控制器并防抖落盘，意外退出页面后可通过「继续上次」恢复
            onChanged: (v) => _controller.syncCheckpointEdit(v),
          ),
          const SizedBox(height: 10),
          // 导航行：返回上一步 / 下一步（按状态动态显示，仅出现有意义的方向）
          ...[
            if (canBack || canForward)
              Row(
                children: [
                  if (canBack)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: c.backCheckpoint,
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('返回上一步'),
                      ),
                    ),
                  if (canBack && canForward) const SizedBox(width: 8),
                  if (canForward)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: c.forwardCheckpoint,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: const Text('下一步'),
                      ),
                    ),
                ],
              ),
            if (canBack || canForward) const SizedBox(height: 8),
          ],
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
  /// [selectable] 为 false 时（流式更新中的内容）用普通 Text 渲染，
  /// 布局成本远低于 SelectableText，显著降低大文档流式刷新时的卡顿。
  Widget _buildBubble({
    String? label,
    required String content,
    required bool isError,
    bool selectable = true,
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
          if (selectable)
            SelectableText(
              content.isEmpty ? '（无内容）' : content,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xFF444444),
              ),
            )
          else
            Text(
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
      // 键盘弹出时把整个弹窗上移，避免输入框被键盘遮挡、看不到自己输入的内容。
      // 弹窗是 const，实例稳定，所以每帧只会重建这层 Padding；用 viewInsetsOf
      // 收窄依赖，其它 MediaQuery 字段变化不再牵连这里。
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
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
      case '主题':
        return '描述故事的核心主题、想表达的东西，例如：一个杀神学着做一个普通人...';
      case '主角设定':
        return '详细设定主角的姓名、外貌、性格、背景故事...';
      case '世界观':
        return '描述世界的规则、势力分布、力量体系、历史背景...';
      case '要求提示词':
        return '写下对大纲生成的具体要求，例如：节奏快、不要后宫、每个大事件都要有爽点、'
            '避免烂俗桥段、伏笔要提前埋好并在第三幕回收...';
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
                    // 防重复点击：重复 pop 会连带关闭下层页面
                    closeDialogSafely(context, result: _controller.text.trim());
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
