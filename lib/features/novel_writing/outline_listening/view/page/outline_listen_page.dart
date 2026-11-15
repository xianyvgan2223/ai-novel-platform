import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/outline_chapter_sync.dart';
import '../../../shared/outline_load_error_view.dart';
import '../../background/outline_listen_session.dart';
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
///
/// **后台朗读**：controller 归进程级的 [OutlineListenSession] 所有，页面只是视图。
/// 退出页面朗读不会停（前台服务 + 通知栏接管），从通知点回来 / 再次进入同一条
/// 大纲都会挂回同一个 controller，当前事件 / 当前句 / 高亮 / 进度都还在。
class OutlineListenPage extends StatefulWidget {
  final OutlineRecord outline;

  /// 初始事件列表（从章节选择页传下来）；为 null 时页面自己按大纲正文解析
  final List<OutlineChapter>? chapters;

  /// 是否由「后台朗读通知」点击打开。
  ///
  /// 通知点击时 app 层把会话里正在朗读的那条大纲带过来（[fromNotification]），
  /// 页面挂回同一个 controller；本参数用于「会话已不在时」补一句说明
  /// （见 [_OutlineListenPageState._hintSessionLost]），正常路径不影响行为。
  final bool fromNotification;

  /// 注入控制器（**仅供测试**）：为 null 时页面走后台朗读会话
  @visibleForTesting
  final OutlineListenController? controller;

  /// 当前打开的朗读页实例数。
  ///
  /// 通知点击时 app 层据此判断「朗读页是否已经在前台」：已在前台就只把 App
  /// 拉到前面，不再 push 第二个页面（见 main.dart 的 _openOutlineListenPage）。
  static int openInstanceCount = 0;

  const OutlineListenPage({
    super.key,
    required this.outline,
    this.chapters,
    this.controller,
    this.fromNotification = false,
  });

  @override
  State<OutlineListenPage> createState() => _OutlineListenPageState();
}

class _OutlineListenPageState extends State<OutlineListenPage> {
  AppPalette get _p => context.palette;

  late final OutlineListenController _controller;

  /// 本页拿到的是**已有**后台会话（true）还是新建的（false）。
  ///
  /// 已有会话时不能再 init / load：那会把后台正在读的位置、卡片文本冲掉
  /// （controller 里的段列表、句子计划、高亮都会重建）。
  bool _attachedExisting = false;

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
    OutlineListenPage.openInstanceCount++;
    final injected = widget.controller;
    if (injected != null) {
      // 测试注入：沿用旧行为（页面自建、页面 dispose，不碰后台会话）
      _controller = injected;
      _controller.addListener(_onControllerChanged);
      _loading = false;
      unawaited(_prepareEngine());
      unawaited(_controller.refreshEngineHint());
      return;
    }
    // 生产路径：controller 归进程级会话所有。同一条大纲已有会话（后台朗读中 /
    // 暂停在某一处，或点通知回来）就挂回去，位置与高亮都还在；否则新建一份。
    final attach = OutlineListenSession.instance.acquire(
      widget.outline,
      widget.chapters,
      preferExisting: true,
    );
    _controller = attach.controller;
    _attachedExisting = attach.attachedExisting;
    _controller.addListener(_onControllerChanged);
    if (_attachedExisting) {
      // 挂回已有会话：结构 / 引擎都就绪了，只需要显示并定位到正在读的那条
      _loading = false;
      _restoreActiveCardOnFirstFrame();
      return;
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
    if (widget.fromNotification) {
      // 通知说「后台在朗读」，但没挂回已有会话（例如进程被系统回收后重开）：
      // 照常加载，加载完补一句说明，别让用户以为声音马上会响。
      unawaited(_load().then((_) => _hintSessionLost()));
    } else {
      _load();
    }
  }

  /// 挂回已有会话（点通知回来 / 再次进入同一条大纲）时，把正在读的卡片滚进视野。
  ///
  /// [_onControllerChanged] 只在新事件开始时才滚；挂回来的第一帧控制器不会发通知，
  /// 不主动定位的话页面会停在列表顶部，用户还得自己翻回朗读位置。
  void _restoreActiveCardOnFirstFrame() {
    final index = _controller.activeIndex;
    if (index < 0) return;
    _lastScrolledIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToSegment(index);
    });
  }

  /// 从通知进来但会话已经没了：加载完如实说一句，避免「页面在、声音不响」的困惑
  void _hintSessionLost() {
    if (!mounted) return;
    _toast('后台朗读已结束，点卡片上的播放可继续听');
  }

  /// 准备朗读引擎（能成功就顺手把「正在用内置语音」告诉页面）
  Future<void> _prepareEngine() async {
    await _controller.engine.init();
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    if (OutlineListenPage.openInstanceCount > 0) {
      OutlineListenPage.openInstanceCount--;
    }
    _controller.removeListener(_onControllerChanged);
    if (widget.controller != null) {
      // 测试注入的 controller 归页面所有
      _controller.dispose();
    } else {
      // 生产路径：controller 归后台会话所有。这里只 detach——朗读要继续；
      // 会话会在「已停止 / 已听完且没有页面挂着」时自己释放，不能在这里 dispose。
      OutlineListenSession.instance.detachPage(_controller);
    }
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToSegment(index),
    );
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
  ///
  /// 第 1 步拿到的**完整记录**要一并交给控制器（`init(record:)`）：列表页传下来
  /// 的只是小字段摘要，`foreshadows` / `characters`（人物档案）不在里面。
  /// 不补的话，保存 / 改名时写回会把伏笔清单与人物档案覆盖成空串。
  Future<void> _load() async {
    final id = widget.outline.id;
    // 没有 id（测试 / 未入库）：直接用传进来的章节
    if (id == null) {
      _controller.init(
        widget.chapters ?? const <OutlineChapter>[],
        reload: false,
      );
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _error = null);
    try {
      final record = await latestOutlineRecord(widget.outline);
      await reconcileOutlineChapters(outlineId: id, content: record.content);
      final rows = await OutlineChapterDbHelper().getByOutlineId(id);
      final chapters = rows.map((m) => OutlineChapter.fromMap(m)).toList();
      // 刚从库里读完，不用再让控制器重读一遍；完整记录一并交给控制器
      _controller.init(chapters, reload: false, record: record);
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
  /// 退出**不暂停朗读**：本页支持后台朗读（进程级会话 + Android 前台服务 + 通知），
  /// 返回列表 / 回桌面后声音继续，通知栏有进度与「停止」按钮。只有用户主动点
  /// 播控条上的「停止朗读」（或通知栏的停止）才真的停。
  Future<void> _handleExit() async {
    if (!mounted) return;
    if (!_controller.hasUnsaved) {
      Navigator.of(context).pop();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: Text('有 ${_controller.dirtyCount} 处大纲改动还没保存，要保存后退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text('不保存', style: TextStyle(color: _p.textTertiary)),
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
            backgroundColor: _p.background,
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
                        child: hasContent ? _buildList() : _buildEmptyBody(),
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
      backgroundColor: _p.surface,
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
        icon: Icon(Icons.arrow_back, color: _p.textPrimary),
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
          color: _p.accent,
          disabledColor: _p.textTertiary,
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
          color: _p.accent,
          disabledColor: _p.textTertiary,
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
            foregroundColor: _p.accent,
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
          color: _p.accent,
          tooltip: _controller.playerCollapsed ? '展开播放控制' : '收起播放控制',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: _toggleCollapsed,
        ),
        // 朗读设置：语速 / 朗读范围 / 循环都在这个面板里
        IconButton(
          icon: const Icon(Icons.tune, size: 19),
          color: _p.accent,
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
    _toast(_controller.canRedo ? '已撤回上一步（可用「取消撤回」恢复）' : '已撤回上一步');
  }

  /// 取消撤回：把刚刚撤回的那一步再做一遍
  Future<void> _redo() async {
    if (!_controller.canRedo) return;
    await _controller.redo();
    if (!mounted) return;
    _lastScrolledIndex = -1;
    _toast('已取消撤回');
  }

  /// 播控条：未播放时只有「怎么开始」，播放中才是进度 + 当前朗读的事件 + 播控。
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
      decoration: BoxDecoration(
        color: _p.accentSoft,
        border: Border(bottom: BorderSide(color: _p.border)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: '展开播放控制',
            child: InkWell(
              onTap: _toggleCollapsed,
              child: SizedBox(
                width: 30,
                height: 22,
                child: Center(
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 17,
                    color: _p.accent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开态：**一行播控 + 一行当前句**。
  ///
  /// 第一版是两行（书名 + 进度 + 两个标签一行，播控一行）再加一行状态，
  /// 在窄屏上「标题 + 概要」这类标签会被挤成两行；所以播控始终只留一行：
  /// 未播放时只有「点卡片播放 + 开始 + 语速」（见 [_idlePlayerRow]），
  /// 开始听之后才是完整的一行：进度 · 当前事件 · 播控 · 语速。
  /// 朗读范围这类状态收进设置面板（顶栏齿轮打开），不再挂在播控条上抢宽度。
  /// 下方那条「当前句」只在真的停在一句上时出现（见 [_buildCurrentSentenceBar]），
  /// 收起态整块不显示（见 [_buildCollapsedPlayer]）。
  Widget _buildExpandedPlayer() {
    final segment = _controller.activeSegment;
    final playing = _controller.playing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // 窄屏（真机 360dp 那种）放不下语速，就不显示：它是次要状态，
            // 设置面板里既能看到也能改；留在这一行只会把标题挤成省略号
            final showRate = constraints.maxWidth >= 360;
            return _playerRow(segment, playing, showRate: showRate);
          },
        ),
        _buildCurrentSentenceBar(),
      ],
    );
  }

  /// 「当前句」提示条：正在读的是哪一句、这一句在事件里排第几。
  ///
  /// 卡片上的标题 / 概要输入框其实已经由 [OutlineListenTextController] 自己高亮
  /// 当前句（控制器统一维护），这条是做两件高亮做不到的事：
  /// 1. 读正文时没有输入框可高亮，只能在这里看到当前句；
  /// 2. 长卡片滚出屏幕后，仍能一眼看到「正在读哪一句」。
  ///
  /// V4.11.4 起这一条下面多了一条**可直接左右拖动的滑条**：通知栏的进度条受
  /// Android 限制只能点按（RemoteViews 没有连续触摸事件），所以真正能"像调亮度
  /// 那样拖"的入口放在页面顶部——点通知回朗读页就能立刻拖，不必滚到卡片底部。
  Widget _buildCurrentSentenceBar() {
    // 没有当前句（没开始 / 已停止 / 事件间隙）就不占版面
    if (_controller.activeIndex < 0 || _controller.activePiece == null) {
      return const SizedBox.shrink();
    }
    final total = _controller.activeSentenceCount;
    return Container(
      width: double.infinity,
      // 浅主色底 + 左侧 2dp 主色竖条：与卡片「朗读中」的配色同一套，不抢注意力
      decoration: BoxDecoration(
        color: _p.accentSoft,
        border: Border(
          left: BorderSide(color: _p.accent, width: 2),
          bottom: BorderSide(color: _p.border),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: _p.accent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '第 ${_controller.activeSentenceOrdinal}/${_controller.activeSentenceCount} 句',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: _p.accent,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 正文句子可能很长：最多两行 + 省略号，避免播控区吃掉半屏
              Expanded(
                child: Text(
                  _controller.activeSentenceText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.35,
                    color: _p.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (total > 1) _PlayerSentenceSlider(controller: _controller),
        ],
      ),
    );
  }

  /// 完整播控行：进度 · 当前事件 · 上一个/播放/下一个/停止 · 内置语音 · 语速。
  ///
  /// 只在**已有朗读位置**（[OutlineListenController.activeIndex] >= 0）时出现；
  /// 还没开始时走下面的 [_idlePlayerRow]。
  Widget _playerRow(
    OutlineListenSegment? segment,
    bool playing, {
    required bool showRate,
  }) {
    // 未播放时换成极简一行：上一版这里同样是整排控件，但上一个 / 下一个 /
    // 停止此刻全是灰的，点不动又占宽度——信息量最小、视觉噪音最大。
    if (_controller.activeIndex < 0) {
      return _idlePlayerRow(showRate: showRate);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
      decoration: BoxDecoration(
        color: _p.accentSoft,
        border: Border(bottom: BorderSide(color: _p.border)),
      ),
      child: Row(
        children: [
          // 进度只在真的开始读之后才占位置：没开始读时这一整行会换成极简提示，
          // 真机上那里的可用宽度不该被「共 N / 第 0」之类的无效数字吃掉
          Text(
            // 「只听大 / 小事件」时按范围内计数：范围过滤后还拿全篇事件数当
            // 分母，会出现「第 2/7 个事件」却已经是最后一条的错觉
            _controller.settings.scope == OutlineListenScope.all
                ? '${_controller.activeIndex + 1}/${_controller.segments.length}'
                : '${_controller.activePlayableOrdinal}/${_controller.playableCount}',
            style: TextStyle(fontSize: 9.5, color: _p.textTertiary),
          ),
          const SizedBox(width: 8),
          // 当前朗读的是哪一个事件：听的时候最怕「不知道读到哪了」
          Expanded(
            child: Text(
              // 有朗读位置时 activeSegment 不会为空；兜底文案只防极端时序
              segment == null ? '点卡片播放' : _oneLine(segment.title),
              style: TextStyle(
                fontSize: 10.5,
                height: 1.2,
                fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                color: playing ? _p.accent : _p.textSecondary,
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
          _playButton(
            playing,
            onPressed: _controller.segments.isEmpty ? null : _controller.toggle,
          ),
          const SizedBox(width: 2),
          _roundButton(
            icon: Icons.skip_next,
            tooltip: '下一个事件',
            onPressed: _controller.segments.isEmpty ? null : _controller.next,
          ),
          const SizedBox(width: 2),
          _roundButton(
            icon: Icons.stop,
            // 后台朗读唯一的显式停止入口：退出页面后声音还在读，必须有一个
            // 「现在立刻停下」的按钮（重读仍然可以用卡片上的播放按钮）。
            tooltip: '停止朗读',
            color: _p.danger,
            onPressed: _controller.activeIndex >= 0 ? _controller.stop : null,
          ),
          const SizedBox(width: 2),
          // 语速：窄屏放不下时隐藏，设置面板里仍可调（最大 4x）
          if (showRate)
            Text(
              _controller.settings.rateLabel,
              style: TextStyle(fontSize: 9.5, color: _p.textTertiary),
              maxLines: 1,
            ),
        ],
      ),
    );
  }

  /// 未播放时的极简播控行：「点卡片播放」提示 + 一个开始按钮（+ 宽屏语速）。
  ///
  /// 只保留「怎么开始」这一件事：[activeIndex] < 0 时上一个 / 下一个 / 停止
  /// 本来就是禁用态，进度数字也没有意义，全藏掉；用户点了卡片或这个按钮、
  /// 有了朗读位置之后，下面那行完整播控会立刻顶上来。
  Widget _idlePlayerRow({required bool showRate}) {
    final hasContent = _controller.segments.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
      decoration: BoxDecoration(
        color: _p.accentSoft,
        border: Border(bottom: BorderSide(color: _p.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              // 一条可读事件都没有时别再写「点卡片播放」：点了也不会有反应
              hasContent ? '点卡片播放' : '暂无可朗读事件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: _p.textTertiary),
            ),
          ),
          const SizedBox(width: 6),
          _playButton(
            false,
            // 走 play() 而不是 toggle()：未播放时语义就是「从头 / 从范围内
            // 第一个事件开始读」，控制器自己会跳过范围外事件
            onPressed: hasContent ? _controller.play : null,
          ),
          if (showRate) ...[
            const SizedBox(width: 6),
            Text(
              _controller.settings.rateLabel,
              style: TextStyle(fontSize: 9.5, color: _p.textTertiary),
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }

  /// 圆形播放 / 暂停按钮；[onPressed] 为 null 时置灰（视作不可用）。
  ///
  /// 未播放态的极简行只留一个「开始」按钮，与完整播控行的播放 / 暂停共用同一套
  /// 视觉（同一个圆形尺寸与配色），避免页面上出现两种长得不一样的播放键。
  Widget _playButton(bool playing, {VoidCallback? onPressed}) {
    final disabled = onPressed == null;
    return InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: disabled ? _p.border : _p.accent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          color: disabled ? _p.textTertiary : _p.onAccent,
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

    /// 图标颜色（默认主色）：停止按钮用红色，把自己和普通播控区分开
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: 15),
      color: color ?? _p.accent,
      disabledColor: _p.textTertiary,
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
    final ink = _p.isDark ? _p.warning : _p.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: _p.isDark
          ? _p.warning.withValues(alpha: 0.14)
          : _p.warning.withValues(alpha: 0.14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: ink),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _controller.errorMessage,
                  style: TextStyle(fontSize: 11.5, color: ink),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: ink,
                tooltip: '关闭提示',
                visualDensity: VisualDensity.compact,
                onPressed: _controller.clearError,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
    final ink = _p.isDark ? _p.warning : _p.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: _p.isDark
          ? _p.warning.withValues(alpha: 0.14)
          : _p.warning.withValues(alpha: 0.14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: ink),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _controller.engineHint,
                  style: TextStyle(fontSize: 11.5, color: ink),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 重试：丢掉旧引擎重建后再读；仍失败就把最新原因留在提示条上
  Future<void> _retryPlay() async {
    final ok = await _controller.retryPlay();
    if (!mounted || ok) return;
    final reason = _controller.errorMessage.isEmpty
        ? '还是没能开始朗读'
        : _controller.errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reason, style: const TextStyle(fontSize: 12.5)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildList() {
    final segments = _controller.segments;
    // 「只听大/小事件」的说明收成列表顶部**一条**轻横幅：以前每张范围外卡片
    // 末尾都写一行「跳过此条」，一屏里重复七八次，既吵又白占高度；范围是整页
    // 共用的状态，说一次就够了（范围恢复「全部事件」时横幅自然消失）。
    final showScopeBanner =
        _controller.settings.scope != OutlineListenScope.all;
    final bannerCount = showScopeBanner ? 1 : 0;
    return ListView.builder(
      controller: _scrollCtrl,
      // 输入法升起时视口变矮，下面的卡片会掉出缓存区被卸载；
      // 缓存区给足（与「大纲编辑」同一个理由与取值）
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      // 横幅也作为列表的第一项（而不是钉在 ListView 外面）：它跟着内容一起
      // 滚走，不长期占用本就紧张的竖向空间
      itemCount: segments.length + bannerCount,
      itemBuilder: (context, index) {
        if (showScopeBanner && index == 0) return _buildScopeBanner();
        return _buildEventCard(index - bannerCount);
      },
    );
  }

  /// 朗读范围过滤的轻提示（只在「只听大/小事件」时出现一次，位于列表顶部）。
  ///
  /// 只陈述范围与影响、不做成按钮：要改范围去顶栏「朗读设置」，这里只负责让
  /// 用户知道「为什么有些卡片不跟着读」，避免像旧版那样在每张卡片上重复解释。
  Widget _buildScopeBanner() {
    final majorOnly =
        _controller.settings.scope == OutlineListenScope.majorOnly;
    return Container(
      // 与卡片同左右边距（ListView 的 padding 已给），底部留 8dp 与卡片分隔
      margin: const EdgeInsets.only(bottom: 8),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: _p.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.volume_off, size: 13, color: _p.textTertiary),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              majorOnly ? '只听大事件 · 小事件不参与朗读' : '只听小事件 · 大事件不参与朗读',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: _p.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片上的类型标签：大事件带全篇序号（大事件57），小事件带所属大事件内的
  /// 序号（小事件2）——与大纲正文、以及「大纲编辑」页卡片是同一套写法。
  ///
  /// 序号由控制器在 [OutlineListenController._buildSegments] 里按事件列表算好
  /// （[OutlineListenSegment.typeLabel]），页面只管显示；这里不能拿
  /// [OutlineListenSegment.eventIndex] 顶替：它是所有事件的连续序号，小事件会
  /// 跳号（大事件1 后面跟着小事件2、3……），与正文的「○ 小事件1」对不上。
  Widget _typeTag(OutlineListenSegment segment) {
    final isMajor = segment.isMajor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isMajor ? _p.accent : _p.accentSoft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        segment.typeLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isMajor ? _p.onAccent : _p.accent,
        ),
      ),
    );
  }

  /// **一个事件一张卡片**（V4.8.4 起）。
  ///
  /// 版面上这张卡片就是这个事件的全部：类型标签 + 标题（可改）+ 概要整段（可改），
  /// 左上角的播放按钮表示「从这一个事件开始往下读」。上一版把事件拆成「标题一行 +
  /// 概要逐行 N 行 + 正文一行」，读的时候一行一停——那不是用户要的粒度。
  Widget _buildEventCard(int index) {
    final segment = _controller.segments[index];
    final key = _cardKeys.putIfAbsent(index, () => GlobalKey());
    final active = index == _controller.activeIndex;
    final playing = active && _controller.playing;
    return Container(
      key: key,
      // 列表里不再有每张卡片的进度条之后，卡片本身可以略收紧一点：
      // 一屏能多看到一点内容，整页的「满」主要就减在这里
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 8),
      decoration: BoxDecoration(
        color: playing ? _p.accentSoft : _p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: playing
              ? _p.accent
              : (segment.isDirty
                    ? _p.accent.withValues(alpha: 0.55)
                    : _p.border),
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
                color: _p.accent,
                tooltip: '从这一个事件开始读',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(1),
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: () => _controller.playFrom(index),
              ),
              const SizedBox(width: 2),
              _typeTag(segment),
              if (segment.hasContent) ...[
                const SizedBox(width: 6),
                Text(
                  '已写正文 ${segment.contentLength} 字',
                  style: TextStyle(fontSize: 9.5, color: _p.success),
                ),
              ],
              const SizedBox(width: 6),
              if (segment.isDirty)
                Text('已改', style: TextStyle(fontSize: 9.5, color: _p.warning)),
              const Spacer(),
              if (playing)
                Text(
                  '朗读中',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: _p.accent,
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
              decoration: InputDecoration(
                hintText: '事件标题',
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textTertiary,
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: _p.textPrimary,
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
              decoration: InputDecoration(
                hintText: '事件概要（大纲内容）',
                hintStyle: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: _p.textTertiary,
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              // 字号比上一版小一号、行高收一点：真机上一张 20 行的概要卡片
              // 原来要占满整屏（桌面截图看不出来，手机上一眼就顶到屏幕底）
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: _p.textSecondary,
              ),
            ),
          ),
          // 句子进度条只属于「正在读的那一条」：以前每张卡片末尾都挂一条，
          // 一屏里全是灰条和「共 N 句」，把标题 / 概要挤成了次要信息。
          // 现在只在当前朗读事件、并且它真的能拆出多句（拖了才有意义）时出现；
          // 其余卡片干净收尾——要看句子进度，听的时候自然会停在那张卡片上。
          if (active && _controller.activeSentenceCount > 1) ...[
            const SizedBox(height: 2),
            _SentenceSeekBar(controller: _controller, index: index),
          ],
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
            Icon(Icons.headphones_outlined, size: 56, color: _p.textTertiary),
            const SizedBox(height: 12),
            Text(
              '这条大纲还没有可朗读的事件',
              style: TextStyle(fontSize: 14, color: _p.textTertiary),
            ),
            const SizedBox(height: 6),
            Text(
              '请先在「一键生成大纲」里生成，或在「大纲编辑」里添加事件',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: _p.textTertiary),
            ),
            if (_controller.engineHint.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _controller.engineHint,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: _p.warning),
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
        decoration: BoxDecoration(
          color: _p.surface,
          border: Border(top: BorderSide(color: _p.border)),
        ),
        child: Row(
          children: [
            Icon(
              dirty > 0 ? Icons.info_outline : Icons.check_circle_outline,
              size: 14,
              color: dirty > 0 ? _p.warning : _p.success,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                dirty > 0 ? '$dirty 处改动未保存' : '所有改动已保存',
                style: TextStyle(fontSize: 12, color: _p.textSecondary),
              ),
            ),
            ElevatedButton(
              onPressed: (dirty == 0 || _controller.saving)
                  ? null
                  : () => _save(),
              style: ElevatedButton.styleFrom(
                backgroundColor: _p.accent,
                foregroundColor: _p.onAccent,
                disabledBackgroundColor: _p.border,
                disabledForegroundColor: _p.textTertiary,
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
      builder: (_) =>
          OutlineRenameSheet(controller: _controller, candidates: candidates),
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

/// 播控区下方那条**可以直接左右拖动**的句子滑条（V4.11.4）。
///
/// 为什么放在这里：通知栏里的进度条受 Android 限制只能点按（通知的自定义视图
/// 没有连续触摸事件，系统媒体通知的可拖 seekbar 在这台荣耀 Android 10 上又不
/// 渲染），真正「像调亮度那样拖」的入口只能放在 App 内。这条滑条挂在顶部播控区
/// 下面、一直可见，点通知回到朗读页就能立刻拖，不用滚到卡片底部找每卡进度条。
///
/// 拖动过程只改本地预览，松手才真正跳句（拖动中反复打断引擎会像卡带）；播放中
/// 从落点句重新朗读，暂停时只把位置挪过去（高亮/通知同步），等点播放再读。
class _PlayerSentenceSlider extends StatefulWidget {
  final OutlineListenController controller;

  const _PlayerSentenceSlider({required this.controller});

  @override
  State<_PlayerSentenceSlider> createState() => _PlayerSentenceSliderState();
}

class _PlayerSentenceSliderState extends State<_PlayerSentenceSlider> {
  AppPalette get _p => context.palette;

  /// 拖动过程中的本地预览值（0~1）；null = 没在拖，跟随控制器
  double? _dragValue;

  int get _total => widget.controller.activeSentenceCount;

  /// 进度换算成第几句（1 起），与卡片上那条进度条同一套坐标
  int _ordinalOf(double progress) {
    final total = _total;
    if (total <= 0) return 0;
    return (progress * total).ceil().clamp(1, total);
  }

  void _seekEnd(double value) {
    final ordinal = _ordinalOf(value);
    // 先清掉预览：控制器随后会通知真实位置，滑块不会一直卡在拖动值上
    setState(() => _dragValue = null);
    final index = widget.controller.activeIndex;
    if (index < 0 || ordinal <= 0) return;
    if (widget.controller.playing) {
      unawaited(widget.controller.playFromSentence(index, ordinal - 1));
    } else {
      unawaited(widget.controller.seekToSentence(ordinal - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final total = _total;
    final dragging = _dragValue != null;
    final progress = dragging ? _dragValue! : controller.activeSentenceProgress;
    final ordinal = dragging
        ? _ordinalOf(_dragValue!)
        : controller.activeSentenceOrdinal;
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          // 一个滑动小图标提示「这里可以拖」——通知栏只能点，很多人不知道页面这条能滑
          Icon(Icons.swipe, size: 12, color: _p.textTertiary),
          const SizedBox(width: 2),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                trackShape: const RectangularSliderTrackShape(),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 5.5,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
                activeTrackColor: _p.accent,
                inactiveTrackColor: _p.borderStrong,
                thumbColor: _p.accent,
                overlayColor: _p.accent.withValues(alpha: 0.13),
              ),
              child: Slider(
                // 测试用定位：页面上有两条句子滑条（这里 + 当前卡片底部），
                // 用 key 区分「顶部这条」，不靠遍历顺序 / y 坐标
                key: const ValueKey('player-sentence-slider'),
                value: progress.clamp(0.0, 1.0),
                onChangeStart: (v) => setState(() => _dragValue = v),
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: _seekEnd,
              ),
            ),
          ),
          SizedBox(
            // 与卡片进度条的标签同宽，两处句序数字对齐观感一致
            width: 54,
            child: Text(
              ordinal <= 0 ? '共 $total 句' : '第 $ordinal/$total 句',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: _p.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 当前朗读卡片上的「句子进度条」：拖到某一句松手，就从这一句开始朗读。
///
/// 只在**正在读的那一条**卡片上出现（由 [_buildEventCard] 控制）：后台朗读是整篇
/// 按范围连读的，用户听到某条想「从它的第 3 句再听一遍」时，播控条上的上一个 /
/// 下一个只到事件级，不够用；手机上也很难靠反复点播放等前几句读完，滑动直接
/// 定位最快。上一版每张卡片都挂一条（未播放的显示「共 N 句」、范围外的显示
/// 「跳过此条」），一屏里全是重复的灰条，正是用户说「太满」的主要来源，所以
/// 现在只留给真正在听的那一条。
///
/// 句数来自 [OutlineListenController.sentenceCountForIndex]（与朗读计划同一套
/// 切句），所以滑块位置和实际朗读的句子永远对得上。拖动过程只改本地预览，
/// 松手（onChangeEnd）才调 [OutlineListenController.playFromSentence]——拖动中
/// 就跳转会反复打断引擎，听起来像卡带。
class _SentenceSeekBar extends StatefulWidget {
  final OutlineListenController controller;

  /// 这张卡片对应的事件下标
  final int index;

  const _SentenceSeekBar({required this.controller, required this.index});

  @override
  State<_SentenceSeekBar> createState() => _SentenceSeekBarState();
}

class _SentenceSeekBarState extends State<_SentenceSeekBar> {
  AppPalette get _p => context.palette;

  /// 拖动过程中的本地预览值（0~1）；null = 没在拖，跟随控制器
  double? _dragValue;

  int get _total => widget.controller.sentenceCountForIndex(widget.index);

  /// 进度换算成第几句（1 起）。
  ///
  /// activeSentenceProgress 的语义是「读到第 n 句 = n/total」，所以用向上取整：
  /// 0 → 第 1 句，1.0 → 最后一句，中间落在哪句就取哪句。
  int _ordinalOf(double progress) {
    final total = _total;
    if (total <= 0) return 0;
    return (progress * total).ceil().clamp(1, total);
  }

  void _seekEnd(double value) {
    final ordinal = _ordinalOf(value);
    // 先清掉预览：控制器随后会通知真实位置，滑块不会一直卡在拖动值上
    setState(() => _dragValue = null);
    if (ordinal <= 0) return;
    unawaited(widget.controller.playFromSentence(widget.index, ordinal - 1));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final total = _total;
    final dragging = _dragValue != null;
    // 只在当前朗读事件上出现，所以进度直接跟控制器走；拖动时先用本地预览，
    // 松手才真正跳转（拖动中就跳会反复打断引擎）。
    final progress = dragging ? _dragValue! : controller.activeSentenceProgress;
    final ordinal = dragging
        ? _ordinalOf(_dragValue!)
        : controller.activeSentenceOrdinal;
    // 事件读完 / 暂停在末尾时 activeSentenceIndex 可能是 -1：这时写「第 0/N 句」
    // 只会让人困惑，退回「共 N 句」
    final label = ordinal <= 0 ? '共 $total 句' : '第 $ordinal/$total 句';

    return SizedBox(
      // 卡片已经很高了，进度条整行压在 30dp：track 2dp + 拇指 9dp + overlay 24dp
      height: 30,
      child: Row(
        children: [
          SizedBox(
            // 64dp：「第 12/14 句」在 720px/9.5sp 下实测 50dp 会被省略号截断
            // （真机验证时发现「第 12/1…」），这里给足宽度；再宽的句数也不常见
            width: 64,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: _p.textTertiary),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                trackShape: const RectangularSliderTrackShape(),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 4.5,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: _p.accent,
                inactiveTrackColor: _p.borderStrong,
                thumbColor: _p.accent,
                disabledActiveTrackColor: _p.borderStrong,
                disabledInactiveTrackColor: _p.surfaceMuted,
                disabledThumbColor: _p.textTertiary,
              ),
              // 不设 divisions：每句的位置按 (n+1)/total 落，和 activeSentenceProgress
              // 是同一套坐标；刻度模式会用 0..1 均分，反而对不上。
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                // 能显示这条进度条就说明总句数 > 1（[_buildEventCard] 已挡掉单句
                // 事件），所以永远可拖，不再需要 enabled 判断
                onChangeStart: (v) => setState(() => _dragValue = v),
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: _seekEnd,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 朗读设置面板：朗读引擎 / 朗读范围 / 朗读事件类型 / 语速 / 音调 / 连读 / 循环 / 语言
class _SpeechSettingsSheet extends StatefulWidget {
  final OutlineListenController controller;

  const _SpeechSettingsSheet({required this.controller});

  @override
  State<_SpeechSettingsSheet> createState() => _SpeechSettingsSheetState();
}

class _SpeechSettingsSheetState extends State<_SpeechSettingsSheet> {
  AppPalette get _p => context.palette;

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

  /// 改设置时**不打断朗读**：正在读的那一条读完后，下一条就用新设置。
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
      color: _p.surfaceElevated,
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
                  Icon(Icons.tune, size: 18, color: _p.accent),
                  const SizedBox(width: 6),
                  const Text(
                    '朗读设置',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: _p.textTertiary,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '朗读引擎',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              if (_loadingEngines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '正在读取可用引擎…',
                    style: TextStyle(fontSize: 11.5, color: _p.textTertiary),
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
                        selected:
                            widget.controller.selectedEngineId == option.id,
                        onTap: _switchingEngine
                            ? () {}
                            : () => _pickEngine(option),
                      ),
                  ],
                ),
              const SizedBox(height: 4),
              Text(
                widget.controller.usingBuiltinVoice
                    ? '当前使用 App 内置离线语音（系统没有可用 TTS 引擎）'
                    : '可选 DeepSeek 官方音色，也可切回手机系统 TTS 引擎；语速支持到 4x。',
                style: TextStyle(fontSize: 11, color: _p.textTertiary),
              ),
              const SizedBox(height: 14),
              Text(
                '语速',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textPrimary,
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
              const SizedBox(height: 12),
              Text(
                '朗读范围',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textPrimary,
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
              // 「朗读事件类型」与「朗读范围」是两件事：范围决定一个事件读多少内容，
              // 这里决定哪些事件参与朗读推进（全部 / 只大事件 / 只小事件）。
              // 长篇小说上百个事件时，只听大事件能顺着主线快速过一遍。
              Text(
                '朗读事件类型',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _p.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final scope in OutlineListenScope.values)
                    _choice(
                      label: scope.label,
                      selected: s.scope == scope,
                      onTap: () => _update(s.copyWith(scope: scope)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '只听大/小事件时，自动连读与上一个/下一个都只走范围内事件；卡片仍可编辑',
                style: TextStyle(fontSize: 11, color: _p.textTertiary),
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('自动连读下一条', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '关闭后每读完一条就停下，适合边听边改',
                  style: TextStyle(fontSize: 11, color: _p.textTertiary),
                ),
                value: s.autoNext,
                activeThumbColor: _p.accent,
                onChanged: (v) => _update(s.copyWith(autoNext: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('读完后循环', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  '读到最后一条后回到第一条继续',
                  style: TextStyle(fontSize: 11, color: _p.textTertiary),
                ),
                value: s.repeat,
                activeThumbColor: _p.accent,
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
          color: selected ? _p.accent : _p.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _p.accent : _p.borderStrong),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? _p.onAccent : _p.textSecondary,
          ),
        ),
      ),
    );
  }
}
