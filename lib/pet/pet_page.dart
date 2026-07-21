import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/pet_provider.dart';
import 'pet_state.dart';
import 'widgets/pet_avatar_animated.dart';
import 'chat/pet_chat_page.dart';

/// 宠物互动主页 —— 旅行青蛙风格
/// 强调"陪伴"与"放置"，宠物在清新自然的场景中生活。
class PetPage extends ConsumerStatefulWidget {
  const PetPage({super.key});

  @override
  ConsumerState<PetPage> createState() => _PetPageState();
}

class _PetPageState extends ConsumerState<PetPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cloudController;

  @override
  void initState() {
    super.initState();
    _cloudController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    Future.microtask(() async {
      final c = ref.read(petProvider.notifier);
      await c.loadFromDb();
      c.simulateOfflineDecay(2);
    });
  }

  @override
  void dispose() {
    _cloudController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pet = ref.watch(petProvider.select((s) => s.pet));
    final event = ref.watch(petProvider.select((s) => s.currentEvent));

    return Scaffold(
      backgroundColor: const Color(0xFFE8F5E9),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景天空与草地
          _buildNatureBackground(),

          // 远山
          Positioned(
            bottom: MediaQuery.of(context).size.height * 0.22,
            left: 0,
            right: 0,
            child: _buildMountains(),
          ),

          // 草地
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).size.height * 0.28,
            child: _buildGrassField(),
          ),

          // 动态云朵
          AnimatedBuilder(
            animation: _cloudController,
            builder: (context, child) {
              return Positioned(
                top: 80,
                left: _cloudPosition(_cloudController.value, 0),
                child: _buildCloud(size: 80),
              );
            },
          ),
          AnimatedBuilder(
            animation: _cloudController,
            builder: (context, child) {
              return Positioned(
                top: 140,
                left: _cloudPosition(_cloudController.value, 180),
                child: _buildCloud(size: 60),
              );
            },
          ),

          // 太阳
          Positioned(top: 70, right: 40, child: _buildSun()),

          // 顶部标题与记录入口（明确固定在顶部）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 返回按钮
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(200),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Color(0xFF5D4037),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    // 标题
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(200),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.eco,
                            size: 16,
                            color: _moodColor(pet.mood),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '我的小宠 · Lv.${pet.level}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF5D4037),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 右侧操作按钮组
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 状态面板入口
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(200),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(
                              Icons.bar_chart,
                              color: Color(0xFF5D4037),
                            ),
                            onPressed: () => _showPetStats(pet),
                            tooltip: '状态',
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 成长记录
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(200),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(
                              Icons.photo_album_outlined,
                              color: Color(0xFF5D4037),
                            ),
                            onPressed: () => _showGrowthRecords(context),
                            tooltip: '成长记录',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 宠物主体
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).size.height * 0.28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 心情气泡
                _buildMoodBubble(pet),
                const SizedBox(height: 12),
                // 宠物头像（点击看状态）
                GestureDetector(
                  onTap: () => _showPetStats(pet),
                  child: AnimatedPetAvatar(
                    mood: pet.mood,
                    level: pet.level,
                    size: 140,
                  ),
                ),
                const SizedBox(height: 16),
                // 快捷状态条
                _buildQuickStats(pet),
              ],
            ),
          ),

          // 底部工具栏
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: _buildBottomToolbar(pet, event),
          ),
        ],
      ),
    );
  }

  // ========== 背景 ==========

  Widget _buildNatureBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFFFFF8E1), // 晨曦黄
            Color(0xFFE1F5FE), // 天空蓝
            Color(0xFFC8E6C9), // 草绿
          ],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
    );
  }

  Widget _buildMountains() {
    return SizedBox(
      height: 120,
      child: Stack(
        children: [
          // 远山
          Positioned(
            bottom: 0,
            left: -20,
            right: -20,
            child: ClipPath(
              clipper: _MountainClipper(
                peaks: const [0.2, 0.55, 0.85],
                heights: const [0.7, 0.9, 0.6],
              ),
              child: Container(
                height: 100,
                color: const Color(0xFFB2DFDB).withAlpha(160),
              ),
            ),
          ),
          // 近山
          Positioned(
            bottom: 0,
            left: -40,
            right: -40,
            child: ClipPath(
              clipper: _MountainClipper(
                peaks: const [0.15, 0.45, 0.75],
                heights: const [0.55, 0.75, 0.5],
              ),
              child: Container(
                height: 80,
                color: const Color(0xFF80CBC4).withAlpha(140),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrassField() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFAED581), Color(0xFF7CB342)],
        ),
      ),
      child: CustomPaint(size: Size.infinite, painter: _GrassPainter()),
    );
  }

  Widget _buildSun() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFFFE082),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFE082).withAlpha(100),
            blurRadius: 24,
            spreadRadius: 8,
          ),
        ],
      ),
    );
  }

  Widget _buildCloud({required double size}) {
    return Container(
      width: size,
      height: size * 0.5,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(200),
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
    );
  }

  double _cloudPosition(double progress, double offset) {
    final screenWidth = MediaQuery.of(context).size.width;
    final start = -120.0 + offset;
    return start + progress * (screenWidth + 240);
  }

  // ========== 宠物与状态 ==========

  Widget _buildMoodBubble(PetData pet) {
    final text = _moodText(pet.mood);
    final color = _moodColor(pet.mood);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(230),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ========== 宠物状态 ==========

  Widget _buildQuickStats(PetData pet) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(220),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStatItem(
            Icons.favorite,
            pet.moodValue,
            100,
            const Color(0xFFEC407A),
          ),
          const SizedBox(width: 20),
          _buildStatItem(
            Icons.directions_run,
            pet.activity,
            100,
            const Color(0xFF66BB6A),
          ),
          const SizedBox(width: 20),
          _buildStatItem(
            Icons.star,
            pet.intimacy,
            100,
            const Color(0xFFFFA726),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, int value, int max, Color color) {
    final progress = value / max;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 4,
                backgroundColor: color.withAlpha(30),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            Icon(icon, size: 16, color: color),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  // ========== 底部工具栏 ==========

  Widget _buildBottomToolbar(PetData pet, AiEvent? event) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 事件提示条（当有事件时显示）
        if (event != null) _buildEventHint(event),
        const SizedBox(height: 12),
        // 工具按钮
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(230),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(10),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              _buildToolButton(
                icon: Icons.restaurant,
                label: '喂食',
                color: const Color(0xFFFFA726),
                onTap: () {
                  final c = ref.read(petProvider.notifier);
                  c.addGrowth(8);
                  c.updateMood(3);
                  c.addRecord('给小宠喂食', 8);
                  _showSnackBar('小宠吃得津津有味！');
                },
              ),
              _buildToolButton(
                icon: Icons.pets,
                label: '抚摸',
                color: const Color(0xFFEC407A),
                onTap: () {
                  final c = ref.read(petProvider.notifier);
                  c.updateMood(5);
                  c.updateIntimacy(3);
                  c.addRecord('抚摸小宠', 5);
                  _showSnackBar('小宠开心地蹭了蹭你的手 ♥');
                },
              ),
              _buildToolButton(
                icon: Icons.directions_walk,
                label: '散步',
                color: const Color(0xFF66BB6A),
                onTap: () {
                  final c = ref.read(petProvider.notifier);
                  c.updateActivity(15);
                  c.updateMood(5);
                  c.addRecord('带小宠散步', 5);
                  _showSnackBar('小宠活力满满！');
                },
              ),
              _buildToolButton(
                icon: Icons.chat_bubble_outline,
                label: '聊天',
                color: const Color(0xFF42A5F5),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PetChatPage()),
                  );
                },
              ),
              _buildToolButton(
                icon: Icons.explore,
                label: event != null ? '事件' : '探索',
                color: event != null
                    ? _categoryColor(event.category)
                    : const Color(0xFFAB47BC),
                onTap: () {
                  if (event != null) {
                    _showEventDialog(event);
                  } else {
                    ref.read(petProvider.notifier).generateRandomEvent();
                    _showSnackBar('小宠发现了一些新鲜事！');
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                shape: BoxShape.circle,
                border: Border.all(color: color.withAlpha(60)),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF5D4037),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventHint(AiEvent event) {
    return GestureDetector(
      onTap: () => _showEventDialog(event),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(240),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(8),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: _categoryColor(event.category),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF5D4037),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    event.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Color(0xFF9E9E9E)),
          ],
        ),
      ),
    );
  }

  // ========== 交互与弹窗 ==========

  void _showEventDialog(AiEvent event) {
    final controller = ref.read(petProvider.notifier);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _categoryColor(event.category).withAlpha(25),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        event.category.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: _categoryColor(event.category),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  event.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF5D4037),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  event.description,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: event.presetOptions.map((option) {
                    return ActionChip(
                      backgroundColor: const Color(0xFFE8F5E9),
                      side: BorderSide.none,
                      label: Text(option),
                      labelStyle: const TextStyle(
                        color: Color(0xFF5D4037),
                        fontWeight: FontWeight.w500,
                      ),
                      onPressed: () {
                        controller.respondToEvent(option);
                        Navigator.pop(ctx);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF5D4037).withAlpha(230),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.only(bottom: 120, left: 20, right: 20),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _showPetStats(PetData pet) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          maxChildSize: 0.7,
          minChildSize: 0.3,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF1F8E9),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                _moodColor(pet.mood).withAlpha(180),
                                _moodColor(pet.mood),
                              ],
                            ),
                          ),
                          child: const Icon(Icons.pets, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${pet.name}  Lv.${pet.level}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF5D4037),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '心情: ${pet.mood.label}',
                              style: TextStyle(
                                fontSize: 13,
                                color: _moodColor(pet.mood),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildDetailProgressBar(
                      label: '成长值',
                      current: pet.growthCurrent,
                      max: pet.growthMax,
                      color: const Color(0xFF6C63FF),
                    ),
                    const SizedBox(height: 16),
                    _buildDetailProgressBar(
                      label: '心情值',
                      current: pet.moodValue,
                      max: 100,
                      color: const Color(0xFFEC407A),
                    ),
                    const SizedBox(height: 16),
                    _buildDetailProgressBar(
                      label: '活跃度',
                      current: pet.activity,
                      max: 100,
                      color: const Color(0xFF66BB6A),
                    ),
                    const SizedBox(height: 16),
                    _buildDetailProgressBar(
                      label: '亲密度',
                      current: pet.intimacy,
                      max: 100,
                      color: const Color(0xFFFFA726),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailProgressBar({
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
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF5D4037),
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              '$current / $max',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: color.withAlpha(25),
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 12,
          ),
        ),
      ],
    );
  }

  void _showGrowthRecords(BuildContext context) {
    final records = ref.read(petProvider.notifier).records;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.85,
          minChildSize: 0.3,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF1F8E9),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(
                          Icons.photo_album_outlined,
                          color: Color(0xFF5D4037),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '成长记录',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: records.isEmpty
                          ? Center(
                              child: Text(
                                '暂无记录，开始和小宠互动吧！',
                                style: TextStyle(color: Colors.grey[500]),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              itemCount: records.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final r = records[index];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    r.valueChange >= 0
                                        ? Icons.trending_up
                                        : Icons.trending_down,
                                    color: r.valueChange >= 0
                                        ? Colors.green
                                        : Colors.red,
                                    size: 20,
                                  ),
                                  title: Text(
                                    r.content,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  trailing: r.valueChange != 0
                                      ? Text(
                                          '${r.valueChange >= 0 ? '+' : ''}${r.valueChange}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: r.valueChange >= 0
                                                ? Colors.green
                                                : Colors.red,
                                          ),
                                        )
                                      : null,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ========== 辅助方法 ==========

  String _moodText(PetMood mood) {
    switch (mood) {
      case PetMood.happy:
        return '小宠很开心～';
      case PetMood.normal:
        return '小宠很悠闲';
      case PetMood.tired:
        return '小宠有点累';
      case PetMood.low:
        return '小宠情绪低落';
    }
  }

  Color _moodColor(PetMood mood) {
    switch (mood) {
      case PetMood.happy:
        return const Color(0xFF66BB6A);
      case PetMood.normal:
        return const Color(0xFF42A5F5);
      case PetMood.tired:
        return const Color(0xFFFFA726);
      case PetMood.low:
        return const Color(0xFF78909C);
    }
  }

  Color _categoryColor(EventCategory category) {
    switch (category) {
      case EventCategory.daily:
        return const Color(0xFF42A5F5);
      case EventCategory.fun:
        return const Color(0xFFFFA726);
      case EventCategory.challenge:
        return const Color(0xFFEF5350);
      case EventCategory.healing:
        return const Color(0xFF66BB6A);
    }
  }
}

// ========== 自定义绘制 ==========

/// 远山裁剪路径
class _MountainClipper extends CustomClipper<Path> {
  final List<double> peaks;
  final List<double> heights;

  const _MountainClipper({required this.peaks, required this.heights});

  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, size.height);

    for (int i = 0; i < peaks.length; i++) {
      final x = size.width * peaks[i];
      final y = size.height * (1 - heights[i]);
      path.lineTo(x, y);
    }

    path.lineTo(size.width, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// 草地纹理绘制
class _GrassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF9CCC65).withAlpha(80)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final random = List<double>.generate(30, (i) => (i * 37) % size.width);
    for (final x in random) {
      final y = (x * 13) % (size.height * 0.6) + size.height * 0.3;
      final h = 6 + (x % 8);
      canvas.drawLine(Offset(x, y + h), Offset(x + (x % 3 - 1) * 2, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
