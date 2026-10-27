import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import 'package:deepseekapp/core/config/route_names.dart';
import 'package:deepseekapp/features/chat/presentation/settings_page.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/copy_entity.dart';
import 'package:deepseekapp/features/game/novel_game/controller/novel_game_controller.dart';
import 'package:deepseekapp/features/game/novel_game/view/widget/red_dot_badge_widget.dart';
import 'package:deepseekapp/features/game/novel_game/view/widget/character_card_widget.dart';
import 'package:deepseekapp/features/game/novel_game/view/widget/copy_card_widget.dart';
import 'package:deepseekapp/features/game/novel_game/view/widget/ai_loading_widget.dart';
import 'package:deepseekapp/features/game/novel_game/view/page/copy_edit_page.dart';

class NovelGameMainPage extends StatefulWidget {
  final NovelGameController controller;

  const NovelGameMainPage({super.key, required this.controller});

  @override
  State<NovelGameMainPage> createState() => _NovelGameMainPageState();
}

class _NovelGameMainPageState extends State<NovelGameMainPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _safeAsync(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('safeAsync error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _onGenerateCopy() {
    _safeAsync(() async {
      final ok = await widget.controller.showCreateCopyDialog(context);
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('创建副本失败或已取消')));
      }
    });
  }

  void _onGenerateCharacter() {
    _safeAsync(() async {
      final ok = await widget.controller.showCreateCharacterDialog(context);
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('创建人物失败或已取消')));
      }
    });
  }

  void _onCopyStart(CopyEntity copy) {
    _safeAsync(() => widget.controller.startCopy(copy));
  }

  void _onCopySetting(CopyEntity copy) async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => CopyEditPage(copy: copy)));
    if (result == true) {
      await _safeAsync(() async {
        await widget.controller.loadData();
        if (mounted) setState(() {});
      });
    }
  }

  void _onCharacterTap(int characterId) {
    widget.controller.navigateToCharacterEdit(characterId);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final characters = widget.controller.characters;
    final copies = widget.controller.copies;
    final runningCopy = widget.controller.runningCopy;
    final unreadCount = widget.controller.unreadRecordCount;

    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(unreadCount),
            _buildDevNotice(),
            Expanded(flex: 3, child: _buildCharacterList(characters)),
            Divider(height: 1, color: p.border),
            Expanded(flex: 7, child: _buildCopyList(copies, runningCopy)),
            if (runningCopy != null)
              SizedBox(
                height: 28,
                child: AiLoadingWidget(
                  message: '副本「${runningCopy.copyName}」运行中...',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(int unreadCount) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      color: p.surface,
      child: Row(
        children: [
          Text(
            '小说创作',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: p.textPrimary,
            ),
          ),
          const Spacer(),
          _ActionButton(label: '副本', onTap: _onGenerateCopy),
          const SizedBox(width: 4),
          _ActionButton(label: '人物', onTap: _onGenerateCharacter),
          const SizedBox(width: 8),
          RedDotBadgeWidget(
            count: unreadCount,
            child: _ActionButton(
              label: '经历',
              onTap: () => widget.controller.navigateToCopyHistory(context),
            ),
          ),
          const SizedBox(width: 4),
          _ActionButton(
            label: '设置',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                // 命名路由：全局悬浮球据此在设置页隐藏（该页右上角全是控件）。
                settings: const RouteSettings(name: kSettingsRouteName),
                builder: (_) => const SettingsPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevNotice() {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: p.isDark
          ? p.warning.withValues(alpha: 0.14)
          : const Color(0xFFFFF8E1),
      child: Row(
        children: [
          Icon(
            Icons.construction,
            size: 14,
            color: p.isDark ? p.warning : const Color(0xFFE6A817),
          ),
          const SizedBox(width: 6),
          Text(
            '功能开发中，部分功能可能不稳定',
            style: TextStyle(
              fontSize: 11,
              color: p.isDark ? p.warning : const Color(0xFFB8860B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterList(List<CharacterEntity> characters) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 3, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text(
              '人物卡',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: characters.isEmpty
                ? Center(
                    child: Text(
                      '暂无人物',
                      style: TextStyle(color: p.textTertiary, fontSize: 10),
                    ),
                  )
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: characters.map((character) {
                        return SizedBox(
                          width: 100,
                          child: CharacterCardWidget(
                            character: character,
                            onTap: () => widget.controller
                                .navigateToCharacterEdit(character.id ?? 0),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyList(List<CopyEntity> copies, CopyEntity? runningCopy) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text(
              '副本列表',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: copies.isEmpty
                ? Center(
                    child: Text(
                      '暂无副本',
                      style: TextStyle(color: p.textTertiary, fontSize: 10),
                    ),
                  )
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: copies.map((copy) {
                        final copyCharacters = widget.controller
                            .getCharactersForCopy(copy.id ?? 0);
                        return SizedBox(
                          width: 160,
                          child: CopyCardWidget(
                            copy: copy,
                            characters: copyCharacters,
                            onStart: () => _onCopyStart(copy),
                            onSetting: () => _onCopySetting(copy),
                            onCharacterTap: _onCharacterTap,
                            onCharacterDropped: (charId) {
                              widget.controller.addCharacterToCopy(
                                copy.id ?? 0,
                                charId,
                              );
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ActionButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: p.accent,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(color: p.onAccent, fontSize: 10),
        ),
      ),
    );
  }
}
