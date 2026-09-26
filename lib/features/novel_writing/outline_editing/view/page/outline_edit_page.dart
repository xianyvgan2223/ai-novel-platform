import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../controller/outline_edit_controller.dart';
import '../../model/outline_edit_draft.dart';
import '../widget/outline_ai_chat_sheet.dart';

/// 「大纲编辑」页面：只编辑大纲，不改动正文。
///
/// 所选章节一次性内联铺开（不再逐章切换）：每张卡片直接编辑事件标题与事件概要，
/// 卡片右上角「AI 生成」按章节唤起 AI 对话面板，生成结果可替换 / 追加概要或替换标题，
/// 底部一次保存全部改动。
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
  // 每张卡片的 Key：AI 面板关闭后把对应卡片滚到可见位置，方便核对结果
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

  /// 保存所有改动章节（只写标题与概要）
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
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: Text('有 ${_controller.dirtyCount} 章大纲已修改，要保存后退出吗？'),
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
    final key = _cardKeys[index];
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
                ? const Center(
                    child: Text(
                      '没有可编辑的章节',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF999999),
                      ),
                    ),
                  )
                : _buildBody(),
          ),
        );
      },
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
            '只编辑事件标题与事件概要，不改动已写正文；每章可单独让 AI 生成大纲',
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

  /// 单章大纲卡片：类型 + 正文状态 + 序号 + AI 入口 + 标题 + 概要
  Widget _buildDraftCard(int index, OutlineEditDraft draft) {
    final key = _cardKeys.putIfAbsent(index, () => GlobalKey());
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
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: draft.isMajor
                      ? const Color(0xFF4D6BFE)
                      : const Color(0xFFEFF3FF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  draft.isMajor ? '大事件' : '章节',
                  style: TextStyle(
                    fontSize: 10,
                    color: draft.isMajor
                        ? Colors.white
                        : const Color(0xFF4D6BFE),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${index + 1}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF999999),
                ),
              ),
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
              if (draft.isDirty) ...[
                const SizedBox(width: 6),
                const Text(
                  '已修改',
                  style: TextStyle(fontSize: 10, color: Color(0xFFFF9800)),
                ),
              ],
              const Spacer(),
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

  Widget _buildBottomBar() {
    final dirty = _controller.dirtyCount;
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
              dirty == 0 ? Icons.check_circle_outline : Icons.info_outline,
              size: 14,
              color: dirty == 0
                  ? const Color(0xFF4CAF50)
                  : const Color(0xFFFF9800),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                dirty == 0 ? '所有大纲已保存' : '$dirty 章大纲有未保存的修改',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: (dirty == 0 || _controller.saving)
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
}
