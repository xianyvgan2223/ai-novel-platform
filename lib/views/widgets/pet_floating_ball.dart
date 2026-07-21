// lib/views/widgets/pet_floating_ball.dart
// 可拖拽悬浮宠物球 — 宠物聊天页面顶层常驻，支持边缘吸附和互动动作菜单

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../pet/providers/pet_provider.dart';
import '../../pet/pet_state.dart';
import '../../pet/chat/pet_chat_controller.dart';

class PetFloatingBall extends ConsumerStatefulWidget {
  /// 聊天实时表情（由 PetChatController 提供）
  final ChatExpression chatExpression;

  const PetFloatingBall({
    super.key,
    this.chatExpression = ChatExpression.neutral,
  });

  @override
  ConsumerState<PetFloatingBall> createState() => _PetFloatingBallState();
}

class _PetFloatingBallState extends ConsumerState<PetFloatingBall>
    with SingleTickerProviderStateMixin {
  // 悬浮球位置（相对屏幕右下角的偏移）
  double _dx = 0;
  double _dy = 0;
  bool _isDragging = false;

  // 球体大小
  static const double _ballSize = 48;

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// 根据聊天表情获取图标
  IconData _getExpressionIcon(ChatExpression exp) {
    switch (exp) {
      case ChatExpression.excited:
        return Icons.auto_awesome;
      case ChatExpression.happy:
        return Icons.emoji_emotions;
      case ChatExpression.neutral:
        return Icons.sentiment_satisfied;
      case ChatExpression.sad:
        return Icons.sentiment_dissatisfied;
      case ChatExpression.thinking:
        return Icons.psychology;
    }
  }

  /// 根据聊天表情获取背景颜色
  Color _getExpressionColor(ChatExpression exp) {
    switch (exp) {
      case ChatExpression.excited:
        return const Color(0xFFFF6B9D); // 粉色 — 超开心
      case ChatExpression.happy:
        return const Color(0xFF6C63FF); // 紫色 — 开心
      case ChatExpression.neutral:
        return const Color(0xFF4CAF50); // 绿色 — 普通
      case ChatExpression.sad:
        return const Color(0xFF78909C); // 灰蓝 — 低落
      case ChatExpression.thinking:
        return const Color(0xFFFF9800); // 橙色 — 思考
    }
  }

  /// 根据心情值获取背景颜色（仅用于动作菜单面板展示）
  Color _getMoodBgColor(int moodValue) {
    if (moodValue >= 70) return const Color(0xFF6C63FF);
    if (moodValue >= 50) return const Color(0xFF4CAF50);
    if (moodValue >= 25) return const Color(0xFFFF9800);
    return const Color(0xFF78909C);
  }

  /// 显示互动动作菜单
  void _showActionMenu(BuildContext context) {
    final pet = ref.read(petProvider.notifier);
    final petData = ref.read(petProvider).pet;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 拖拽指示条
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDDDDD),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 宠物状态摘要
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _getMoodBgColor(petData.moodValue),
                      ),
                      child: Icon(
                        _getExpressionIcon(ChatExpression.neutral),
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${petData.name}  Lv.${petData.level}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF333333),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '心情: ${petData.mood.label} · 亲密度: ${petData.intimacy}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 动作按钮网格
                Row(
                  children: [
                    Expanded(
                      child: _buildActionButton(
                        ctx,
                        icon: Icons.face,
                        label: '摸摸头',
                        color: const Color(0xFF6C63FF),
                        onTap: () {
                          pet.updateMood(5);
                          pet.updateIntimacy(3);
                          pet.addRecord('摸了摸小宠的头 ♥', 0);
                          Navigator.pop(ctx);
                          _showFeedback('小宠开心地蹭了蹭你的手 ♥');
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildActionButton(
                        ctx,
                        icon: Icons.restaurant,
                        label: '喂食',
                        color: const Color(0xFFFF9800),
                        onTap: () {
                          pet.addGrowth(10);
                          pet.updateMood(3);
                          pet.addRecord('给小宠喂了吃的', 10);
                          Navigator.pop(ctx);
                          _showFeedback('小宠吃得可开心了！🍖');
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildActionButton(
                        ctx,
                        icon: Icons.sports_esports,
                        label: '玩耍',
                        color: const Color(0xFF4CAF50),
                        onTap: () {
                          pet.updateActivity(8);
                          pet.updateMood(5);
                          pet.addRecord('和小宠一起玩耍', 0);
                          Navigator.pop(ctx);
                          _showFeedback('小宠玩得很尽兴！🎾');
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 查看状态按钮
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showPetStats(petData);
                    },
                    icon: const Icon(Icons.bar_chart, size: 16),
                    label: const Text('查看详细状态'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF666666),
                      side: const BorderSide(color: Color(0xFFDDDDDD)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 动作按钮
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(40)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 简短反馈提示
  void _showFeedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.only(bottom: 80, left: 20, right: 20),
      ),
    );
  }

  /// 查看详细状态
  void _showPetStats(PetData pet) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            Icon(Icons.pets, size: 20, color: const Color(0xFF6C63FF)),
            const SizedBox(width: 8),
            Text(
              '${pet.name} 的状态',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatRow('等级', 'Lv.${pet.level}', const Color(0xFF6C63FF)),
            const Divider(height: 20),
            _buildStatRow(
              '成长值',
              '${pet.growthCurrent}/${pet.growthMax}',
              const Color(0xFF4CAF50),
            ),
            const Divider(height: 20),
            _buildStatRow(
              '心情值',
              '${pet.moodValue}/100',
              const Color(0xFFFF9800),
            ),
            const Divider(height: 20),
            _buildStatRow(
              '活跃度',
              '${pet.activity}/100',
              const Color(0xFF2196F3),
            ),
            const Divider(height: 20),
            _buildStatRow(
              '亲密度',
              '${pet.intimacy}/100',
              const Color(0xFFE91E63),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pet = ref.watch(petProvider.select((s) => s.pet));
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // 默认初始位置：右下角，在输入框上方
    if (_dx == 0 && _dy == 0) {
      _dx = screenWidth - _ballSize - 16;
      _dy = screenHeight - _ballSize - 80; // 在输入框上方
    }

    final expressionColor = _getExpressionColor(widget.chatExpression);

    return Positioned(
      left: _dx,
      top: _dy,
      child: GestureDetector(
        onPanStart: (_) {
          setState(() => _isDragging = true);
        },
        onPanUpdate: (details) {
          setState(() {
            _dx = (_dx + details.delta.dx).clamp(0, screenWidth - _ballSize);
            _dy = (_dy + details.delta.dy).clamp(
              0,
              screenHeight - _ballSize - kToolbarHeight,
            );
          });
        },
        onPanEnd: (_) {
          setState(() => _isDragging = false);
          // 边缘吸附：吸附到最近的水平边缘
          _snapToEdge(screenWidth);
        },
        onTap: () => _showActionMenu(context),
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final scale = _isDragging
                ? 1.15
                : 1.0 + _pulseController.value * 0.08;
            return Transform.scale(
              scale: scale,
              child: Container(
                width: _ballSize,
                height: _ballSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [expressionColor.withAlpha(220), expressionColor],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: expressionColor.withAlpha(80),
                      blurRadius: _isDragging ? 12 : 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 聊天表情图标
                    Icon(
                      _getExpressionIcon(widget.chatExpression),
                      size: 22,
                      color: Colors.white,
                    ),
                    // 等级小标签
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                        child: Text(
                          '${pet.level}',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: expressionColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 边缘吸附动画
  void _snapToEdge(double screenWidth) {
    final half = screenWidth / 2;
    final targetX = _dx + _ballSize / 2 < half
        ? 4.0
        : screenWidth - _ballSize - 4.0;

    setState(() {
      _dx = targetX;
    });
  }
}
