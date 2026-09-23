import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../../shared/domain/outline_record.dart';
import '../../controller/outline_edit_controller.dart';
import '../../model/outline_edit_draft.dart';
import '../widget/outline_ai_chat_sheet.dart';

/// 「大纲编辑」章节编辑页。
///
/// - 单选一章 / 多选章节都进入本页：多章时顶部可切换，未保存内容常驻内存，一次保存全部
/// - 每章可编辑：事件标题、事件概要、正文
/// - 新增 AI 生成入口：与 AI 对话生成内容，结果可直接替换 / 追加 / 插入正文，
///   也可用于替换事件概要
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

  @override
  void initState() {
    super.initState();
    _controller = OutlineEditController(widget.outline);
    _controller.init(widget.chapters);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _novelTitle =>
      widget.outline.title.isNotEmpty ? widget.outline.title : '大纲编辑';

  /// 保存所有改动章节
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
        content: Text(count > 0 ? '已保存 $count 章修改' : '没有需要保存的修改'),
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
        content: Text('有 ${_controller.dirtyCount} 章内容已修改，要保存后退出吗？'),
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

  /// 打开 AI 生成面板（与 AI 对话生成当前章节内容）
  Future<void> _openAiSheet() async {
    if (_controller.activeDraft == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OutlineAiChatSheet(controller: _controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final draft = _controller.activeDraft;
        return PopScope(
          // 拦截系统返回：有未保存修改时先询问
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _handleExit();
          },
          child: Scaffold(
            backgroundColor: Colors.white,
            appBar: _buildAppBar(draft),
            bottomNavigationBar: draft == null ? null : _buildBottomBar(),
            body: draft == null
                ? const Center(
                    child: Text(
                      '没有可编辑的章节',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF999999),
                      ),
                    ),
                  )
                : _buildBody(draft),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(OutlineEditDraft? draft) {
    final multiple = _controller.drafts.length > 1;
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
          if (multiple)
            Text(
              '第 ${_controller.activeIndex + 1}/${_controller.drafts.length} 章',
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
          icon: const Icon(Icons.auto_awesome, color: Color(0xFF4D6BFE)),
          tooltip: 'AI 生成',
          onPressed: _openAiSheet,
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

  Widget _buildBody(OutlineEditDraft draft) {
    return Column(
      children: [
        if (_controller.drafts.length > 1) _buildChapterChips(),
        _buildEventCard(draft),
        Expanded(child: _buildContentArea(draft)),
      ],
    );
  }

  /// 多章编辑时的章节切换条：带序号、标题与未保存标记
  Widget _buildChapterChips() {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        itemCount: _controller.drafts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final d = _controller.drafts[index];
          final active = index == _controller.activeIndex;
          final title = d.titleCtrl.text.trim();
          return GestureDetector(
            onTap: () => _controller.setActive(index),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: active ? const Color(0xFF4D6BFE) : const Color(0xFFF2F4F8),
                borderRadius: BorderRadius.circular(16),
                border: d.isDirty
                    ? Border.all(
                        color: active
                            ? Colors.white
                            : const Color(0xFFFF9800),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  if (d.isDirty) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: active
                            ? Colors.white
                            : const Color(0xFFFF9800),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(
                      '${index + 1}. ${title.isEmpty ? (d.isMajor ? "大事件" : "未命名") : title}',
                      style: TextStyle(
                        fontSize: 12,
                        color: active ? Colors.white : const Color(0xFF333333),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 事件标题 / 概要编辑卡片（大事件同样可编辑）
  Widget _buildEventCard(OutlineEditDraft draft) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE8ECF4)),
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
                      : const Color(0xFFE8ECF4),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  draft.isMajor ? '大事件' : '章节',
                  style: TextStyle(
                    fontSize: 10,
                    color: draft.isMajor
                        ? Colors.white
                        : const Color(0xFF666666),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '事件标题 / 事件概要',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
              ),
              const Spacer(),
              if (draft.isDirty)
                const Text(
                  '已修改',
                  style: TextStyle(fontSize: 11, color: Color(0xFFFF9800)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: draft.titleCtrl,
            decoration: const InputDecoration(
              hintText: '事件标题',
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
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '事件概要（可让 AI 生成后点「替换概要」写入）',
              hintStyle: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF666666),
            ),
          ),
        ],
      ),
    );
  }

  /// 正文编辑区：大事件是结构节点，只编辑标题与概要
  Widget _buildContentArea(OutlineEditDraft draft) {
    if (draft.isMajor) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined, size: 40, color: Color(0xFFDDDDDD)),
              SizedBox(height: 12),
              Text(
                '大事件是结构节点，只编辑标题与概要',
                style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
              ),
              SizedBox(height: 6),
              Text(
                '正文由其下的小事件章节承载；可点右上角「AI 生成」让 AI 协助完善事件概要',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFFBBBBBB),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                '正文',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${draft.wordCount} 字',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF999999),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.undo,
                  size: 18,
                  color: Color(0xFF4D6BFE),
                ),
                tooltip: '撤回',
                visualDensity: VisualDensity.compact,
                onPressed: draft.canUndo ? draft.undo : null,
              ),
              IconButton(
                icon: const Icon(
                  Icons.redo,
                  size: 18,
                  color: Color(0xFF4D6BFE),
                ),
                tooltip: '前进',
                visualDensity: VisualDensity.compact,
                onPressed: draft.canRedo ? draft.redo : null,
              ),
            ],
          ),
          Expanded(
            child: TextField(
              controller: draft.contentCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: '在此编辑章节正文，或点右上角「AI 生成」与 AI 对话生成内容',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFBBBBBB),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                ),
                contentPadding: const EdgeInsets.all(12),
                filled: true,
                fillColor: const Color(0xFFFAFAFA),
              ),
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: Color(0xFF333333),
              ),
            ),
          ),
          const SizedBox(height: 8),
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
                dirty == 0
                    ? '所有修改已保存'
                    : '$dirty 章有未保存的修改',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF666666),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _openAiSheet,
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('AI 生成', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF4D6BFE),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: (dirty == 0 || _controller.saving) ? null : () => _save(),
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
