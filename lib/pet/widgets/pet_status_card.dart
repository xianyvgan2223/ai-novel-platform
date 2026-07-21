import 'package:flutter/material.dart';
import '../pet_state.dart';
import 'pet_avatar_animated.dart';

/// 宠物基础状态展示卡片（纯组件，不 watch provider）
class PetStatusCard extends StatelessWidget {
  final PetData pet;

  const PetStatusCard({super.key, required this.pet});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 宠物形象区域
            RepaintBoundary(child: _buildPetAvatar(pet, theme)),
            const SizedBox(height: 16),
            // 宠物名称和等级
            Text(
              pet.name,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            _buildMoodBadge(pet),
            const SizedBox(height: 20),
            // 成长值
            _buildProgressBar(
              label: '成长值',
              current: pet.growthCurrent,
              max: pet.growthMax,
              color: _kColorGrowth,
            ),
            const SizedBox(height: 12),
            // 心情值
            _buildProgressBar(
              label: '心情值',
              current: pet.moodValue,
              max: 100,
              color: _kMoodColor(pet.mood),
            ),
            const SizedBox(height: 12),
            // 属性行
            Row(
              children: [
                Expanded(
                  child: _buildAttributeChip(
                    icon: Icons.directions_run,
                    label: '活跃度',
                    value: pet.activity,
                    color: _kColorActivity,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildAttributeChip(
                    icon: Icons.favorite,
                    label: '亲密度',
                    value: pet.intimacy,
                    color: _kColorIntimacy,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------- 子组件 -------

  Widget _buildPetAvatar(PetData pet, ThemeData theme) {
    return AnimatedPetAvatar(mood: pet.mood, level: pet.level, size: 100);
  }

  Widget _buildMoodBadge(PetData pet) {
    final color = _kMoodColor(pet.mood);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(
            'Lv.${pet.level}  ·  ${pet.mood.label}',
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar({
    required String label,
    required int current,
    required int max,
    required Color color,
  }) {
    final progress = max > 0 ? (current / max).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text(
              '$current / $max',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: color.withAlpha(25),
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildAttributeChip({
    required IconData icon,
    required String label,
    required int value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------- 预定义常量色 -------

  static const _kColorGrowth = Color(0xFF6C63FF);
  static const _kColorActivity = Color(0xFF00BFA5);
  static const _kColorIntimacy = Color(0xFFFF6584);
  static const _kColorHappy = Color(0xFF4CAF50);
  static const _kColorNormal = Color(0xFF2196F3);
  static const _kColorTired = Color(0xFFFF9800);
  static const _kColorLow = Color(0xFF9E9E9E);

  static Color _kMoodColor(PetMood mood) {
    switch (mood) {
      case PetMood.happy:
        return _kColorHappy;
      case PetMood.normal:
        return _kColorNormal;
      case PetMood.tired:
        return _kColorTired;
      case PetMood.low:
        return _kColorLow;
    }
  }
}
