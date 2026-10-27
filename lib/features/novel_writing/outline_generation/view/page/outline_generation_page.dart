import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../../../core/config/route_names.dart';
import '../../../../../core/widgets/settings_kit.dart';
import '../../background/outline_generation_session.dart';
import '../../controller/outline_controller.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_record.dart';
import 'outline_setting_page.dart';
import 'outline_history_list_page.dart';

// ─── 本页视觉（色值 / 圆角 / 间距全部取自 settings_kit 的令牌，禁止另起一套） ───

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
  AppPalette get _p => context.palette;

  /// 警告横幅：柔和的暖底 + 深琥珀字。
  Color get _warningSoft =>
      _p.isDark ? _p.warning.withValues(alpha: 0.14) : const Color(0xFFFFF6E3);
  Color get _warningInk => _p.isDark ? _p.warning : const Color(0xFF9A6B12);

  /// 检查点卡片：琥珀色点缀（图标 chip + 标题），底色仍用白卡。
  Color get _amberSoft =>
      _p.isDark ? _p.warning.withValues(alpha: 0.14) : const Color(0xFFFFF3DA);
  Color get _amberInk => _p.isDark ? _p.warning : const Color(0xFFB8860B);
  Color get _amberTitle => _p.isDark ? _p.textPrimary : const Color(0xFF7A5C00);

  /// 错误气泡里的正文色（比纯红更沉，长文阅读不刺眼）。
  Color get _errorInk => _p.isDark ? _p.danger : const Color(0xFF8C2F2F);

  /// 卡片发丝描边：白卡不用投影，改用 1px 浅灰描边，页面更平、更克制。
  Color get _cardBorder => _p.border;

  /// 输入框聚焦时的描边：不用主色，一条中灰线即可（本页没有第二强调色）。
  Color get _fieldFocusBorder => _p.borderStrong;

  TextStyle get _fieldTextStyle =>
      TextStyle(fontSize: 14, height: 1.4, color: _p.textPrimary);

  TextStyle get _helperStyle =>
      TextStyle(fontSize: 11.5, height: 1.5, color: _p.textTertiary);

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

  /// 「停止生成」悬浮块位置（相对 body 右下角的偏移，可拖动；跨重建保留）
  double _stopRight = 16;
  double _stopBottom = 24;
  final GlobalKey _stopFabKey = GlobalKey();

  /// 「一键到底」按钮的显隐状态（仅用于滚动时触发重建）
  bool _canJumpToBottom = false;

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
    _controller.scrollController.addListener(_onScrollChanged);
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
    _controller.scrollController.removeListener(_onScrollChanged);
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

  /// 滚动位置变化：只在「是否需要一键到底」翻转时重建，避免每个像素 setState。
  void _onScrollChanged() {
    final sc = _controller.scrollController;
    if (!sc.hasClients) return;
    final can = (sc.position.maxScrollExtent - sc.offset) > 120;
    if (can != _canJumpToBottom) {
      setState(() => _canJumpToBottom = can);
    }
  }

  /// 布局完成后同步「一键到底」的显隐：内容变长 / 检查点出现后
  /// maxScrollExtent 会变化，但滚动监听不一定触发，必须主动对齐一次。
  void _syncJumpVisibility() {
    if (!mounted) return;
    final sc = _controller.scrollController;
    if (!sc.hasClients) return;
    final can = (sc.position.maxScrollExtent - sc.offset) > 120;
    if (can != _canJumpToBottom) {
      setState(() => _canJumpToBottom = can);
    }
  }

  /// 拖动「停止生成」悬浮块：位置记在 body 右下角偏移里，限制在可视区域内。
  void _onStopDrag(DragUpdateDetails d, BoxConstraints constraints) {
    final fabSize = _stopFabKey.currentContext?.size ?? const Size(140, 48);
    final inset = MediaQuery.paddingOf(context).bottom;
    final maxRight = (constraints.maxWidth - fabSize.width - 8).clamp(
      8.0,
      9999.0,
    );
    final maxBottom = (constraints.maxHeight - fabSize.height - 8 - inset)
        .clamp(8.0, 9999.0);
    setState(() {
      _stopRight = (_stopRight - d.delta.dx).clamp(8.0, maxRight);
      _stopBottom = (_stopBottom - d.delta.dy).clamp(8.0, maxBottom);
    });
  }

  /// 一键滚到最底部（流式生成时看最新内容）。
  Future<void> _jumpToBottom() async {
    final sc = _controller.scrollController;
    if (!sc.hasClients) return;
    await sc.animateTo(
      sc.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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
      for (var i = 0; i < bubbles.length; i++) ...[
        // 步骤之间用发丝分割线而不是间距：长结果更像连续文档，不是一摞气泡
        if (i > 0)
          Divider(height: 28, thickness: 1, color: _p.border),
        RepaintBoundary(
          child: _buildBubble(
            label: bubbles[i].label,
            content: bubbles[i].content,
            isError: bubbles[i].isError,
          ),
        ),
      ],
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
    final hasOutput =
        c.bubbles.isNotEmpty || c.displayText.isNotEmpty || c.loading;
    return DefaultSelectionStyle(
      // 光标 / 选中高亮也用中性色，避免输入框里还残留蓝色
      cursorColor: _p.textPrimary,
      selectionColor: _p.textPrimary.withValues(alpha: 0.18),
      child: Scaffold(
        backgroundColor: _p.background,
        appBar: AppBar(
          backgroundColor: _p.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          title: Text(
            _isContinue ? '继续生成' : (_isReedit ? '局部重新生成' : '一键生成大纲'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _p.textPrimary,
            ),
          ),
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 18,
              color: _p.textPrimary,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            IconButton(
              icon: Icon(
                Icons.history_rounded,
                size: 21,
                color: _p.textSecondary,
              ),
              tooltip: '历史大纲',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const OutlineHistoryListPage(),
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.tune_rounded,
                size: 21,
                color: _p.textSecondary,
              ),
              tooltip: '大纲生成设置',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  // 命名路由：让全局悬浮球在大纲生成设置页隐藏（见 route_names.dart）
                  settings: const RouteSettings(
                    name: kOutlineSettingsRouteName,
                  ),
                  builder: (_) => const OutlineSettingPage(),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(
              height: 1,
              thickness: 1,
              color: _p.borderStrong,
            ),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final inset = MediaQuery.paddingOf(context).bottom;
            // 内容高度变化后（流式追加 / 检查点卡出现）同步一次按钮显隐
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _syncJumpVisibility(),
            );
            return Stack(
              children: [
                CupertinoScrollbar(
                  controller: c.scrollController,
                  thumbVisibility: true,
                  thickness: 5,
                  radius: const Radius.circular(3),
                  child: SingleChildScrollView(
                    controller: c.scrollController,
                    padding: EdgeInsets.fromLTRB(
                      20,
                      4,
                      20,
                      40 + MediaQuery.paddingOf(context).bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 局部重新生成模式：显示可编辑的「小说设定」卡片（类型/主题/主角/世界观），
                        // 隐藏大/小事件数与「一键生成」按钮，直接进入检查点编辑
                        if (_isReedit) ...[
                          _buildReeditSettingCard(),
                          const SizedBox(height: 4),
                        ] else ...[
                          _buildInputSection(),
                          const SizedBox(height: 16),
                          _buildGenerateButton(c),
                        ],
                        if (c.error != null) ...[
                          const SizedBox(height: 14),
                          _buildBanner(
                            text: c.error!,
                            icon: Icons.error_outline_rounded,
                            background: _p.dangerSoft,
                            foreground: _p.danger,
                          ),
                        ],
                        if (c.warning != null) ...[
                          const SizedBox(height: 14),
                          _buildBanner(
                            text: c.warning!,
                            icon: Icons.warning_amber_rounded,
                            background: _warningSoft,
                            foreground: _warningInk,
                          ),
                        ],
                        if (hasOutput) ...[
                          const SizedBox(height: 18),
                          _buildOutputCard(c),
                        ],
                        if (c.paused && c.checkpointKind != null) ...[
                          const SizedBox(height: 18),
                          _buildCheckpointCard(),
                        ],
                        if (!_isReedit &&
                            _hasDraft &&
                            !c.loading &&
                            !c.paused) ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: OutlinedButton.icon(
                              onPressed: _onResume,
                              icon: const Icon(Icons.restore_rounded, size: 18),
                              label: const Text('继续上次未完成的生成'),
                              style: _secondaryButtonStyle(
                                fontSize: 13.5,
                                foreground: _p.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // 一键到底：只在下方还有内容时出现，放左下避开右下的停止块
                if (_canJumpToBottom)
                  Positioned(
                    left: 16,
                    bottom: 24 + inset,
                    child: _JumpToBottomButton(onTap: _jumpToBottom),
                  ),
                // 停止生成：可自由拖动，位置限制在可视区域内
                if (c.loading)
                  Positioned(
                    right: _stopRight,
                    bottom: _stopBottom + inset,
                    child: GestureDetector(
                      key: _stopFabKey,
                      onPanUpdate: (d) => _onStopDrag(d, constraints),
                      child: FloatingActionButton.extended(
                        onPressed: _onCancelPressed,
                        // 白底 + 红字：停止是「打断」而不是主行动，不用大面积红色抢焦点
                        backgroundColor: _p.surface,
                        foregroundColor: _p.danger,
                        elevation: 0,
                        highlightElevation: 0,
                        extendedPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: _p.danger.withValues(alpha: 0.25),
                          ),
                        ),
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text(
                          '停止生成',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 局部重新生成模式的「小说设定」区块：类型/主题/主角设定/世界观 可直接编辑。
  /// 修改后点「继续」按新设定重新生成下游内容，并随另存的新大纲记录保存；
  /// 不含大/小事件数（数量决定骨架结构，由检查点内容控制）。
  Widget _buildReeditSettingCard() {
    final c = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          title: '小说设定（可修改）',
          subtitle: '改完点「继续」重新生成',
          isFirst: true,
        ),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '修改世界观 / 主角设定后点「继续」，将按新设定重新生成后续内容并保存到新大纲',
                style: _helperStyle,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c.genreController,
                decoration: _inputDecoration('小说类型'),
                style: _fieldTextStyle,
              ),
              const SizedBox(height: 12),
              _fieldWithExpand(c.themeController, '主题（如：废土世界中的 AI 觉醒）', '主题'),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.protagonistController,
                '主角设定（如：流浪剑客林墨）',
                '主角设定',
              ),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.worldViewController,
                '世界观（如：灵力为尊的大陆，科技与魔法并存）',
                '世界观',
              ),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.requirementController,
                '要求提示词（如：节奏快、不要后宫、每个大事件都要有爽点）',
                '要求提示词',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInputSection() {
    final c = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(
              child: _SectionHeading(
                title: '小说设定',
                subtitle: '写清设定，剩下的交给 AI',
                isFirst: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                bottom: kSettingsSectionGapBot + 2,
              ),
              child: _InspirationButton(onTap: _randomInspiration),
            ),
          ],
        ),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                // 用 initialValue 而非已废弃的 value；外部改动时 FormField 会同步内部值
                initialValue: _predefinedGenres.contains(c.genreController.text)
                    ? c.genreController.text
                    : (c.genreController.text.trim().isEmpty
                          ? '__custom__'
                          : c.genreController.text),
                decoration: _inputDecoration('小说类型'),
                style: _fieldTextStyle,
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
                          Icon(
                            Icons.edit_rounded,
                            size: 16,
                            color: _p.textSecondary,
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
                  DropdownMenuItem(
                    value: '__custom__',
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_rounded,
                          size: 16,
                          color: _p.textSecondary,
                        ),
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
              const SizedBox(height: 12),
              _fieldWithExpand(c.themeController, '主题（如：废土世界中的 AI 觉醒）', '主题'),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.protagonistController,
                '主角设定（如：流浪剑客林墨）',
                '主角设定',
              ),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.worldViewController,
                '世界观（如：灵力为尊的大陆，科技与魔法并存）',
                '世界观',
              ),
              const SizedBox(height: 12),
              _fieldWithExpand(
                c.requirementController,
                '要求提示词（如：节奏快、不要后宫、每个大事件都要有爽点）',
                '要求提示词',
              ),
              const SizedBox(height: 8),
              Text(
                '要求提示词会注入到定调、粗骨架、精写大事件、展开小事件的每一步',
                style: _helperStyle,
              ),
              const SizedBox(height: 18),
              Text(
                '事件规模',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textTertiary,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 6),
              _buildCountRow(
                '大事件数：',
                c.majorEventCount,
                1,
                null, // 无上限，数量多时生成耗时相应变长
                (v) => c.majorEventCount = v,
                _majorEventCountController,
              ),
              const SizedBox(height: 6),
              _buildCountRow(
                '小事件数：',
                c.minorEventCount,
                1,
                10,
                (v) => c.minorEventCount = v,
                _minorEventCountController,
              ),
              const SizedBox(height: 8),
              Text(
                '预计约 ${c.estimatedApiCalls} 次 AI 调用，大事件数较多时耗时较长',
                style: _helperStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 填充式输入框：去边框（只留浅灰底），聚焦时出现一条中灰细边。
  /// 一页 4~5 个输入框，如果每个都带描边会形成「灰框墙」，去边框后更像
  /// 一张完整的表单，视觉噪音更低。
  InputDecoration _inputDecoration(String hint) {
    final base = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13.5, color: _p.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: base,
      enabledBorder: base,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: _fieldFocusBorder),
      ),
      filled: true,
      fillColor: _p.surfaceMuted,
      isDense: true,
    );
  }

  /// 白卡：18dp 圆角 + 1px 发丝描边、无投影（比浮起投影更平更高级）。
  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _cardBorder),
      ),
      child: child,
    );
  }

  /// 输入框 + 内嵌「放大编辑」按钮（主题 / 主角 / 世界观 / 要求提示词共用）。
  /// 按钮收进输入框内部（suffixIcon），不再独占一列，表单整体更干净。
  Widget _fieldWithExpand(
    TextEditingController controller,
    String hint,
    String title,
  ) {
    return TextField(
      controller: controller,
      decoration: _inputDecoration(hint).copyWith(
        suffixIcon: IconButton(
          icon: Icon(
            Icons.open_in_full_rounded,
            size: 16,
            color: _p.textTertiary,
          ),
          tooltip: '放大编辑',
          onPressed: () => _showLargeEditor(context, controller, title),
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
      ),
      style: _fieldTextStyle,
    );
  }

  /// 顶部主行动：炭黑小胶囊（右对齐），靠明度而不是饱和色建立层级。
  /// 不铺满整行 —— 满宽深色块在这个以留白为主的页面里会显得过重。
  Widget _buildGenerateButton(OutlineController c) {
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 176,
        height: 44,
        child: ElevatedButton.icon(
          onPressed: (c.loading || c.paused)
              ? null
              : () async {
                  await c.generate();
                  await _refreshDraft();
                },
          icon: c.loading
              ? SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _p.textTertiary,
                  ),
                )
              : const Icon(Icons.auto_awesome_rounded, size: 17),
          label: Text(c.loading ? '生成中...' : '一键生成大纲'),
          style: _primaryButtonStyle(fontSize: 13.5).copyWith(
            // 生成中：按钮禁用但仍保持「同一颗按钮」的克制浅灰态
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? _p.surfaceMuted
                  : _p.textPrimary,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? _p.textTertiary
                  : _p.onAccent,
            ),
          ),
        ),
      ),
    );
  }

  /// 生成结果区：一张白卡承载书名 + 各步骤文本 + 进度。
  /// 步骤之间不画盒子，用 1px 发丝分割线 + 字距区分层级，长结果读起来像
  /// 一篇排版过的文档而不是一摞卡片。
  Widget _buildOutputCard(OutlineController c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        color: _p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.title.isNotEmpty) ...[
            Text(
              c.title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.4,
                letterSpacing: 0.1,
                color: _p.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
          ],
          // 已提交的多气泡（步骤结果 / 失败尝试的思考与输出）
          // 缓存复用实例：流式更新时未变化的气泡直接跳过重建
          ..._bubbleWidgetsFor(c.bubbles),
          // 回退：无气泡但有历史/预览内容（如断点续跑恢复）
          if (c.bubbles.isEmpty &&
              c.displayText.isNotEmpty &&
              c.liveText.isEmpty)
            _buildBubble(label: null, content: c.displayText, isError: false),
          // 实时流式气泡：每 300ms 更新，用 RepaintBoundary 隔离重绘，
          // 用普通 Text 而非 SelectableText（后者布局成本高，流式期间不可选也无妨）
          if (c.liveText.isNotEmpty)
            RepaintBoundary(
              child: _buildBubble(
                label: '生成中',
                content: c.liveText,
                isError: false,
                selectable: false,
              ),
            )
          else if (c.loading)
            _buildBubble(label: '生成中', content: '正在生成...', isError: false),
          if (c.loading) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: c.progress,
                minHeight: 2,
                backgroundColor: _p.border,
                color: _p.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              c.progressText,
              style: TextStyle(fontSize: 12, color: _p.textTertiary),
            ),
            if (c.lastStepSummary != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('最近完成：${c.lastStepSummary}', style: _helperStyle),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBanner({
    required String text,
    required IconData icon,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: foreground, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _primaryButtonStyle({double fontSize = 13}) {
    return ElevatedButton.styleFrom(
      // 炭黑主按钮：靠明度而不是饱和色建立层级，避免亮蓝铺底显廉价
      backgroundColor: _p.textPrimary,
      foregroundColor: _p.onAccent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
    );
  }

  ButtonStyle _secondaryButtonStyle({
    double fontSize = 13,
    Color? foreground,
  }) {
    return OutlinedButton.styleFrom(
      foregroundColor: foreground ?? _p.textPrimary,
      backgroundColor: _p.surface,
      side: BorderSide(color: _p.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _amberSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.pause_rounded,
                  size: 15,
                  color: _amberInk,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cardTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _p.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            cardDesc,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: _p.textTertiary,
            ),
          ),
          if (_isReedit) ...[
            const SizedBox(height: 4),
            Text(
              _isContinue ? '继续生成后将另存为新大纲，不会覆盖原记录' : '重新生成后将另存为新大纲，不会覆盖原记录',
              style: TextStyle(fontSize: 11.5, color: _amberTitle),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _checkpointCtrl,
            maxLines: null,
            minLines: 6,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: _p.textPrimary,
            ),
            decoration: _inputDecoration(fieldHint),
            // 编辑内容实时同步到控制器并防抖落盘，意外退出页面后可通过「继续上次」恢复
            onChanged: (v) => _controller.syncCheckpointEdit(v),
          ),
          const SizedBox(height: 12),
          // 导航行：返回上一步 / 下一步（按状态动态显示，仅出现有意义的方向）
          ...[
            if (canBack || canForward)
              Row(
                children: [
                  if (canBack)
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: OutlinedButton.icon(
                          onPressed: c.backCheckpoint,
                          icon: const Icon(Icons.arrow_back_rounded, size: 16),
                          label: const Text('返回上一步'),
                          style: _secondaryButtonStyle(),
                        ),
                      ),
                    ),
                  if (canBack && canForward) const SizedBox(width: 8),
                  if (canForward)
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: OutlinedButton.icon(
                          onPressed: c.forwardCheckpoint,
                          icon: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                          ),
                          label: const Text('下一步'),
                          style: _secondaryButtonStyle(),
                        ),
                      ),
                    ),
                ],
              ),
            if (canBack || canForward) const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: OutlinedButton.icon(
                    onPressed: c.regenerateCheckpoint,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重新生成'),
                    style: _secondaryButtonStyle(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    onPressed: () => c.continueCheckpoint(_checkpointCtrl.text),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('继续'),
                    style: _primaryButtonStyle(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton.icon(
              onPressed: _onCancelPressed,
              icon: const Icon(Icons.stop_rounded, size: 15),
              label: const Text('取消生成', style: TextStyle(fontSize: 12.5)),
              style: TextButton.styleFrom(foregroundColor: _p.danger),
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
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: _p.textPrimary,
            ),
          ),
        ),
        Container(
          height: 34,
          decoration: BoxDecoration(
            color: _p.surfaceMuted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_rounded),
                iconSize: 18,
                color: _p.textSecondary,
                disabledColor: _p.textTertiary,
                onPressed: value > min
                    ? () => setState(() {
                        onChanged(value - 1);
                        controller.text = '${value - 1}';
                      })
                    : null,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
              ),
              SizedBox(
                width: 36,
                child: TextField(
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _p.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
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
                icon: const Icon(Icons.add_rounded),
                iconSize: 18,
                color: _p.textSecondary,
                disabledColor: _p.textTertiary,
                onPressed: max == null || value < max
                    ? () => setState(() {
                        onChanged(value + 1);
                        controller.text = '${value + 1}';
                      })
                    : null,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 渲染单个生成内容气泡
  /// [selectable] 为 false 时（流式更新中的内容）用普通 Text 渲染，
  /// 布局成本远低于 SelectableText，显著降低大文档流式刷新时的卡顿。
  ///
  /// 视觉：正常步骤不铺底色、不描边（靠字号与间距分层）；只有「生成中」的
  /// 流式内容用浅主色底、失败内容用浅红底，避免一屏十几个描边盒子。
  Widget _buildBubble({
    String? label,
    required String content,
    required bool isError,
    bool selectable = true,
  }) {
    final bodyStyle = TextStyle(
      fontSize: 13.5,
      height: 1.65,
      color: isError ? _errorInk : _p.textPrimary,
    );
    final text = content.isEmpty ? '（无内容）' : content;
    final highlighted = isError || !selectable;
    return Container(
      width: double.infinity,
      padding: highlighted ? const EdgeInsets.all(14) : EdgeInsets.zero,
      decoration: highlighted
          ? BoxDecoration(
              color: isError ? _p.dangerSoft : _p.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null && label.isNotEmpty) ...[
            Row(
              children: [
                Icon(
                  isError
                      ? Icons.error_outline_rounded
                      : Icons.auto_awesome_rounded,
                  size: 12,
                  color: isError ? _p.danger : _p.textTertiary,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: isError ? _p.danger : _p.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          if (selectable)
            SelectableText(text, style: bodyStyle)
          else
            Text(text, style: bodyStyle),
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

/// 「一键到底」：滚到最新内容的圆形按钮（白底细描边，避开主视觉）。
class _JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;

  const _JumpToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: '滚动到底部',
      child: Material(
        color: p.surface,
        elevation: 0,
        shape: CircleBorder(
          side: BorderSide(color: p.border),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              Icons.vertical_align_bottom_rounded,
              size: 19,
              color: p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 分区标题右侧的「随机灵感」：灰字 + 灰图标，无底色，不参与主行动的色彩层级。
class _InspirationButton extends StatelessWidget {
  final VoidCallback onTap;

  const _InspirationButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shuffle_rounded, size: 13, color: p.textSecondary),
              const SizedBox(width: 4),
              Text(
                '随机灵感',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 本页分区标题：只留标题 + 副标题，不带彩色图标 chip。
///
/// settings_kit 的 [SettingsSectionHeader] 是为「设置项」设计的；内容创作页
/// 需要更克制的层级，一排蓝色图标 chip 会让页面显得杂、显廉价。
class _SectionHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isFirst;

  const _SectionHeading({
    required this.title,
    this.subtitle,
    this.isFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        4,
        isFirst ? 16 : kSettingsSectionGapTop,
        4,
        kSettingsSectionGapBot,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: p.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.25,
                color: p.textTertiary,
              ),
            ),
          ],
        ],
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

  AppPalette get _p => context.palette;

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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _p.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: _p.textTertiary,
                  ),
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
                cursorColor: _p.textPrimary,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.6,
                  color: _p.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: _hintFor(widget.title),
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: _p.textTertiary,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: () {
                  widget.onConfirm(_controller.text);
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _p.textPrimary,
                  foregroundColor: _p.onAccent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('确认'),
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

  AppPalette get _p => context.palette;

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
              Text(
                '自定义小说类型',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _p.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                cursorColor: _p.textPrimary,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: _p.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: '输入自定义类型（如：赛博朋克、末日废土...）',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: _p.textTertiary,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 13,
                  ),
                  filled: true,
                  fillColor: _p.surfaceMuted,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: _p.border),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: _p.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: _p.textPrimary,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () {
                    // 防重复点击：重复 pop 会连带关闭下层页面
                    closeDialogSafely(context, result: _controller.text.trim());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _p.textPrimary,
                    foregroundColor: _p.onAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
