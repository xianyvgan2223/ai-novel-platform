import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/outline_chapter_sync.dart';
import '../../../shared/outline_load_error_view.dart';
import '../../../outline_editing/view/widget/event_type_tag.dart';
import '../../controller/outline_listen_controller.dart';
import '../../model/listening_segment.dart';
import '../../service/tts_engine.dart';
import 'outline_rename_sheet.dart';

/// 「听大纲改名」页面：把大纲读出来，并且**边听边改**。
///
/// 三件事：
/// 1. **听**：系统 TTS 逐条朗读（标题 / 标题 + 概要 / 标题 + 概要 + 正文），
///    自动连读、可循环、可倍速；
/// 2. **改**：列表里每一条都能就地编辑标题与概要（听到哪一条、改哪一条），
///    底部统一保存（与「大纲编辑」同一套写回逻辑）；
/// 3. **一键改名**：顶栏「改名」把整篇里的人名 / 地名一次换掉（见
///    [OutlineRenameSheet]）——「听到第 5 条发现这个人名想换」正是这个入口。
///
/// 与「大纲编辑」的分工：编辑页面向批量勾选、逐条改、最后保存；本页面向
/// 顺着听一遍、听到问题就地改，因此列表按**行**铺开（而不是按事件折叠）。
class OutlineListenPage extends StatefulWidget {
  final OutlineRecord outline;

  /// 初始事件列表（从章节选择页传下来）；为 null 时页面自己按大纲正文解析
  final List<OutlineChapter>? chapters;

  /// 注入控制器（**仅供测试**）：为 null 时页面自建
  @visibleForTesting
  final OutlineListenController? controller;

  const OutlineListenPage({
    super.key,
    required this.outline,
    this.chapters,
    this.controller,
  });

  @override
  State<OutlineListenPage> createState() => _OutlineListenPageState();
}

class _OutlineListenPageState extends State<OutlineListenPage> {
  late final OutlineListenController _controller;
  final ScrollController _scrollCtrl = ScrollController();

  /// 每条卡片一个 Key：朗读推进时把当前这条滚到可见位置
  final Map<int, GlobalKey> _cardKeys = {};

  bool _loading = true;
  Object? _error;

  /// 上一次自动滚动到的卡片下标（避免同一张卡片反复触发滚动）
  int _lastScrolledIndex = -1;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? OutlineListenController(widget.outline);
    _controller.addListener(_onControllerChanged);
    if (widget.controller == null) {
      _load();
    } else {
      _loading = false;
    }
    // 提前把语音引擎准备好：第一次点播放不用等初始化（失败也无妨，
    // 真正播放时会再试一次并把原因显示出来）。
    //
    // 控制器默认用 FallbackTtsEngine（系统 TTS 优先、失败自动回落到 App 自带的
    // 离线语音）：有些手机（魅族 18 这类精简 ROM）系统里一个 TTS 引擎都没有，
    // 以前只能报错，现在内置语音直接顶上；系统引擎可用时仍然走系统那条路。
    unawaited(_prepareEngine());
    // 顺手体检一次：本机没有语音引擎 / 缺中文语音包的话，进页面就说清楚，
    // 而不是等用户点了播放才弹一句「初始化失败」
    unawaited(_controller.refreshEngineHint());
  }

  /// 准备朗读引擎（能成功就顺手把「正在用内置语音」告诉页面）
  Future<void> _prepareEngine() async {
    await _controller.engine.init();
    if (!mounted) return;
    setState(() {});
  }
  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 朗读推进时把当前这一条滚进视野：听着听着眼睛还停在原地最容易迷失。
  ///
  /// 正在输入的时候**不滚**：用户在改某一条时画面自己跳走，比不跟随更烦
  /// （闪动的光标、正在敲的字都被带走了）。
  void _onControllerChanged() {
    final index = _controller.activeIndex;
    if (index < 0 || index == _lastScrolledIndex) return;
    _lastScrolledIndex = index;
    if (FocusManager.instance.primaryFocus?.hasFocus ?? false) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSegment(index));
  }

  /// 读取事件结构（**与「大纲编辑」的章节选择页同一套**）。
  ///
  /// 三步顺序不能变：
  /// 1. 先按 id 取**库里最新**的记录：列表页传下来的 [OutlineRecord] 是打开列表
  ///    那一刻的快照（`content` 是 final，编辑页保存只写库、不回填内存），拿旧正文
  ///    去解析会把删掉的事件找回来、把改过的标题翻回旧值；
  /// 2. 用它跑 [reconcileOutlineChapters] 校正 `outline_chapters`：识别规则的容错、
  ///    行 id 保留、正文总量不减少这些都在那里，于是本页看到的事件结构与
  ///    「大纲编辑」完全一致；
  /// 3. 最后才读章表建段落。即使章表原本是空的（还没在「大纲转章节」解析过），
  ///    第 2 步也已经按正文把事件解析入库了。
  Future<void> _load() async {
    final id = widget.outline.id;
    // 没有 id（测试 / 未入库）：直接用传进来的章节
    if (id == null) {
      _controller.init(widget.chapters ?? const <OutlineChapter>[], reload: false);
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _error = null);
    try {
      final record = await latestOutlineRecord(widget.outline);
      await reconcileOutlineChapters(outlineId: id, content: record.content);
      final rows = await OutlineChapterDbHelper().getByOutlineId(id);
      final chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      // 刚从库里读完，不用再让控制器重读一遍
      _controller.init(chapters, reload: false);
    } catch (e, st) {
      debugPrint('[outline_listen] 加载事件结构失败 outline=$id：$e\n$st');
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _scrollToSegment(int index) async {
    final key = _cardKeys[index];
    final ctx = key?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      alignment: 0.3,
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 1)),
    );
  }

  /// 保存改动（与「大纲编辑」同一套：标题与概要写回章节行并合并回大纲正文）
  Future<void> _save({bool popAfter = false}) async {
    final count = await _controller.saveAll();
    if (!mounted) return;
    if (_controller.saveError.isNotEmpty) {
      _toast('保存失败：${_controller.saveError}');
      return;
    }
    _toast(count > 0 ? '已保存 $count 个事件的改动' : '没有需要保存的修改');
    if (popAfter && mounted) Navigator.of(context).pop();
  }

  /// 退出确认：有未保存修改时询问「保存并退出 / 不保存 / 取消」。
  ///
  /// 无论走哪条路都**先停朗读**：弹着确认框、甚至已经退回列表页，声音还在读
  /// 是最容易让人以为 App 出毛病的情况。
  Future<void> _handleExit() async {
    await _controller.pause();
    if (!mounted) return;
    if (!_controller.hasUnsaved) {
      Navigator.of(context).pop();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: Text(
          '有 ${_controller.dirtyCount} 处大纲改动还没保存，要保存后退出吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text(
              '不保存',
              style: TextStyle(color: Color(0xFF999999)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'save':
        await _save(popAfter: true);
        break;
      case 'discard':
        if (mounted) Navigator.of(context).pop();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final hasContent = _controller.segments.isNotEmpty;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _handleExit();
          },
          child: Scaffold(
            backgroundColor: Colors.white,
            appBar: _buildAppBar(),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? OutlineLoadErrorView(error: _error!, onRetry: _load)
                : Column(
                    children: [
                      _buildPlayer(),
                      if (_controller.errorMessage.isNotEmpty) _buildErrorBar(),
                      if (_controller.errorMessage.isEmpty &&
                          _controller.engineHint.isNotEmpty)
                        _buildEngineHintBar(),
                      Expanded(
                        child: hasContent
                            ? _buildList()
                            : _buildEmptyBody(),
                      ),
                    ],
                  ),
            bottomNavigationBar: hasContent ? _buildBottomBar() : null,
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0.5,
      titleSpacing: 0,
      // 标题会被右侧 5 个操作按钮挤没（真机 360dp 上只剩「听大纲…」），
      // 因此按可用宽度自动降一档字号；实在放不下时省略号兜底。
      title: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 110;
          return Text(
            '听大纲改名',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 14 : 15.5,
              fontWeight: FontWeight.w600,
            ),
          );
        },
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: _handleExit,
      ),
      // 按钮之间默认各留 16dp 外边距，5 个按钮就是 80dp 白给出去；
      // 用紧凑视觉密度把它压到 4dp，标题才有位置。
      actions: [
        // 撤回 / 取消撤回：改标题、改概要、一键改名都能退回来
        IconButton(
          icon: const Icon(Icons.undo, size: 19),
          color: const Color(0xFF4D6BFE),
          disabledColor: const Color(0xFFCCCCCC),
          tooltip: '撤回',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: (_controller.saving || !_controller.canUndo)
              ? null
              : _undo,
        ),
        IconButton(
          icon: const Icon(Icons.redo, size: 19),
          color: const Color(0xFF4D6BFE),
          disabledColor: const Color(0xFFCCCCCC),
          tooltip: '取消撤回',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: (_controller.saving || !_controller.canRedo)
              ? null
              : _redo,
        ),
        // 一键改名：人名 / 地名整篇替换
        TextButton.icon(
          onPressed: _controller.segments.isEmpty ? null : _openRenameSheet,
          icon: const Icon(Icons.drive_file_rename_outline, size: 16),
          label: const Text('改名', style: TextStyle(fontSize: 12.5)),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF4D6BFE),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        // 播控收放：展开态显示「收起」，收起态显示「展开」（同一个位置，两向切换）
        IconButton(
          icon: Icon(
            _controller.playerCollapsed
                ? Icons.keyboard_arrow_down
                : Icons.keyboard_arrow_up,
            size: 21,
          ),
          color: const Color(0xFF4D6BFE),
          tooltip: _controller.playerCollapsed ? '展开播放控制' : '收起播放控制',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: _toggleCollapsed,
        ),
        // 朗读设置：语速 / 朗读范围 / 循环都在这个面板里
        IconButton(
          icon: const Icon(Icons.tune, size: 19),
          color: const Color(0xFF4D6BFE),
          tooltip: '朗读设置',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: _openSettingsSheet,
        ),
      ],
    );
  }

  /// 撤回：先停朗读（文本要换掉），再把上一步改回来并提示
  Future<void> _undo() async {
    if (!_controller.canUndo) return;
    await _controller.undo();
    if (!mounted) return;
    _lastScrolledIndex = -1; // 高度/文本变了，让下一次朗读重新跟随一次
    _toast(
      _controller.canRedo ? '已撤回上一步（可用「取消撤回」恢复）' : '已撤回上一步',
    );
  }

  /// 取消撤回：把刚刚撤回的那一步再做一遍
  Future<void> _redo() async {
    if (!_controller.canRedo) return;
    await _controller.redo();
    if (!mounted) return;
    _lastScrolledIndex = -1;
    _toast('已取消撤回');
  }

  /// 播控条：进度 + 当前朗读的事件 + 播放 / 上一个 / 下一个。
  ///
  /// **可收起**：按钮在顶栏（同一个位置两向切换：展开态是「收起」箭头，收起态是
  /// 「展开」箭头），播控条自己不再带按钮，版面因此干净。
  Widget _buildPlayer() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: _controller.playerCollapsed
          ? _buildCollapsedPlayer()
          : _buildExpandedPlayer(),
    );
  }

  /// 收起态：一条 22dp 窄条。
  ///
  /// 只留左侧一枚向下的箭头表示「这里收着一块播控，点它放下来」；
  /// 不放播放控件——收起就是为了把屏幕让给下面的卡片。
  Widget _buildCollapsedPlayer() {
    return Container(
      width: double.infinity,
      height: 22,
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FF),
        border: Border(bottom: BorderSide(color: Color(0xFFEEF1F8))),
      ),
      child: Row(
        children: [
          Tooltip(
            message: '展开播放控制',
            child: InkWell(
              onTap: _toggleCollapsed,
              child: const SizedBox(
                width: 30,
                height: 22,
                child: Center(
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 17,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开态：**一行**，尺寸压到原来的一半左右。
  ///
  /// 第一版是两行（书名 + 进度 + 两个标签一行，播控一行）再加一行状态，
  /// 在窄屏上「标题 + 概要」这类标签会被挤成两行；现在只留一行：
  /// 进度 · 当前事件 · 播控 · 语速 · 设置入口。
  /// 朗读范围这类状态收进设置面板（顶栏齿轮打开），不再挂在播控条上抢宽度。
  Widget _buildExpandedPlayer() {
    final segment = _controller.activeSegment;
    final playing = _controller.playing;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄屏（真机 360dp 那种）放不下语速，就不显示：它是次要状态，
        // 设置面板里既能看到也能改；留在这一行只会把标题挤成省略号
        final showRate = constraints.maxWidth >= 360;
        return _playerRow(segment, playing, showRate: showRate);
      },
    );
  }

  Widget _playerRow(
    OutlineListenSegment? segment,
    bool playing, {
    required bool showRate,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FF),
        border: Border(bottom: BorderSide(color: Color(0xFFEEF1F8))),
      ),
      child: Row(
        children: [
          // 进度只在真的开始读之后才占位置：没开始读时这里显示「共 N」，
          // 真机上会把窄屏的可用宽度吃掉一截，右侧提示被截成「点卡片上的…」
          if (_controller.activeIndex >= 0) ...[
            Text(
              '${_controller.activeIndex + 1}/${_controller.segments.length}',
              style: const TextStyle(fontSize: 9.5, color: Color(0xFF999999)),
            ),
            const SizedBox(width: 8),
          ],
          // 当前朗读的是哪一个事件：听的时候最怕「不知道读到哪了」
          Expanded(
            child: Text(
              segment == null ? '点卡片播放' : _oneLine(segment.title),
              style: TextStyle(
                fontSize: 10.5,
                height: 1.2,
                fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                color: playing
                    ? const Color(0xFF4D6BFE)
                    : const Color(0xFF666666),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          _roundButton(
            icon: Icons.skip_previous,
            tooltip: '上一个事件',
            onPressed: _controller.segments.isEmpty
                ? null
                : _controller.previous,
          ),
          const SizedBox(width: 2),
          _playButton(playing),
          const SizedBox(width: 2),
          _roundButton(
            icon: Icons.skip_next,
            tooltip: '下一个事件',
            onPressed: _controller.segments.isEmpty ? null : _controller.next,
          ),
          const SizedBox(width: 2),
          _roundButton(
            icon: Icons.replay,
            tooltip: '重读这一个事件',
            onPressed: _controller.segments.isEmpty
                ? null
                : _controller.replayCurrent,
          ),
          const SizedBox(width: 2),
          // 正在用 App 自带的离线语音（手机系统里没有可用的 TTS 引擎）：
          // 让用户知道声音从哪来，别以为是手机系统在念
          if (_controller.usingBuiltinVoice)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF2FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '内置语音',
                style: TextStyle(fontSize: 9, color: Color(0xFF4D6BFE)),
              ),
            ),
          // 语速：窄屏放不下时干脆不显示（设置面板里既能看到也能改）
          if (showRate)
            Text(
              _controller.settings.rateLabel,
              style: const TextStyle(fontSize: 9.5, color: Color(0xFF999999)),
              maxLines: 1,
            ),
        ],
      ),
    );
  }

  Widget _playButton(bool playing) {
    return InkWell(
      onTap: _controller.segments.isEmpty ? null : _controller.toggle,
      customBorder: const CircleBorder(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: _controller.segments.isEmpty
              ? const Color(0xFFE8ECF4)
              : const Color(0xFF4D6BFE),
          shape: BoxShape.circle,
        ),
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          color: _controller.segments.isEmpty
              ? const Color(0xFF999999)
              : Colors.white,
          size: 16,
        ),
      ),
    );
  }

  /// 收起 / 展开播放控制（展开态的收起按钮、收起态的展开按钮都走这里）
  void _toggleCollapsed() {
    _controller.setPlayerCollapsed(!_controller.playerCollapsed);
    _lastScrolledIndex = -1; // 高度变了，让下一次朗读重新跟随一次
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 15),
      color: const Color(0xFF4D6BFE),
      disabledColor: const Color(0xFFCCCCCC),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(2),
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
    );
  }

  /// 朗读出错时的提示条：给出原因 + 重试入口（不静默失败）
  ///
  /// 「重试」走 [OutlineListenController.retryPlay]：它会先把原生引擎实例丢掉
  /// 重建再读——用户按提示去系统里装好 / 启用好语音引擎后，只有这样才能在不杀
  /// App 的前提下恢复（只重发一次 init 会拿回原生缓存的失败结果）。
  Widget _buildErrorBar() {
    final noEngine = !_controller.engine.isAvailable && _controller.engineHint.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: const Color(0xFFFFF4E5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: Color(0xFFE65100)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _controller.errorMessage,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFE65100)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: const Color(0xFFE65100),
                tooltip: '关闭提示',
                visualDensity: VisualDensity.compact,
                onPressed: _controller.clearError,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 本机一个引擎都没有时，第一条该走的是「先去商店装一个」：
              // 系统设置页里首选引擎是「无」，用户到那儿没有东西可选
              if (noEngine)
                TextButton(
                  onPressed: _openVoiceEngineStore,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('去商店装引擎', style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: _openTtsSettings,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('去系统设置', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _retryPlay,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('重试', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 进页面体检出的引擎问题（本机没有引擎 / 缺中文语音包）：提前说清 + 两条出路。
  ///
  /// 与 [_buildErrorBar] 的分工：这条是**还没点播放**时的预警，那条是**读完失败**
  /// 后的报错；同时只显示一条，免得同一个原因说两遍。
  ///
  /// 「去商店装引擎」排在前面是有原因的：本机一个引擎都没有时，系统「文字转语音」
  /// 页里首选引擎就是「无」，用户到那儿也没东西可选（魅族 18 真机实测画面），
  /// 必须先在手机商店里装一个引擎 App。
  Widget _buildEngineHintBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: const Color(0xFFFFF8E1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Color(0xFF8D6E63)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _controller.engineHint,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF8D6E63)),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _openVoiceEngineStore,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text(
                  '去商店装引擎',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8D6E63)),
                ),
              ),
              TextButton(
                onPressed: _openTtsSettings,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text(
                  '去系统设置',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8D6E63)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 去应用商店搜「语音引擎」：本机一个引擎都没有时的第一步。
  ///
  /// App 不能替用户装引擎（Android 不允许静默安装 APK），但能把他送到商店搜索页，
  /// 在手机上一键搜到、一键装完，回来点「重试」即可。
  Future<void> _openVoiceEngineStore() async {
    final ok = await _controller.openVoiceEngineStore();
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '没找到应用商店，请在手机商店里搜「语音引擎」安装（讯飞语音引擎 / Google 语音服务等）',
          style: TextStyle(fontSize: 12.5),
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }

  /// 重试：丢掉旧引擎重建后再读；仍失败就把最新原因留在提示条上
  Future<void> _retryPlay() async {
    final ok = await _controller.retryPlay();
    if (!mounted || ok) return;
    final reason = _controller.errorMessage.isEmpty ? '还是没能开始朗读' : _controller.errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reason, style: const TextStyle(fontSize: 12.5)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 去系统「文字转语音」设置页：装引擎 / 换引擎 / 换发音人都在这一步
  Future<void> _openTtsSettings() async {
    final ok = await _controller.openTtsSettings();
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '本机没找到「文字转语音」设置页，请在系统设置里搜索「文字转语音」或「TTS」',
          style: TextStyle(fontSize: 12.5),
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Widget _buildList() {
    final segments = _controller.segments;
    // 大事件序号按当前卡片表算一次：卡片逐个问的话，每次重建都要把整张表扫一遍
    // （长大纲几百个事件），朗读时每秒重建几次就会明显卡。
    final majorNumbers = _majorNumbers(segments);
    return ListView.builder(
      controller: _scrollCtrl,
      // 输入法升起时视口变矮，下面的卡片会掉出缓存区被卸载；
      // 缓存区给足（与「大纲编辑」同一个理由与取值）
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: segments.length,
      itemBuilder: (context, index) =>
          _buildEventCard(index, majorNumbers[index]),
    );
  }

  /// 卡片上的类型标签：大事件带全篇序号（大事件57），小事件带自己的序号。
  ///
  /// 为什么小事件也带序号：共用的 [EventTypeTag] 对小事件只显示「事件」，
  /// 一张卡片上连序号都没有的话，用户没法把卡片和正文里的「○ 小事件2：」对上。
  Widget _typeTag(OutlineListenSegment segment, int? majorNumber) {
    final isMajor = segment.isMajor;
    final label = isMajor
        ? (majorNumber == null ? '大事件' : '大事件$majorNumber')
        : '小事件${segment.eventIndex}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isMajor ? const Color(0xFF4D6BFE) : const Color(0xFFEFF3FF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isMajor ? Colors.white : const Color(0xFF4D6BFE),
        ),
      ),
    );
  }

  /// 每一个卡片的大事件序号（只数大事件，与大纲正文里的「大事件N」一致）
  List<int?> _majorNumbers(List<OutlineListenSegment> segments) {
    final numbers = List<int?>.filled(segments.length, null);
    var seq = 0;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].isMajor) numbers[i] = ++seq;
    }
    return numbers;
  }

  /// **一个事件一张卡片**（V4.8.4 起）。
  ///
  /// 版面上这张卡片就是这个事件的全部：类型标签 + 标题（可改）+ 概要整段（可改），
  /// 左上角的播放按钮表示「从这一个事件开始往下读」。上一版把事件拆成「标题一行 +
  /// 概要逐行 N 行 + 正文一行」，读的时候一行一停——那不是用户要的粒度。
  Widget _buildEventCard(int index, int? majorNumber) {
    final segment = _controller.segments[index];
    final key = _cardKeys.putIfAbsent(index, () => GlobalKey());
    final active = index == _controller.activeIndex;
    final playing = active && _controller.playing;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 10),
      decoration: BoxDecoration(
        color: playing ? const Color(0xFFF5F8FF) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: playing
              ? const Color(0xFF4D6BFE)
              : (segment.isDirty
                    ? const Color(0xFFB9C8FF)
                    : const Color(0xFFE8ECF4)),
          width: playing ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行：播放（从这一个事件开始读）+ 类型标签 + 状态
          Row(
            // 居中：图标按钮自带内边距，不指定的话标签会与它错位
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  playing ? Icons.graphic_eq : Icons.play_arrow,
                  size: 17,
                ),
                color: const Color(0xFF4D6BFE),
                tooltip: '从这一个事件开始读',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(1),
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => _controller.playFrom(index),
              ),
              const SizedBox(width: 2),
              _typeTag(segment, majorNumber),
              if (segment.hasContent) ...[
                const SizedBox(width: 6),
                Text(
                  '已写正文 ${segment.contentLength} 字',
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: Color(0xFF4CAF50),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              if (segment.isDirty)
                const Text(
                  '已改',
                  style: TextStyle(fontSize: 9.5, color: Color(0xFFFF9800)),
                ),
              const Spacer(),
              if (playing)
                const Text(
                  '朗读中',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          // 事件标题
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextField(
              controller: segment.titleCtrl,
              minLines: 1,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: '事件标题',
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFBBBBBB),
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // 事件概要整段（多行保留换行）
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextField(
              controller: segment.summaryCtrl,
              minLines: 2,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: '事件概要（大纲内容）',
                hintStyle: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Color(0xFFBBBBBB),
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              // 字号比上一版小一号、行高收一点：真机上一张 20 行的概要卡片
              // 原来要占满整屏（桌面截图看不出来，手机上一眼就顶到屏幕底）
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: Color(0xFF666666),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.headphones_outlined,
              size: 56,
              color: Color(0xFFCCCCCC),
            ),
            const SizedBox(height: 12),
            const Text(
              '这条大纲还没有可朗读的事件',
              style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 6),
            const Text(
              '请先在「一键生成大纲」里生成，或在「大纲编辑」里添加事件',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Color(0xFFBBBBBB)),
            ),
            if (_controller.engineHint.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _controller.engineHint,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Color(0xFFE65100)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 底部只留「未保存状态 + 保存」。
  ///
  /// 「一键改名」原先在这里也放了一个入口，与顶栏的「改名」重复；统一收在顶栏
  /// （那里才是页面的动作区），底栏专注一件事：把改动存下去。
  Widget _buildBottomBar() {
    final dirty = _controller.dirtyCount;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            Icon(
              dirty > 0 ? Icons.info_outline : Icons.check_circle_outline,
              size: 14,
              color: dirty > 0
                  ? const Color(0xFFFF9800)
                  : const Color(0xFF4CAF50),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                dirty > 0 ? '$dirty 处改动未保存' : '所有改动已保存',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: (dirty == 0 || _controller.saving) ? null : () => _save(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4D6BFE),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE8ECF4),
                disabledForegroundColor: const Color(0xFF999999),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: _controller.saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 弹窗 ----

  /// 打开「一键改名」面板
  Future<void> _openRenameSheet() async {
    await _controller.pause();
    if (!mounted) return;
    // 候选先算好再交给面板：面板构建过程中让控制器 notifyListeners 会直接抛
    // 「setState() called during build」（候选是一次性快照，面板里也不改它）
    _controller.refreshNameCandidates();
    final candidates = _controller.nameCandidates;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutlineRenameSheet(
        controller: _controller,
        candidates: candidates,
      ),
    );
    if (!mounted) return;
    // 改名后段落文本整体变了：清掉滚动记忆，下次朗读重新跟随
    _lastScrolledIndex = -1;
  }

  /// 打开朗读设置面板
  Future<void> _openSettingsSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SpeechSettingsSheet(controller: _controller),
    );
  }
}

/// 当前朗读的那一条在播控条上只占一行：把换行压成空格
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 朗读设置面板：模式 / 语速 / 音调 / 连读 / 循环 / 语言
class _SpeechSettingsSheet extends StatefulWidget {
  final OutlineListenController controller;

  const _SpeechSettingsSheet({required this.controller});

  @override
  State<_SpeechSettingsSheet> createState() => _SpeechSettingsSheetState();
}

class _SpeechSettingsSheetState extends State<_SpeechSettingsSheet> {
  /// 本机可选的朗读引擎（跟随系统 / 内置语音 / 各个系统引擎），打开面板时拉一次
  List<TtsEngineOption> _engines = const [];
  bool _loadingEngines = true;
  bool _switchingEngine = false;

  @override
  void initState() {
    super.initState();
    _loadEngines();
  }

  Future<void> _loadEngines() async {
    final list = await widget.controller.availableEngines();
    if (!mounted) return;
    setState(() {
      _engines = list;
      _loadingEngines = false;
    });
  }

  /// 换引擎：立刻重新初始化，并把结果反馈给用户（起不来就说清原因）
  Future<void> _pickEngine(TtsEngineOption option) async {
    if (_switchingEngine) return;
    setState(() => _switchingEngine = true);
    final ok = await widget.controller.selectEngine(option.id);
    if (!mounted) return;
    setState(() => _switchingEngine = false);
    final reason = widget.controller.errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已切换到：${option.label}' : (reason.isEmpty ? '这个引擎没能启动' : reason),
          style: const TextStyle(fontSize: 12.5),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 改设置时**不打断朗读**：正在读的那一条读完后，下一条就用新设置
  /// （改一下语速就从头重读，听感上更烦）。因此这里只改配置、不重启引擎。
  void _update(OutlineSpeechSettings next) {
    widget.controller.updateSettings(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.settings;
    // 用 Material 承载面板而不是 DecoratedBox：面板里有 SwitchListTile，
    // 它要在最近的 Material 上画背景与水波纹；套在带背景色的 DecoratedBox 里
    // 会被盖住（框架会直接报「ink splashes may be invisible」）。
    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.heightOf(context) * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Row(
              children: [
                const Icon(Icons.tune, size: 18, color: Color(0xFF4D6BFE)),
                const SizedBox(width: 6),
                const Text(
                  '朗读设置',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: const Color(0xFF999999),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 朗读引擎：默认「跟随系统」，系统没有引擎时自动用 App 自带的离线语音；
            // 也可以在这里指定某个系统引擎（例如装了 eSpeak 之后想固定用它）。
            const Text(
              '朗读引擎',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 6),
            if (_loadingEngines)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '正在读取本机可用的引擎…',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF999999)),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in _engines)
                    _choice(
                      label: option.label,
                      selected: widget.controller.selectedEngineId == option.id,
                      onTap: _switchingEngine ? () {} : () => _pickEngine(option),
                    ),
                ],
              ),
            const SizedBox(height: 4),
            Text(
              widget.controller.usingBuiltinVoice
                  ? '当前用的是 App 自带语音（系统里没有可用引擎）'
                  : '正在用手机系统里的语音引擎；想换手机自带的其他引擎去系统设置里换',
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 12),
            const Text(
              '朗读范围',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in OutlineListenMode.values)
                  _choice(
                    label: mode.label,
                    selected: s.mode == mode,
                    onTap: () => _update(s.copyWith(mode: mode)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '语速',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final rate in OutlineSpeechSettings.rateOptions)
                  _choice(
                    label: '${rate}x',
                    selected: s.rate == rate,
                    onTap: () => _update(s.copyWith(rate: rate)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '音调',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final pitch in const [0.8, 1.0, 1.2, 1.4])
                  _choice(
                    label: '${pitch}x',
                    selected: s.pitch == pitch,
                    onTap: () => _update(s.copyWith(pitch: pitch)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '语音（中文朗读用 zh-CN；设备缺该语音包时会退回系统默认语言）',
              style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final lang in const ['zh-CN', 'zh-TW', 'en-US'])
                  _choice(
                    label: lang,
                    selected: s.language == lang,
                    onTap: () => _update(s.copyWith(language: lang)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                '自动连读下一条',
                style: TextStyle(fontSize: 13),
              ),
              subtitle: const Text(
                '关闭后每读完一条就停下，适合边听边改',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
              value: s.autoNext,
              activeThumbColor: const Color(0xFF4D6BFE),
              onChanged: (v) => _update(s.copyWith(autoNext: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('读完后循环', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '读到最后一条后回到第一条继续',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
              value: s.repeat,
              activeThumbColor: const Color(0xFF4D6BFE),
              onChanged: (v) => _update(s.copyWith(repeat: v)),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _choice({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF4D6BFE) : const Color(0xFFF5F7FB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF4D6BFE) : const Color(0xFFE3E8F2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : const Color(0xFF666666),
          ),
        ),
      ),
    );
  }
}
