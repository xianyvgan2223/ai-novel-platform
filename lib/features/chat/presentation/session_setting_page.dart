/// lib/features/chat/presentation/session_setting_page.dart
/// 会话设置页 — 每个会话独立的系统提示词配置
///
/// 视觉：与主设置页 v2 完全一致（浅灰页面 + 白色圆角卡片 + 卡外分区标题），
/// 全部组件 / 色值 / 尺寸都从 core/widgets/settings_kit.dart 取，本文件只保留
/// 「页面结构 + 业务逻辑」：
/// - 系统提示词是一张焦点输入卡（填充输入框 + 放大编辑），输入时右上角
///   「已填写 / 未填写」状态实时变化；
/// - 说明区用 SettingsNote，把「只对当前会话生效」这类长句放进卡片，
///   不再用页面顶部「大标题 + 说明」的旧式段落。
///
/// 行为与改造前一致：initState 从 chatProvider.currentSession 读 systemPrompt；
/// 保存时 trim → updateSessionSystemPrompt（内存）→ 有 id 时写库；
/// 失败红底 SnackBar『保存失败』且不 pop，成功主色 SnackBar『会话设置已保存』后 pop。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_palette.dart';
import '../../../core/widgets/settings_kit.dart';
import '../application/chat_controller.dart'; // chatProvider
import '../data/chat_session_service.dart';

class SessionSettingsPage extends ConsumerStatefulWidget {
  const SessionSettingsPage({super.key});

  @override
  ConsumerState<SessionSettingsPage> createState() =>
      _SessionSettingsPageState();
}

class _SessionSettingsPageState extends ConsumerState<SessionSettingsPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final session = ref.read(chatProvider).currentSession;
    _controller = TextEditingController(text: session?.systemPrompt ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final chatCtrl = ref.read(chatProvider);
    final session = chatCtrl.currentSession;
    if (session == null) return;
    final p = context.palette;

    final newPrompt = _controller.text.trim();

    // 更新内存中的当前会话
    chatCtrl.updateSessionSystemPrompt(newPrompt);

    // 已有数据库 id 则同步持久化
    if (session.id != null) {
      final updated = session.copyWith(systemPrompt: newPrompt);
      try {
        await ChatSessionService.updateSession(updated);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('保存失败'),
              backgroundColor: p.danger,
              duration: const Duration(seconds: 1),
            ),
          );
        }
        return;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('会话设置已保存'),
          backgroundColor: p.accent,
          duration: const Duration(seconds: 1),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  /// 放大编辑：把提示词丢进 kit 的 v2 大编辑弹窗。
  /// 语义与改造前一致：取消不变更，确定才写回 controller。
  /// 弹窗是直接改 controller（不经过输入框 onChanged），返回后要主动刷一次
  /// build，否则右上角「已填写 / 未填写」徽标会停在旧状态。
  Future<void> _openEnlargeEditor() async {
    await showSettingsPromptDialog(
      context,
      title: '编辑系统提示词',
      controller: _controller,
      hint: '设定 AI 的角色、语气、回复风格等，留空则无限制',
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filled = _controller.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: p.background,
      appBar: SettingsAppBar(title: '会话设置', onSave: _onSave),
      body: ListView(
        padding: EdgeInsets.only(
          top: 2,
          left: kSettingsCardMarginH,
          right: kSettingsCardMarginH,
          bottom: 40 + MediaQuery.paddingOf(context).bottom,
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          // ── 1. 会话系统提示（分区标题与卡内标题分开，避免同名重复）──
          const SettingsSectionHeader(
            icon: Icons.forum_outlined,
            title: '会话系统提示',
            subtitle: '设定 AI 在当前会话中的角色与语气',
            isFirst: true,
          ),
          SettingsCard(
            children: [
              SettingsPromptCard(
                icon: Icons.forum_outlined,
                title: '系统提示词',
                controller: _controller,
                hintText: '设定 AI 的角色、语气、回复风格等，留空则无限制',
                minLines: 5,
                maxLines: 10,
                statusText: filled ? '已填写' : '未填写',
                statusColor: filled ? p.success : p.textSecondary,
                statusBackground: filled ? p.successSoft : p.surfaceMuted,
                onExpand: _openEnlargeEditor,
                // 输入时刷新「已填写 / 未填写」徽标；保存仍从 controller 读。
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),

          // ── 2. 说明 ──
          const SettingsSectionHeader(
            icon: Icons.info_outline_rounded,
            title: '说明',
          ),
          const SettingsNote(
            text: '系统提示词只对当前会话生效，切换会话不会互相影响；保存后下一条消息即生效。',
          ),
        ],
      ),
    );
  }
}
