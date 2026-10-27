// lib/game/game_hub_page.dart
// 游戏中心 — 多游戏切换首页

import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'novel_game_page.dart';
import 'character_chat/view/character_select_page.dart';
import 'trpg/view/page/trpg_home_page.dart';

class GameHubPage extends StatelessWidget {
  const GameHubPage({super.key});

  static const _games = <_GameEntry>[
    _GameEntry(
      id: 'novel',
      name: '小说创作',
      description: '创建角色与副本，展开AI驱动的互动小说冒险',
      icon: Icons.auto_stories,
      color: Color(0xFF4A90D9),
    ),
    _GameEntry(
      id: 'character_chat',
      name: '角色扮演',
      description: '选择角色进行沉浸式AI对话，仿SillyTavern风格的角色扮演体验',
      icon: Icons.people,
      color: Color(0xFFE74C3C),
    ),
    _GameEntry(
      id: 'trpg',
      name: '跑团模拟器',
      description: 'AI当主持人，掷骰判定、回合制冒险的DnD风格TRPG',
      icon: Icons.casino,
      color: Color(0xFF8E44AD),
    ),
  ];

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
          '游戏中心',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: p.border),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '选择游戏',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: p.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.85,
                ),
                itemCount: _games.length,
                itemBuilder: (context, index) {
                  return _GameCard(
                    game: _games[index],
                    onTap: () => _onGameTap(context, _games[index].id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onGameTap(BuildContext context, String gameId) {
    switch (gameId) {
      case 'novel':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const NovelGamePage()));
      case 'character_chat':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const CharacterSelectPage()));
      case 'trpg':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const TrpgHomePage()));
    }
  }
}

class _GameEntry {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color color;

  const _GameEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
  });
}

class _GameCard extends StatelessWidget {
  final _GameEntry game;
  final VoidCallback onTap;

  const _GameCard({required this.game, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
                    color: p.shadow,
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: game.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(game.icon, size: 28, color: game.color),
            ),
            const SizedBox(height: 12),
            Text(
              game.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                game.description,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: p.textTertiary,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
