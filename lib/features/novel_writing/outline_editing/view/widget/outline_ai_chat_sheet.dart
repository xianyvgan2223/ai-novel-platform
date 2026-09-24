import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../controller/outline_edit_controller.dart';
import '../../model/outline_edit_chat_message.dart';
import '../../model/outline_edit_draft.dart';

/// 「大纲编辑」AI 生成面板（底部弹窗）——只生成大纲，不生成正文。
///
/// 与 AI 多轮对话生成事件标题与事件概要：AI 会读取小说设定、所属大事件、
/// 前后相邻事件、剧情账本与伏笔清单，以及**编辑框中尚未保存的当前大纲**；
/// 生成结果可一键替换 / 追加到事件概要，或替换事件标题。
class OutlineAiChatSheet extends StatefulWidget {
  final OutlineEditController controller;

  const OutlineAiChatSheet({super.key, required this.controller});

  @override
  State<OutlineAiChatSheet> createState() => _OutlineAiChatSheetState();
}

class _OutlineAiChatSheetState extends State<OutlineAiChatSheet> {
  static const List<String> _quickPrompts = [
    '按小说设定写出本节概要',
    '细化本节的情节推进',
    '让本节与前后事件衔接更自然',
    '精简本节概要，去掉冗余',
    '换一个更贴切的标题',
  ];

  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final GlobalKey _outlineBubbleKey = GlobalKey(); // 「当前大纲」气泡（应用后滚回查看）
  int _lastMessageCount = 0;
  int _lastStreamLength = 0;
  bool _followOutput = true; // 用户上滑阅读时暂停自动跟随

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      final pos = _scrollCtrl.position;
      if (pos.hasContentDimensions) {
        _followOutput = pos.pixels >= pos.maxScrollExtent - 80;
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final controller = widget.controller;
    if (controller.chatting) return;
    final content = (text ?? _inputCtrl.text).trim();
    if (content.isEmpty) return;
    if (text == null) _inputCtrl.clear();
    _followOutput = true;
    controller.sendChat(content);
    _scrollToBottomSoon();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      if (pos.maxScrollExtent > 0) _scrollCtrl.jumpTo(pos.maxScrollExtent);
    });
  }

  /// 流式输出时跟随滚动：新消息或末尾内容变长时滚到底部
  void _trackStream() {
    final messages = widget.controller.messages;
    final lastLength = messages.isEmpty ? 0 : messages.last.content.length;
    if (messages.length != _lastMessageCount) {
      _lastMessageCount = messages.length;
      _followOutput = true;
    }
    if (lastLength != _lastStreamLength) {
      _lastStreamLength = lastLength;
      if (_followOutput) _scrollToBottomSoon();
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _toast('已复制到剪贴板');
  }

  /// 应用 AI 结果后把「当前大纲」气泡滚回可见位置，立刻看到改动后的完整大纲
  void _scrollToOutline() {
    final ctx = _outlineBubbleKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final insets = media.viewInsets.bottom;
    // 键盘弹出时压缩面板高度，保证标题栏与输入框始终可见；
    // 不用满屏高度，留出上方页面可见（配合面板内的「当前大纲」预览）
    final height = (media.size.height * 0.8 - insets)
        .clamp(260.0, media.size.height)
        .toDouble();
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: Container(
        height: height,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            _trackStream();
            final controller = widget.controller;
            return Column(
              children: [
                _buildHeader(controller),
                const Divider(height: 1),
                // 「当前大纲」作为对话里的第一条气泡展示，随对话一起滚动看全文
                Expanded(child: _buildMessageList(controller)),
                if (controller.chatError.isNotEmpty) _buildError(controller),
                _buildQuickPrompts(controller),
                _buildInput(controller),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(OutlineEditController controller) {
    final draft = controller.aiTargetDraft;
    final String label;
    if (draft == null) {
      label = '';
    } else {
      label = draft.isMajor
          ? '大事件'
          : '第 ${controller.aiTargetIndex + 1} 节';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 6),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 18, color: Color(0xFF4D6BFE)),
          const SizedBox(width: 6),
          const Text(
            'AI 生成大纲',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.isEmpty ? '' : '当前：$label',
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_sweep_outlined,
              size: 20,
              color: Color(0xFF999999),
            ),
            tooltip: '清空对话',
            onPressed: controller.chatting ? null : controller.clearChat,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Color(0xFF666666)),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 「当前大纲」气泡：对话里的第一条消息，展示正在修改的事件标题与概要。
  /// 内容随编辑实时更新，整条气泡随对话列表一起滚动（不固定在上方），
  /// 长概要也能完整看到。
  Widget _buildOutlineBubble(OutlineEditDraft draft) {
    final summary = draft.summary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: _outlineBubbleKey,
        margin: const EdgeInsets.only(bottom: 10, right: 20),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF3FF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD8E0FF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 13,
                  color: Color(0xFF4D6BFE),
                ),
                const SizedBox(width: 4),
                const Text(
                  '当前大纲',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
                const Spacer(),
                if (draft.isDirty)
                  const Text(
                    '未保存',
                    style: TextStyle(fontSize: 10, color: Color(0xFFFF9800)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              draft.title.isEmpty ? '（未命名章节）' : draft.title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              summary.isEmpty
                  ? '（暂无概要，可在下方告诉 AI 你想怎么写）'
                  : summary,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: summary.isEmpty
                    ? const Color(0xFFAAAAAA)
                    : const Color(0xFF555555),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 对话为空时的引导（排在大纲气泡下方）
  Widget _buildEmptyHint() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.forum_outlined, size: 32, color: Color(0xFFDDDDDD)),
          SizedBox(height: 10),
          Text(
            '和 AI 聊聊这一节怎么写',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
          SizedBox(height: 4),
          Text(
            'AI 会读取小说设定、所属大事件与前后章节大纲，只生成大纲，不改动正文',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: Color(0xFFBBBBBB),
            ),
          ),
        ],
      ),
    );
  }

  /// 对话列表：第一条是「当前大纲」气泡，其后是对话消息，
  /// 对话为空时再补一条引导。整列可滚动，长概要也能完整查看。
  Widget _buildMessageList(OutlineEditController controller) {
    final draft = controller.aiTargetDraft;
    final messages = controller.messages;
    final outlineCount = draft == null ? 0 : 1;
    final hintCount = messages.isEmpty ? 1 : 0;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      itemCount: outlineCount + messages.length + hintCount,
      itemBuilder: (context, index) {
        if (draft != null && index == 0) return _buildOutlineBubble(draft);
        final msgIndex = index - outlineCount;
        if (msgIndex < messages.length) {
          return _buildMessageBubble(messages[msgIndex], draft);
        }
        return _buildEmptyHint();
      },
    );
  }

  Widget _buildMessageBubble(
    OutlineEditChatMessage msg,
    OutlineEditDraft? draft,
  ) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF4D6BFE),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            msg.content,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    final trimming = msg.content.trim();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, right: 24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE8ECF4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.hasThinking) _ThinkingPanel(thinking: msg.thinking),
            if (trimming.isEmpty && msg.streaming)
              const Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '生成中...',
                    style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                  ),
                ],
              )
            else
              SelectableText(
                msg.streaming ? '${msg.content}▍' : msg.content,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: Color(0xFF333333),
                ),
              ),
            if (!msg.streaming &&
                trimming.isNotEmpty &&
                draft != null &&
                draft.chapterId != 0)
              _buildApplyButtons(trimming, draft),
          ],
        ),
      ),
    );
  }

  /// 生成结果的应用入口：只作用于大纲（事件概要 / 事件标题）
  Widget _buildApplyButtons(String text, OutlineEditDraft draft) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _actionButton('替换概要', () {
            draft.replaceSummary(text);
            _toast('已替换事件概要');
            _scrollToOutline();
          }),
          _actionButton('追加到概要', () {
            draft.appendSummary(text);
            _toast('已追加到事件概要');
            _scrollToOutline();
          }),
          _actionButton('替换标题', () {
            draft.replaceTitle(text);
            _toast('已替换事件标题');
            _scrollToOutline();
          }),
          _actionButton('复制', () => _copy(text)),
        ],
      ),
    );
  }

  Widget _actionButton(String label, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF4D6BFE),
        side: const BorderSide(color: Color(0xFFC7D2FE)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }

  Widget _buildError(OutlineEditController controller) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: const Color(0xFFFFF3F3),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 14, color: Color(0xFFE53935)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              controller.chatError,
              style: const TextStyle(fontSize: 11, color: Color(0xFFE53935)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickPrompts(OutlineEditController controller) {
    final enabled = !controller.chatting;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _quickPrompts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final prompt = _quickPrompts[index];
          return GestureDetector(
            onTap: enabled ? () => _send(prompt) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: enabled
                    ? const Color(0xFFF2F4F8)
                    : const Color(0xFFF8F9FB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE8ECF4)),
              ),
              child: Text(
                prompt,
                style: TextStyle(
                  fontSize: 11,
                  color: enabled
                      ? const Color(0xFF4D6BFE)
                      : const Color(0xFFBBBBBB),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInput(OutlineEditController controller) {
    final chatting = controller.chatting;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '描述你的要求，例如：把本节概要改成主角初遇反派',
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFBBBBBB),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF8F9FB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFE8ECF4)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFE8ECF4)),
                  ),
                ),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(width: 4),
            chatting
                ? IconButton(
                    icon: const Icon(
                      Icons.stop_circle_outlined,
                      color: Color(0xFFE53935),
                    ),
                    tooltip: '停止生成',
                    onPressed: controller.stopChat,
                  )
                : IconButton(
                    icon: const Icon(Icons.send, color: Color(0xFF4D6BFE)),
                    tooltip: '发送',
                    onPressed: () => _send(),
                  ),
          ],
        ),
      ),
    );
  }
}

/// AI 思考过程面板（默认折叠）：流式展示 reasoning_content
class _ThinkingPanel extends StatefulWidget {
  final String thinking;

  const _ThinkingPanel({required this.thinking});

  @override
  State<_ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<_ThinkingPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: const Color(0xFF999999),
                ),
                const SizedBox(width: 2),
                Text(
                  '思考过程（${widget.thinking.characters.length} 字）',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFC),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFEEEEEE)),
              ),
              child: Text(
                widget.thinking,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFF888888),
                ),
              ),
            ),
        ],
      ),
    );
  }
}