/// lib/views/session_setting_page.dart
/// 会话设置页 — 每个会话独立的系统提示词配置

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/chat_session_service.dart';
import 'chat_page.dart'; // chatProvider

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
            const SnackBar(
              content: Text('保存失败'),
              backgroundColor: Color(0xFFFF4D4F),
              duration: Duration(seconds: 1),
            ),
          );
        }
        return;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('会话设置已保存'),
          backgroundColor: Color(0xFF4D6BFE),
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '会话设置',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _onSave,
            child: const Text(
              '保存',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4D6BFE),
              ),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          const Text(
            '系统提示词',
            style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 3,
              style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              decoration: const InputDecoration(
                hintText: '设定 AI 的角色、语气、回复风格等，留空则无限制',
                hintStyle: TextStyle(fontSize: 13, color: Color(0xFFBBBBBB)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '每个会话可独立设置系统提示词，用于定制 AI 在当前对话中的行为。',
            style: TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
          ),
        ],
      ),
    );
  }
}
