import 'package:flutter/material.dart';
import '../pet_state.dart';

/// 带动画的宠物头像组件
/// 使用 Material Icons + 浮动/呼吸动画
class AnimatedPetAvatar extends StatefulWidget {
  final PetMood mood;
  final int level;
  final double size;

  const AnimatedPetAvatar({
    super.key,
    required this.mood,
    this.level = 1,
    this.size = 100,
  });

  @override
  State<AnimatedPetAvatar> createState() => _AnimatedPetAvatarState();
}

class _AnimatedPetAvatarState extends State<AnimatedPetAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _floatAnimation;
  late Animation<double> _breatheAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _floatAnimation = Tween<double>(begin: -5, end: 5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );

    _breatheAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        return Transform.translate(
          offset: Offset(0, _floatAnimation.value),
          child: Transform.scale(scale: _breatheAnimation.value, child: child),
        );
      },
      child: _buildAvatar(),
    );
  }

  Widget _buildAvatar() {
    final color = _kMoodColor(widget.mood);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color.withAlpha(180), color.withAlpha(60)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [],
      ),
      child: Icon(
        _kMoodIcon(widget.mood),
        size: widget.size * 0.55,
        color: Colors.white,
      ),
    );
  }

  // ------- 预定义资源 -------

  static Color _kMoodColor(PetMood m) {
    switch (m) {
      case PetMood.happy:
        return Color(0xFF4CAF50);
      case PetMood.normal:
        return Color(0xFF2196F3);
      case PetMood.tired:
        return Color(0xFFFF9800);
      case PetMood.low:
        return Color(0xFF9E9E9E);
    }
  }

  static IconData _kMoodIcon(PetMood m) {
    switch (m) {
      case PetMood.happy:
        return Icons.pets;
      case PetMood.normal:
        return Icons.cruelty_free;
      case PetMood.tired:
        return Icons.bedtime;
      case PetMood.low:
        return Icons.sentiment_dissatisfied;
    }
  }
}
