import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../controller/outline_edit_controller.dart';
import '../../model/outline_edit_draft.dart';
import '../widget/event_type_tag.dart';
import '../widget/outline_ai_chat_sheet.dart';

/// 「大纲编辑」页面：只编辑大纲，不改动正文。
///
/// 所选章节一次性内联铺开（不再逐章切换）：每张卡片直接编辑事件标题与事件概要，
/// 卡片右上角「AI 生成」按章节唤起 AI 对话面板，生成结果可替换 / 追加概要或替换标题，
/// 底部一次保存全部改动。
///
/// 结构也能改：卡片右上角的「＋」是**唯一**的新增入口，点它先选加在这一条的
/// 上方还是下方，再选大事件 / 小事件；「🗑」删除该事件。增删同时落在大纲正文
/// 与章节行上，保存时一起生效（见 OutlineEditController.addEvent / deleteEvent）。
class OutlineEditPage extends StatefulWidget {
  final OutlineRecord outline;
  final List<OutlineChapter> chapters;

  /// 注入控制器（**仅供测试**）：为 null 时页面自建。
  ///
  /// 控制器是页面的内部状态，测试要断言「改完立即写回内存的伏笔清单」这类行为，
  /// 就必须拿到页面正在用的那一个——自己在外面 new 一个摆好状态传进来，
  /// 页面不认（它只用 outline 与 chapters 重建一份自己的）。
  @visibleForTesting
  final OutlineEditController? controller;

  const OutlineEditPage({
    super.key,
    required this.outline,
    required this.chapters,
    this.controller,
  });

  @override
  State<OutlineEditPage> createState() => _OutlineEditPageState();
}

class _OutlineEditPageState extends State<OutlineEditPage> {
  late final OutlineEditController _controller;
  final ScrollController _scrollCtrl = ScrollController();
  // 每张卡片的 Key：AI 面板关闭后把对应卡片滚到可见位置，方便核对结果；
  // 增删事件后新增的卡片也按它滚到可见位置。按**局部 id** 记，
  // 行 id 在保存后才补上，且删除时会重编序号，按行 id 记会串卡片。
  final Map<int, GlobalKey> _cardKeys = {};

  @override
  void initState() {
    super.initState();
    // 注入的控制器（测试用）已经在外面 init 过了，这里不再重复灌一遍草稿
    _controller = widget.controller ?? OutlineEditController(widget.outline);
    if (widget.controller == null) _controller.init(widget.chapters);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String get _novelTitle =>
      widget.outline.title.isNotEmpty ? widget.outline.title : '大纲编辑';

  /// 保存所有改动章节（只写标题与概要；增删事件一并落库）
  Future<void> _save({bool popAfter = false}) async {
    final count = await _controller.saveAll();
    if (!mounted) return;
    if (_controller.saveError.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${_controller.saveError}')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(count > 0 ? '已保存 $count 章大纲' : '没有需要保存的修改'),
        duration: const Duration(seconds: 1),
      ),
    );
    if (popAfter && mounted) Navigator.of(context).pop();
  }

  /// 退出确认：有未保存修改时询问「保存并退出 / 不保存 / 取消」
  Future<void> _handleExit() async {
    if (!_controller.hasUnsaved) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    final p = context.palette;
    final structure = _controller.hasStructureChanges;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: Text(
          structure
              ? '有 ${_controller.dirtyCount} 章大纲已修改，还有事件的增删未保存，要保存后退出吗？'
              : '有 ${_controller.dirtyCount} 章大纲已修改，要保存后退出吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'discard'),
            child: Text(
              '不保存',
              style: TextStyle(color: p.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'cancel'),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => closeDialogSafely(ctx, result: 'save'),
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

  /// 打开 AI 生成面板：目标为第 [index] 章
  Future<void> _openAiSheet(int index) async {
    _controller.setAiTarget(index);
    final draft = index < _controller.drafts.length
        ? _controller.drafts[index]
        : null;
    final key = draft == null ? null : _cardKeys[draft.localId];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutlineAiChatSheet(controller: _controller),
    );
    if (!mounted) return;
    final ctx = key?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.15,
      );
    }
  }

  /// 把某张卡片滚到可见位置（新增事件后让用户立刻看到并开始写标题）
  Future<void> _scrollToDraft(int localId) async {
    // 等本帧布局结束，新卡片的 Element 才挂得上
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ctx = _cardKeys[localId]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      alignment: 0.2,
    );
  }

  /// 选择插入位置：加在 [draft] 的上方还是下方
  Future<bool?> _pickPosition(OutlineEditDraft draft) {
    final subject = draft.title.isEmpty ? '当前事件' : '「${draft.title}」';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加事件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _positionOption(
              ctx,
              above: true,
              title: '在$subject上方添加',
            ),
            _positionOption(
              ctx,
              above: false,
              title: '在$subject下方添加',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _positionOption(
    BuildContext ctx, {
    required bool above,
    required String title,
  }) {
    final p = context.palette;
    return InkWell(
      onTap: () => closeDialogSafely(ctx, result: above),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              above ? Icons.vertical_align_top : Icons.vertical_align_bottom,
              size: 18,
              color: p.accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  Text(
                    above ? '排在它前面' : '排在它后面',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选择要插入的事件类型：大事件（结构节点）还是小事件（章节）
  Future<bool?> _pickEventType({required bool majorFirst}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加事件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _typeOption(
              ctx,
              isMajor: true,
              first: majorFirst,
              sub: '结构节点，正文里写成「══ 大事件N：标题 ══」',
            ),
            _typeOption(
              ctx,
              isMajor: false,
              first: !majorFirst,
              sub: '挂在所属大事件下面的小节，正文里写成「○ 小事件N：标题」',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _typeOption(
    BuildContext ctx, {
    required bool isMajor,
    required bool first,
    required String sub,
  }) {
    final p = context.palette;
    return InkWell(
      onTap: () => closeDialogSafely(ctx, result: isMajor),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            EventTypeTag(
              isMajor: isMajor,
              background: isMajor ? p.accent : p.accentSoft,
              foreground: isMajor ? p.onAccent : p.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMajor ? '大事件' : '小事件',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (first)
              Text(
                '默认',
                style: TextStyle(fontSize: 10, color: p.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  /// 添加事件：先问加在 [draft] 的上方还是下方，再问类型是大事件还是小事件，
  /// 选完两步才真的插入。
  ///
  /// [draft] 为 null（页面上一条事件都没有）时不问位置，那条只可能是第一条。
  /// 两步都选完才动结构：中途点「取消」页面上什么都不会多出来，
  /// 不会留下一条半成品卡片要用户自己删。
  /// 默认类型跟着插入点走：接在小事件后面默认还是小事件，
  /// 接在大事件后面 / 追加到末尾默认是大事件。
  Future<void> _addEvent(OutlineEditDraft? draft) async {
    var at = _controller.drafts.length;
    var above = false;
    if (draft != null) {
      final idx = _indexOfDraft(draft);
      if (idx < 0) return; // 卡片已被撤销掉，不再往下走
      final picked = await _pickPosition(draft);
      if (picked == null || !mounted) return;
      at = idx;
      above = picked;
    }
    // 弹窗期间点顶栏「撤销 / 反撤销」可能把卡片加回来或撤掉，
    // 插入点按当前列表夹一次，序号不会越界
    final index = (above ? at : at + 1).clamp(0, _controller.drafts.length);

    final majorFirst = index <= 0 || _controller.drafts[index - 1].isMajor;
    final isMajor = await _pickEventType(majorFirst: majorFirst);
    if (isMajor == null || !mounted) return;

    final localId = _controller.addEvent(
      index: index,
      isMajor: isMajor,
      // 点「下方」时锚点是上面那张卡片：位置由它算，不能按「下一张被勾选的卡片」
      // 算——只勾选了几章时两者之间可能隔着几十条
      below: !above && draft != null,
    );
    if (!mounted) return;
    final where = draft == null ? '末尾' : (above ? '上方' : '下方');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已在$where添加${isMajor ? "大事件" : "小事件"}，可直接改标题；保存后生效',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
    await _scrollToDraft(localId);
  }

  /// 草稿在列表里的下标；卡片已被撤销掉时返回 -1（此时不再往下走）。
  ///
  /// 按**局部 id** 认卡片：撤销 / 反撤销是按快照重建列表的，
  /// 同一个事件在界面上是同一张卡片、但对象实例可能已经换了一个，
  /// 用对象相等去找会找不到（`indexOf` 找不到就静默不插入）。
  int _indexOfDraft(OutlineEditDraft draft) =>
      _controller.drafts.indexWhere((d) => d.localId == draft.localId);

  /// 删除事件：先按控制器给出的「影响面」如实告知，确认后才删
  Future<void> _deleteEvent(OutlineEditDraft draft) async {
    final p = context.palette;
    final impact = _controller.deleteImpact(draft);
    final name = draft.title.isEmpty ? '（未命名事件）' : draft.title;
    final lines = <String>[];
    if (impact.hasContent) {
      lines.add('该事件已写正文（约 ${impact.contentLength} 字），删除后这部分正文会一起丢失。');
    }
    if (impact.childCount > 0) {
      lines.add(
        '它名下还有 ${impact.childCount} 个小事件'
        '${impact.childContentCount > 0 ? "（其中 ${impact.childContentCount} 个已写正文）" : ""}，'
        '删除大事件不会删掉它们，它们会归到上一个大事件名下。',
      );
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「$name」？'),
        content: Text(
          lines.isEmpty
              ? '将从大纲里移除这一条，保存后生效。'
              : lines.join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => closeDialogSafely(ctx, result: true),
            style: ElevatedButton.styleFrom(
              backgroundColor: p.danger,
              foregroundColor: p.onAccent,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _controller.deleteEvent(draft);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已删除该事件，保存后生效；可用顶栏「撤销」找回'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return PopScope(
          // 拦截系统返回：有未保存修改时先询问
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _handleExit();
          },
          child: Scaffold(
            backgroundColor: p.background,
            appBar: _buildAppBar(),
            bottomNavigationBar: _controller.drafts.isEmpty
                ? null
                : _buildBottomBar(),
            body: _controller.drafts.isEmpty
                ? _buildEmptyBody()
                : _buildBody(),
          ),
        );
      },
    );
  }

  /// 没有可编辑章节时的兜底：仍然允许「添加事件」，否则一卷大纲都没解析出来时
  /// 连一条都建不了，只能回上一页。这时没有「上一条」可选，直接追加成第一条。
  Widget _buildEmptyBody() {
    final p = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '没有可编辑的事件',
            style: TextStyle(fontSize: 14, color: p.textTertiary),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _addEvent(null),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加一个大事件'),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.accent,
              side: BorderSide(color: p.borderStrong),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final p = context.palette;
    return AppBar(
      backgroundColor: p.surface,
      elevation: 0.5,
      // 标题**左对齐**（不用 centerTitle）：右侧有撤销 / 反撤销 / 保存
      // 三个操作项，居中标题只剩很窄的可用宽度，连「大纲编辑」四个字都会被
      // 截成「大纲…」，更别说原先塞在这里的小说名了。
      // 小说名移到下方页面条整行显示。
      titleSpacing: 0,
      title: const Text(
        '大纲编辑',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: p.textPrimary),
        onPressed: _handleExit,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.undo, size: 20),
          color: p.accent,
          disabledColor: p.textTertiary,
          tooltip: '撤销',
          onPressed: (!_controller.saving && _controller.canUndo)
              ? _controller.undo
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo, size: 20),
          color: p.accent,
          disabledColor: p.textTertiary,
          tooltip: '反撤销',
          onPressed: (!_controller.saving && _controller.canRedo)
              ? _controller.redo
              : null,
        ),
        TextButton(
          onPressed: _controller.saving ? null : () => _save(),
          child: _controller.saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  '保存',
                  style: TextStyle(fontSize: 14, color: p.accent),
                ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final p = context.palette;
    final drafts = _controller.drafts;
    return Column(
      children: [
        // 页面条：整行显示小说名 + 本章事件数（标题栏放不下长书名）。
        // 「改哪里」的说明（只改标题与概要）已经去掉：标题栏里的输入框本身
        // 就写着「事件标题 / 事件概要」，再挂一行提示只是白占高度。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          color: p.accentSoft,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _novelTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${drafts.length} 个事件',
                style: TextStyle(
                  fontSize: 11,
                  color: p.textTertiary,
                ),
              ),
              const SizedBox(width: 8),
              // 伏笔清单入口：页面条右侧是空的，顺手把「伏笔 N」排在事件数后面
              // （标题栏左侧标题 + 右侧撤销/反撤销/保存已经排满，塞不下）
              _buildForeshadowsButton(),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            // 缓存区特意放大（默认只有 250px）。
            //
            // 为什么：输入法升起时视口变矮，屏幕下方的卡片会掉出缓存区被**卸载**；
            // 收起时视口还原，它们又要**重新 build** 回来。卸载便宜、重建贵
            // （一张卡片含标题 / 概要两个 TextField），所以症状表现为
            // 「升起还行、收起下降时掉帧」。
            //
            // 取值依据：最坏情况是「原本贴着视口底边的那张卡片」，它不被卸载的条件是
            // `缓存区 ≥ 键盘高度 − 卡片高度`，取最坏（卡片高度趋 0）即约等于键盘高度。
            // 手机键盘 300~400px，平板竖屏 / 横屏可达 500~600px，故取 1000 留足余量。
            // 代价是多保活几张卡片；若快速滑动列表时出现空白帧，可适当调小。
            scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            itemCount: drafts.length,
            itemBuilder: (context, index) =>
                _buildDraftCard(index, drafts[index]),
          ),
        ),
      ],
    );
  }

  /// 页面条上的「伏笔」入口：查看（并可直接编辑）这条大纲的伏笔清单。
  ///
  /// 为什么要有这个入口：伏笔清单是**只读注入**给 AI 的（提示词里的【伏笔清单】），
  /// 用户看大纲时最常问的一句就是「这里到底埋没埋那条伏笔」。此前只能退出去到
  /// 剧情账本页翻，断了「边看大纲边核对伏笔」这个动作。
  Widget _buildForeshadowsButton() {
    final p = context.palette;
    // 条数按非空行现算：清单是「每条一行」的文本，空行不算一条
    final count = _foreshadowLines(_controller.foreshadows).length;
    return InkWell(
      onTap: _openForeshadowsSheet,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: p.accentSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_border,
              size: 13,
              color: p.accent,
            ),
            const SizedBox(width: 4),
            Text(
              // 上下文还没读回来时不显示条数：开页一瞬间的「0」会让人误以为清单是空的
              _controller.contextLoaded ? '伏笔 $count' : '伏笔',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: p.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开伏笔清单面板（查看 / 编辑）
  Future<void> _openForeshadowsSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ForeshadowsSheet(controller: _controller),
    );
  }

  /// 单章大纲卡片。
  ///
  /// 版面顺序：**标题与「＋ / 🗑 / AI 生成」同一行** → 类型标签与状态 → 概要。
  ///
  /// 类型标签里带序号：大事件按全篇第几个大事件（大事件57），小事件按它在该
  /// 大事件名下第几个（小事件2）——与大纲正文里的「══ 大事件N」/「○ 小事件N」
  /// 是同一套编号，和「听大纲改名」页卡片也一致。序号由控制器按**全篇**算
  /// （不能拿本页卡片下标：只勾选了几章时，下标与正文序号毫无关系）。
  ///
  /// 为什么改：原先操作按钮独占卡片最上面一行，标题在它下面。概要有长有短时，
  /// 那张「按钮条」跟它管的那条标题会被拉开很远，连着几张卡片看下来就是一排
  /// 悬空的 ＋🗑——分不清点的是哪一条，删除这种破坏性操作尤其危险。
  /// 现在按钮贴在标题行右侧，指哪打哪。
  Widget _buildDraftCard(int index, OutlineEditDraft draft) {
    final p = context.palette;
    final key = _cardKeys.putIfAbsent(draft.localId, () => GlobalKey());
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: draft.isDirty ? p.accent.withValues(alpha: 0.5) : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 操作：同一行，按钮紧跟标题，不再悬空
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: draft.titleCtrl,
                  decoration: InputDecoration(
                    hintText: '事件标题',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.textTertiary,
                    ),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _cardAction(
                icon: Icons.add,
                tooltip: '在它上方 / 下方添加事件',
                color: p.accent,
                onPressed: _controller.saving
                    ? null
                    : () => _addEvent(draft),
              ),
              _cardAction(
                icon: Icons.delete_outline,
                tooltip: '删除该事件',
                color: p.danger,
                onPressed: _controller.saving
                    ? null
                    : () => _deleteEvent(draft),
              ),
              TextButton.icon(
                onPressed: () => _openAiSheet(index),
                icon: const Icon(Icons.auto_awesome, size: 14),
                label: const Text(
                  'AI 生成',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: p.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // 类型标签与状态：放在标题下面，作为这条大纲的属性说明
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              children: [
                EventTypeTag(
                  isMajor: draft.isMajor,
                  majorNumber: _controller.majorNumberOfDraft(draft),
                  minorNumber: _controller.minorNumberOfDraft(draft),
                  background: draft.isMajor ? p.accent : p.accentSoft,
                  foreground: draft.isMajor ? p.onAccent : p.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  draft.hasContent ? '已写正文' : '未写正文',
                  style: TextStyle(
                    fontSize: 10,
                    color: draft.hasContent
                        ? p.success
                        : p.textTertiary,
                  ),
                ),
                if (draft.isNew) ...[
                  const SizedBox(width: 6),
                  Text(
                    '新增',
                    style: TextStyle(fontSize: 10, color: p.accent),
                  ),
                ],
                if (draft.isDirty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '已修改',
                    style: TextStyle(fontSize: 10, color: p.warning),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextField(
              controller: draft.summaryCtrl,
              minLines: 2,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: '事件概要（大纲内容）',
                hintStyle: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: p.textTertiary,
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: p.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片头部的小图标按钮（添加 / 删除）：图标比「AI 生成」更紧凑，
  /// 一行里塞得下类型标签、状态、三个操作入口
  Widget _cardAction({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    final p = context.palette;
    return IconButton(
      icon: Icon(icon, size: 16),
      color: color,
      disabledColor: p.textTertiary,
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      splashRadius: 16,
    );
  }

  Widget _buildBottomBar() {
    final p = context.palette;
    final dirty = _controller.dirtyCount;
    final structure = _controller.hasStructureChanges;
    final pending = dirty > 0 || structure;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Icon(
              pending ? Icons.info_outline : Icons.check_circle_outline,
              size: 14,
              color: pending ? p.warning : p.success,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _pendingText(dirty, structure),
                style: TextStyle(
                  fontSize: 12,
                  color: p.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: (!pending || _controller.saving)
                  ? null
                  : () => _save(),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.onAccent,
                disabledBackgroundColor: p.surfaceMuted,
                disabledForegroundColor: p.textTertiary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
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
          ],
        ),
      ),
    );
  }

  /// 底部状态文案：结构改动也如实说明（否则用户看到「所有大纲已保存」会以为
  /// 刚加的事件已经生效了）
  String _pendingText(int dirty, bool structure) {
    if (dirty == 0 && !structure) return '所有大纲已保存';
    if (structure && dirty > 0) {
      return '$dirty 章大纲有修改，另有事件增删未保存';
    }
    if (structure) return '有事件增删未保存';
    return '$dirty 章大纲有未保存的修改';
  }
}

/// 伏笔清单的非空行（清单是「每条一行」的纯文本，空行不算一条）。
/// 页面条上的条数与面板里的列表共用这一处，免得两处算出不同的条数。
List<String> _foreshadowLines(String text) => text
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();

/// 大纲编辑页的「伏笔清单」面板：查看 + 就地编辑。
///
/// **改完立即落库**（[OutlineEditController.saveForeshadows]），不等底部「保存」：
/// 写回前会清掉空行与逐行空白，所以保存后列表按落库后的文本重画——
/// 用户看到的条数就是提示词里【伏笔清单】真正注入的那几条。
class _ForeshadowsSheet extends StatefulWidget {
  final OutlineEditController controller;

  const _ForeshadowsSheet({required this.controller});

  @override
  State<_ForeshadowsSheet> createState() => _ForeshadowsSheetState();
}

class _ForeshadowsSheetState extends State<_ForeshadowsSheet> {
  /// 本地副本：编辑后用它重画列表。直接读 controller 的字段也行（保存时会被
  /// 重新赋值），但副本更直白——面板里显示的永远是「本次编辑后的清单」。
  late String _text = widget.controller.foreshadows;

  Future<void> _edit() async {
    final p = context.palette;
    final editCtrl = TextEditingController(text: _text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text(
          '伏笔清单',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          // 编辑器占屏幕大半高度，长清单也能一眼看全
          constraints: BoxConstraints(
            maxHeight: MediaQuery.heightOf(context) * 0.6,
            maxWidth: MediaQuery.widthOf(context) * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '每条伏笔一行，形如：伏笔内容（埋设位置 / 计划回收时机）',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: p.surfaceMuted,
            ),
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            // 取消：什么都不写回（连内存也不动）
            onPressed: () {
              if (!closeDialogSafely(ctx, result: false)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx, result: true)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: Text(
              '保存',
              style: TextStyle(fontSize: 12, color: p.accent),
            ),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    // 先把文本取出来再用：弹窗关闭时已经用 scheduleControllerDispose 排队释放
    // 这个控制器（退场动画结束后 dispose），await 之后再读它属于「用后释放」——
    // 拿到的是空串，真机上还会偶发抛异常。
    final next = editCtrl.text;
    final error = await widget.controller.saveForeshadows(next);
    if (!mounted) return;
    setState(() => _text = widget.controller.foreshadows);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.isEmpty ? '伏笔清单已保存' : '伏笔清单保存失败：$error'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lines = _foreshadowLines(_text);
    return Container(
      // 不用满屏高度：上方编辑页仍可见，方便对着大纲看伏笔
      constraints: BoxConstraints(
        maxHeight: MediaQuery.heightOf(context) * 0.78,
      ),
      decoration: BoxDecoration(
        color: p.surfaceElevated,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行：条数 + 编辑 + 关闭
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 0),
            child: Row(
              children: [
                const SizedBox(width: 2),
                Icon(
                  Icons.bookmark_border,
                  size: 16,
                  color: p.accent,
                ),
                const SizedBox(width: 6),
                const Text(
                  '伏笔清单',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 6),
                if (lines.isNotEmpty)
                  Text(
                    '${lines.length} 条',
                    style: TextStyle(
                      fontSize: 11,
                      color: p.textTertiary,
                    ),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('编辑', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: p.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: p.textTertiary,
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => closeDialogSafely(context),
                ),
              ],
            ),
          ),
          // 说明这份清单是干什么用的：改完直接生效，不用再点底部「保存」
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'AI 生成大纲时会注入这份清单；改完立即保存，无需再点底部「保存」',
                style: TextStyle(
                  fontSize: 10,
                  height: 1.5,
                  color: p.textTertiary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: p.border),
          Flexible(
            child: lines.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    itemCount: lines.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 与剧情账本的伏笔清单同一个样式（小圆点 + 正文）
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Icon(
                              Icons.circle,
                              size: 6,
                              color: p.accent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(
                              lines[index],
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.6,
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 空态：说清「为什么空」与「去哪儿生成」，而不是只给一片白
  Widget _empty() {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        children: [
          Text(
            '（暂无伏笔清单）',
            style: TextStyle(fontSize: 13, color: p.textTertiary),
          ),
          const SizedBox(height: 6),
          Text(
            '可在「剧情账本」页点「重新提炼」由 AI 从大纲生成，或点上方「编辑」手动填写',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, height: 1.6, color: p.textTertiary),
          ),
        ],
      ),
    );
  }
}
