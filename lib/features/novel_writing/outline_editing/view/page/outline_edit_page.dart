import 'package:flutter/material.dart';
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
/// 结构也能改：顶栏「添加事件」在末尾续一个大 / 小事件，卡片右上角的「＋」
/// 在该条之后插入一个事件，「🗑」删除该事件。增删同时落在大纲正文与章节行上，
/// 保存时一起生效（见 OutlineEditController.addEvent / deleteEvent）。
class OutlineEditPage extends StatefulWidget {
  final OutlineRecord outline;
  final List<OutlineChapter> chapters;

  const OutlineEditPage({
    super.key,
    required this.outline,
    required this.chapters,
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
    _controller = OutlineEditController(widget.outline);
    _controller.init(widget.chapters);
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
            child: const Text(
              '不保存',
              style: TextStyle(color: Color(0xFF999999)),
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
    return InkWell(
      onTap: () => closeDialogSafely(ctx, result: isMajor),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            EventTypeTag(
              isMajor: isMajor,
              background: isMajor
                  ? const Color(0xFF4D6BFE)
                  : const Color(0xFFEFF3FF),
              foreground: isMajor ? Colors.white : const Color(0xFF4D6BFE),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMajor ? '大事件' : '小事件',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
            if (first)
              const Text(
                '默认',
                style: TextStyle(fontSize: 10, color: Color(0xFFBBBBBB)),
              ),
          ],
        ),
      ),
    );
  }

  /// 添加事件（[at] 为插入位置，末尾追加时等于卡片数）。
  ///
  /// 默认类型跟着插入点走：接在小事件后面默认还是小事件，
  /// 接在大事件后面 / 追加到末尾默认是大事件。
  Future<void> _addEvent(int at) async {
    final majorFirst = at <= 0 || _controller.drafts[at - 1].isMajor;
    final isMajor = await _pickEventType(majorFirst: majorFirst);
    if (isMajor == null || !mounted) return;
    final localId = _controller.addEvent(index: at, isMajor: isMajor);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已添加${isMajor ? '大事件' : '小事件'}，可直接改标题；保存后生效',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
    await _scrollToDraft(localId);
  }

  /// 删除事件：先按控制器给出的「影响面」如实告知，确认后才删
  Future<void> _deleteEvent(OutlineEditDraft draft) async {
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
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
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
            backgroundColor: Colors.white,
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
  /// 连一条都建不了，只能回上一页
  Widget _buildEmptyBody() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '没有可编辑的章节',
            style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _addEvent(0),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加一个大事件'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4D6BFE),
              side: const BorderSide(color: Color(0xFFC7D2FE)),
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final count = _controller.drafts.length;
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0.5,
      centerTitle: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _novelTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '大纲编辑 · $count 章',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w400,
              color: Color(0xFF999999),
            ),
          ),
        ],
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
        onPressed: _handleExit,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          color: const Color(0xFF4D6BFE),
          disabledColor: const Color(0xFFCCCCCC),
          tooltip: '在末尾添加事件',
          onPressed: _controller.saving
              ? null
              : () => _addEvent(_controller.drafts.length),
        ),
        IconButton(
          icon: const Icon(Icons.undo, size: 20),
          color: const Color(0xFF4D6BFE),
          disabledColor: const Color(0xFFCCCCCC),
          tooltip: '撤销',
          onPressed: (!_controller.saving && _controller.canUndo)
              ? _controller.undo
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.redo, size: 20),
          color: const Color(0xFF4D6BFE),
          disabledColor: const Color(0xFFCCCCCC),
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
              : const Text(
                  '保存',
                  style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
                ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final drafts = _controller.drafts;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFF8F9FF),
          child: const Text(
            '只编辑事件标题与事件概要，不改动已写正文；卡片右上角可插入 / 删除事件，顶栏「＋」在末尾追加',
            style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            itemCount: drafts.length,
            itemBuilder: (context, index) =>
                _buildDraftCard(index, drafts[index]),
          ),
        ),
      ],
    );
  }

  /// 单章大纲卡片：类型 + 正文状态 + 序号 + 插入 / 删除 / AI 入口 + 标题 + 概要
  Widget _buildDraftCard(int index, OutlineEditDraft draft) {
    final key = _cardKeys.putIfAbsent(draft.localId, () => GlobalKey());
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: draft.isDirty
              ? const Color(0xFFB9C8FF)
              : const Color(0xFFE8ECF4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EventTypeTag(
                isMajor: draft.isMajor,
                majorNumber: _controller.majorNumberOfDraft(draft),
                background: draft.isMajor
                    ? const Color(0xFF4D6BFE)
                    : const Color(0xFFEFF3FF),
                foreground: draft.isMajor
                    ? Colors.white
                    : const Color(0xFF4D6BFE),
              ),
              // 大事件的序号已经在标签里（大事件57），这张卡上不再重复显示
              // 「本批第几张」；小事件没有别的编号，保留原来的小数字
              if (!draft.isMajor) ...[
                const SizedBox(width: 6),
                Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Text(
                draft.hasContent ? '已写正文' : '未写正文',
                style: TextStyle(
                  fontSize: 10,
                  color: draft.hasContent
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFBBBBBB),
                ),
              ),
              if (draft.isNew) ...[
                const SizedBox(width: 6),
                const Text(
                  '新增',
                  style: TextStyle(fontSize: 10, color: Color(0xFF4D6BFE)),
                ),
              ],
              if (draft.isDirty) ...[
                const SizedBox(width: 6),
                const Text(
                  '已修改',
                  style: TextStyle(fontSize: 10, color: Color(0xFFFF9800)),
                ),
              ],
              const Spacer(),
              _cardAction(
                icon: Icons.add,
                tooltip: '在它后面插入事件',
                color: const Color(0xFF4D6BFE),
                onPressed: _controller.saving
                    ? null
                    : () => _addEvent(index + 1),
              ),
              _cardAction(
                icon: Icons.delete_outline,
                tooltip: '删除该事件',
                color: const Color(0xFFE53935),
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
                  foregroundColor: const Color(0xFF4D6BFE),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          TextField(
            controller: draft.titleCtrl,
            decoration: const InputDecoration(
              hintText: '事件标题',
              hintStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFFBBBBBB),
              ),
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: draft.summaryCtrl,
            minLines: 2,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: '事件概要（大纲内容）',
              hintStyle: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: Color(0xFFBBBBBB),
              ),
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: Color(0xFF666666),
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片头部的小图标按钮（插入 / 删除）：图标比「AI 生成」更紧凑，
  /// 一行里塞得下类型标签、状态、三个操作入口
  Widget _cardAction({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      color: color,
      disabledColor: const Color(0xFFCCCCCC),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      splashRadius: 16,
    );
  }

  Widget _buildBottomBar() {
    final dirty = _controller.dirtyCount;
    final structure = _controller.hasStructureChanges;
    final pending = dirty > 0 || structure;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            Icon(
              pending ? Icons.info_outline : Icons.check_circle_outline,
              size: 14,
              color: pending
                  ? const Color(0xFFFF9800)
                  : const Color(0xFF4CAF50),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _pendingText(dirty, structure),
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _controller.saving
                  ? null
                  : () => _addEvent(_controller.drafts.length),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                '添加事件',
                style: TextStyle(fontSize: 13),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF4D6BFE),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: (!pending || _controller.saving)
                  ? null
                  : () => _save(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4D6BFE),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE8ECF4),
                disabledForegroundColor: const Color(0xFF999999),
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
