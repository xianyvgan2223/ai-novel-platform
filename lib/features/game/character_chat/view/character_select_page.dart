// lib/game/character_chat/view/character_select_page.dart
// 角色选择页 — 展示所有可对话角色和历史会话

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../model/character_model.dart';
import '../controller/chat_controller.dart';
import '../data/default_characters.dart';
import '../data/chat_db_service.dart';
import 'chat_room_page.dart';

class CharacterSelectPage extends StatefulWidget {
  const CharacterSelectPage({super.key});

  @override
  State<CharacterSelectPage> createState() => _CharacterSelectPageState();
}

class _CharacterSelectPageState extends State<CharacterSelectPage> {
  List<CharacterChatSession> _sessions = [];
  bool _loadingSessions = true;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    try {
      final sessions = await CharacterChatDbService.getAllSessions();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _loadingSessions = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSessions = false);
    }
  }

  List<CharacterModel> get _filteredCharacters {
    if (_searchQuery.isEmpty) return defaultCharacters;
    return defaultCharacters.where((c) {
      if (c.name.toLowerCase().contains(_searchQuery)) return true;
      for (final tag in c.tags) {
        if (tag.toLowerCase().contains(_searchQuery)) return true;
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        toolbarHeight: 44,
        backgroundColor: p.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '角色扮演',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ── 搜索框 ──
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索角色名或标签...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: p.textTertiary,
                ),
                border: InputBorder.none,
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: p.textTertiary,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                        },
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: p.textTertiary,
                        ),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
              style: TextStyle(fontSize: 13, color: p.textPrimary),
            ),
          ),
          const SizedBox(height: 12),

          // ── 历史会话 ──
          if (_sessions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                '继续对话',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
            ),
            ..._sessions.map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _HistoryCard(
                  session: s,
                  onTap: () => _continueChat(s),
                  onDelete: () => _deleteSession(s.id!),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1, color: p.border),
            ),
          ] else if (!_loadingSessions)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: SizedBox.shrink(),
            ),
          // ── 新建对话 ──
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '选择角色开始新对话',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ),
          if (_filteredCharacters.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  '没有匹配的角色',
                  style: TextStyle(fontSize: 13, color: p.textTertiary),
                ),
              ),
            )
          else
            ..._filteredCharacters.map(
              (c) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CharacterCard(
                  character: c,
                  onTap: () => _openChat(c),
                  searchQuery: _searchQuery,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openChat(CharacterModel character) {
    final controller = CharacterChatController();
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                ChatRoomPage(controller: controller, character: character),
          ),
        )
        .then((_) => _loadSessions());
  }

  void _continueChat(CharacterChatSession session) {
    final controller = CharacterChatController();
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ChatRoomPage.fromSession(
              controller: controller,
              sessionId: session.id!,
            ),
          ),
        )
        .then((_) => _loadSessions());
  }

  Future<void> _deleteSession(int id) async {
    final p = context.palette;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surfaceElevated,
        title: const Text('删除会话', style: TextStyle(fontSize: 14)),
        content: const Text('确定删除该对话记录吗？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '删除',
              style: TextStyle(fontSize: 13, color: p.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await CharacterChatDbService.deleteSession(id);
      await _loadSessions();
    }
  }
}

/// 历史会话卡片
class _HistoryCard extends StatelessWidget {
  final CharacterChatSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HistoryCard({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colors = {
      '塞拉菲娜': const Color(0xFFE74C3C),
      '罗兰': const Color(0xFF6B4226),
      '小咪': const Color(0xFF2ECC71),
      '夏洛特': const Color(0xFF8E44AD),
      '佐克斯': const Color(0xFF3498DB),
    };
    final color = colors[session.characterName] ?? const Color(0xFF4A90D9);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Text(
                session.characterName.characters.first,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.characterName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '上次对话: ${_formatTime(session.updatedAt)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: onDelete,
              child: Icon(
                Icons.close,
                size: 16,
                color: p.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}

/// 角色卡片
class _CharacterCard extends StatelessWidget {
  final CharacterModel character;
  final VoidCallback onTap;
  final String searchQuery;

  const _CharacterCard({
    required this.character,
    required this.onTap,
    this.searchQuery = '',
  });

  /// 构建带搜索高亮的名字文本
  Widget _buildHighlightedName(AppPalette p) {
    if (searchQuery.isEmpty) {
      return Text(
        character.name,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
      );
    }

    final name = character.name;
    final lowerName = name.toLowerCase();
    final query = searchQuery.toLowerCase();
    final spans = <InlineSpan>[];
    int start = 0;

    while (true) {
      final index = lowerName.indexOf(query, start);
      if (index == -1) {
        spans.add(TextSpan(text: name.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: name.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: name.substring(index, index + query.length),
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
      );
      start = index + query.length;
    }

    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        children: spans,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final themeColors = <String, Color>{
      '塞拉菲娜': const Color(0xFFE74C3C),
      '罗兰': const Color(0xFF6B4226),
      '小咪': const Color(0xFF2ECC71),
      '夏洛特': const Color(0xFF8E44AD),
      '佐克斯': const Color(0xFF3498DB),
    };
    final avatarColor = themeColors[character.name] ?? const Color(0xFF4A90D9);
    final tagColor = p.isDark
        ? Color.lerp(avatarColor, Colors.white, 0.35) ?? avatarColor
        : avatarColor;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(12),
          border: p.isDark ? Border.all(color: p.border) : null,
          boxShadow: p.isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: avatarColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(26),
              ),
              alignment: Alignment.center,
              child: Text(
                character.name.characters.first,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: avatarColor,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHighlightedName(p),
                  const SizedBox(height: 4),
                  Text(
                    character.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: p.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  if (character.tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: character.tags.map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: avatarColor.withValues(
                              alpha: p.isDark ? 0.18 : 0.1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 10,
                              color: tagColor.withValues(alpha: 0.8),
                              height: 1.3,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                Icons.chat_bubble_outline,
                size: 18,
                color: avatarColor.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
