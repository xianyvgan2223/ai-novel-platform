import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
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

  /// 选项行（「注入同批所选事件」）是否展开：**默认收起**。
  /// 收起只影响这一行显示与否，开关状态存在控制器里，收起再展开不会变。
  bool _optionsExpanded = false;

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
    // 本 build 刻意不读 MediaQuery：面板高度依赖键盘 inset，每帧都要重算，
    // 但重算只应该发生在 _InsetSizedSheet 那一层。若在这个 build 里读，
    // 键盘弹出的整段动画期间每帧都会重跑这里，下面这棵面板内容跟着每帧重建。
    // 内容在这里只构造一次、作为 child 传下去，_InsetSizedSheet 每帧重建时
    // 拿到的是同一个实例，Flutter 会跳过它的 rebuild。
    return _InsetSizedSheet(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          _trackStream();
          final controller = widget.controller;
          return Column(
            children: [
              _buildHeader(controller),
              const Divider(height: 1),
              // 默认收起：展开时才显示选项行（开关状态不受展开 / 收起影响）
              if (_optionsExpanded) ...[
                _buildInjectToggle(controller),
                _buildInjectPriorMajorsToggle(controller),
                _buildInjectNextMajorToggle(controller),
                const Divider(height: 1),
              ],
              // 「当前大纲」作为对话里的第一条气泡展示，随对话一起滚动看全文
              Expanded(child: _buildMessageList(controller)),
              if (controller.chatError.isNotEmpty) _buildError(controller),
              _buildQuickPrompts(controller),
              _buildInput(controller),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(OutlineEditController controller) {
    final p = context.palette;
    final draft = controller.aiTargetDraft;
    final String label;
    if (draft == null) {
      label = '';
    } else if (draft.isMajor) {
      // 序号与卡片 / 大纲正文同一套：大事件全篇只数大事件
      final n = controller.majorNumberOfDraft(draft);
      label = n == null ? '大事件' : '大事件$n';
    } else {
      // 小事件序号在所属大事件内部从 1 重新计数（与正文「○ 小事件N」一致）
      final n = controller.minorNumberOfDraft(draft);
      label = n == null ? '小事件' : '小事件$n';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 6),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 18, color: p.accent),
          const SizedBox(width: 6),
          const Text(
            'AI 生成大纲',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.isEmpty ? '' : '当前：$label',
              style: TextStyle(fontSize: 11, color: p.textTertiary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.delete_sweep_outlined,
              size: 20,
              color: p.textTertiary,
            ),
            tooltip: '清空对话',
            onPressed: controller.chatting ? null : controller.clearChat,
          ),
          // 选项行（「注入同批所选事件」）的收起 / 展开：默认收起，
          // 收起只是把这一行藏起来，不影响开关本身的状态
          IconButton(
            icon: Icon(
              _optionsExpanded ? Icons.expand_less : Icons.expand_more,
              size: 22,
              // 收起时如果选项里有开着的，图标用主色点一下，提示里面有生效的设置
              color:
                  controller.injectSelectedEvents ||
                      controller.injectPriorMajors ||
                      controller.injectNextMajor
                  ? p.accent
                  : p.textTertiary,
            ),
            tooltip: _optionsExpanded ? '收起选项' : '展开选项',
            onPressed: () =>
                setState(() => _optionsExpanded = !_optionsExpanded),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: p.textSecondary),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 「注入同批所选事件」开关：打开后，除当前事件外，把本次在选事件页一起勾选、
  /// 正在编辑的其他事件也交给 AI；已经作为【前一/后续事件】【所属大事件】
  /// 【之前所有大事件】注入过的不会重复注入
  /// （见 OutlineEditController.aiSelectedEventsText）。
  /// 关闭时提示词与原来完全一致。
  Widget _buildInjectToggle(OutlineEditController controller) {
    final on = controller.injectSelectedEvents;
    return _optionRow(
      icon: Icons.playlist_add_check,
      title: '注入同批所选事件',
      // 只编辑了一个事件时如实说明，避免开了开关却没变化让人困惑
      subtitle: controller.drafts.length <= 1
          ? '本次只编辑了 1 个事件，没有其他所选事件可注入'
          : '把本次一起勾选的其他事件也交给 AI；已在前文里的不重复注入',
      value: on,
      onChanged: controller.setInjectSelectedEvents,
    );
  }

  /// 「注入之前所有大事件」开关：打开后把**当前事件之前**的每个大事件（标题 + 概要）
  /// 按时间先后交给 AI，让它接着前文写而不是凭空编。
  ///
  /// 只往前取：当前事件之后的大事件一律不注入（还没发生的剧情提前给模型，
  /// 等于让它照着后面的走向写伏笔）。与【所属大事件】【前一事件】【同批所选事件】
  /// 的重叠由控制器统一去重，同一个大事件在提示词里只出现一次。
  Widget _buildInjectPriorMajorsToggle(OutlineEditController controller) {
    final on = controller.injectPriorMajors;
    final injectable = controller.aiPriorMajorsCount;
    final String subtitle;
    if (on && injectable > 0) {
      subtitle = '已注入当前事件之前的 $injectable 个大事件；之后的大事件不注入，重复的不再列一遍';
    } else if (on) {
      // 开了却没东西可注入时如实说明（前文本来就没有大事件）
      subtitle = '当前事件之前还没有大事件，本次没有可注入的内容';
    } else {
      subtitle = '把当前事件之前的所有大事件大纲交给 AI；之后的大事件不注入';
    }
    return _optionRow(
      icon: Icons.account_tree_outlined,
      title: '注入之前所有大事件',
      subtitle: subtitle,
      value: on,
      onChanged: controller.setInjectPriorMajors,
    );
  }

  /// 「注入下一个大事件」开关：打开后把当前事件**之后**第一个大事件（跳过中间
  /// 的小事件）整段交给 AI，让它知道这一阶段该往哪收尾、该埋什么钩子。
  ///
  /// 这是唯一会主动把后面剧情交给模型的开关，所以只在用户点名要的时候才注入。
  /// 开着时它恒定由【下一个大事件】这一节给出，不在【后续事件】里重复出现。
  Widget _buildInjectNextMajorToggle(OutlineEditController controller) {
    final on = controller.injectNextMajor;
    final String subtitle;
    if (!on) {
      subtitle = '把当前事件之后最近的大事件也交给 AI，便于收尾衔接';
    } else if (controller.aiHasNextMajorToInject) {
      subtitle = '已注入下一个大事件；它不再在「后续事件」里重复出现';
    } else {
      subtitle = '当前事件之后还没有大事件，本次没有可注入的内容';
    }
    return _optionRow(
      icon: Icons.flag_outlined,
      title: '注入下一个大事件',
      subtitle: subtitle,
      value: on,
      onChanged: controller.setInjectNextMajor,
    );
  }

  /// 选项行：整行可点（点文字也能开关），右侧是迷你开关。
  /// 两个选项行共用这一处，保证样式与交互一致。
  Widget _optionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final p = context.palette;
    return Material(
      // 底色交给 Material，InkWell 的水波才不会被自己盖住
      color: value ? p.accentSoft : p.surface,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 3, 10, 3),
          child: Row(
            children: [
              Icon(
                icon,
                size: 15,
                color: value ? p.accent : p.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: value ? p.accent : p.textSecondary,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.3,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _MiniSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }

  /// 「当前大纲」气泡：对话里的第一条消息，展示正在修改的事件标题与概要。
  /// 内容随编辑实时更新，整条气泡随对话列表一起滚动（不固定在上方），
  /// 长概要也能完整看到。
  Widget _buildOutlineBubble(OutlineEditDraft draft) {
    final p = context.palette;
    final summary = draft.summary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: _outlineBubbleKey,
        margin: const EdgeInsets.only(bottom: 10, right: 20),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: p.accentSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.borderStrong),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 13,
                  color: p.accent,
                ),
                const SizedBox(width: 4),
                Text(
                  '当前大纲',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.accent,
                  ),
                ),
                const Spacer(),
                if (draft.isDirty)
                  Text(
                    '未保存',
                    style: TextStyle(fontSize: 10, color: p.warning),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              draft.title.isEmpty ? '（未命名章节）' : draft.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
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
                    ? p.textTertiary
                    : p.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 对话为空时的引导（排在大纲气泡下方）
  Widget _buildEmptyHint() {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.forum_outlined, size: 32, color: p.textTertiary),
          const SizedBox(height: 10),
          Text(
            '和 AI 聊聊这一节怎么写',
            style: TextStyle(fontSize: 12, color: p.textTertiary),
          ),
          const SizedBox(height: 4),
          Text(
            'AI 会读取小说设定、所属大事件与前后章节大纲，只生成大纲，不改动正文',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: p.textTertiary,
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
      // 理由同 outline_edit_page：本面板高度随键盘 inset 收缩 / 还原，
      // 视口变矮时气泡被卸载、还原时又要重新 build（长文本气泡重建更贵），
      // 于是「收起键盘」这一步掉帧。取值依据见 outline_edit_page 的注释
      //（缓存区 ≳ 键盘高度即可），平板 / 横屏键盘更高，故取 1000 而非压线值。
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
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
    final p = context.palette;
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: p.bubbleUser,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            msg.content,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: p.bubbleUserText,
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
          color: p.bubbleAssistant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.hasThinking) _ThinkingPanel(thinking: msg.thinking),
            if (trimming.isEmpty && msg.streaming)
              Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '生成中...',
                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                  ),
                ],
              )
            else
              // 用 Text 而非 SelectableText：AI 输出往往很长，而 SelectableText
              // 内部是一个完整的 EditableText（自带 FocusNode、TextEditingController
              // 与 RenderEditable），长文本重新排版的代价明显更高——这块又恰好是
              // 流式输出时每来一个分片都要重建的地方。需要整段复制时用气泡下方的
              //「复制」按钮（_actionButton('复制', ...)）。
              Text(
                msg.streaming ? '${msg.content}▍' : msg.content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: p.bubbleAssistantText,
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
    final p = context.palette;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accent,
        side: BorderSide(color: p.borderStrong),
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
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: p.dangerSoft,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: p.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              controller.chatError,
              style: TextStyle(fontSize: 11, color: p.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickPrompts(OutlineEditController controller) {
    final p = context.palette;
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
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border),
              ),
              child: Text(
                prompt,
                style: TextStyle(
                  fontSize: 11,
                  color: enabled ? p.accent : p.textTertiary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInput(OutlineEditController controller) {
    final p = context.palette;
    final chatting = controller.chatting;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
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
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: p.textTertiary,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  filled: true,
                  fillColor: p.surfaceMuted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.border),
                  ),
                ),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(width: 4),
            chatting
                ? IconButton(
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      color: p.danger,
                    ),
                    tooltip: '停止生成',
                    onPressed: controller.stopChat,
                  )
                : IconButton(
                    icon: Icon(Icons.send, color: p.accent),
                    tooltip: '发送',
                    onPressed: () => _send(),
                  ),
          ],
        ),
      ),
    );
  }
}

/// 面板外壳：高度随键盘 inset 压缩，但不会因此重建 [child]。
///
/// 单独抽出来的原因见 `_OutlineAiChatSheetState.build` 的注释：读 MediaQuery
/// 的那一层在键盘动画期间每帧都会重建，只有把内容作为 child 传进来，
/// 重建才会停在「外壳」这一层，面板内部不会被牵连。
class _InsetSizedSheet extends StatelessWidget {
  const _InsetSizedSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screenHeight = MediaQuery.heightOf(context);
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    // 键盘弹出时压缩面板高度，保证标题栏与输入框始终可见；
    // 不用满屏高度，留出上方页面可见（配合面板内的「当前大纲」预览）
    final height = (screenHeight * 0.8 - insets)
        .clamp(260.0, screenHeight)
        .toDouble();
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: p.surfaceElevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: child,
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
    final p = context.palette;
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
                  color: p.textTertiary,
                ),
                const SizedBox(width: 2),
                Text(
                  '思考过程（${widget.thinking.characters.length} 字）',
                  style: TextStyle(
                    fontSize: 11,
                    color: p.textTertiary,
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
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: p.border),
              ),
              child: Text(
                widget.thinking,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: p.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 面板里的小开关：Material 3 的 [Switch] 又大又深（关闭态滑块是深灰、轨道也很厚），
/// 摆在白色面板上太抢眼——这里用 36×20 的轻量开关，关闭态是浅灰、打开态是主色。
/// 只做展示与点击，整行的点击由外面那层 InkWell 兜底。
class _MiniSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _MiniSwitch({required this.value, required this.onChanged});

  static const double _width = 36;
  static const double _height = 20;
  static const double _inset = 2;
  static const Duration _duration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: _duration,
        width: _width,
        height: _height,
        padding: const EdgeInsets.all(_inset),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: value ? p.accent : p.switchInactive,
          borderRadius: BorderRadius.circular(_height / 2),
        ),
        child: AnimatedContainer(
          duration: _duration,
          width: _height - _inset * 2,
          height: _height - _inset * 2,
          decoration: BoxDecoration(
            color: p.isDark ? p.textPrimary : Colors.white,
            shape: BoxShape.circle,
            boxShadow: p.isDark
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
        ),
      ),
    );
  }
}
