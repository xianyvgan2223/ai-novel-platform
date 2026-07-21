// lib/pet/adventure/adventure_page.dart
// 冒险模式 — 宠物带血条进行文字冒险

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/pet_provider.dart';

/// 冒险事件类型
enum AdventureEventType {
  battle,    // 战斗
  treasure,  // 宝箱
  rest,      // 休息
  trap,      // 陷阱
  boss,      // BOSS战
}

/// 冒险事件
class AdventureEvent {
  final AdventureEventType type;
  final String title;
  final String description;
  final int hpChange;
  final int growthReward;
  final List<String> choices;

  const AdventureEvent({
    required this.type,
    required this.title,
    required this.description,
    this.hpChange = 0,
    this.growthReward = 0,
    this.choices = const ['继续冒险', '返回营地'],
  });
}

class AdventurePage extends ConsumerStatefulWidget {
  const AdventurePage({super.key});

  @override
  ConsumerState<AdventurePage> createState() => _AdventurePageState();
}

class _AdventurePageState extends ConsumerState<AdventurePage> {
  // 冒险状态
  int _hp = 100;
  int _maxHp = 100;
  int _floor = 1;
  bool _exploring = false;
  bool _ended = false;
  bool _won = false;
  final List<_AdventureLog> _logs = [];
  AdventureEvent? _currentEvent;
  int _selectedChoice = -1;
  int _totalGrowth = 0;

  final Random _random = Random();

  @override
  Widget build(BuildContext context) {
    final pet = ref.watch(petProvider.select((s) => s.pet));

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        appBar: AppBar(
          toolbarHeight: 48,
          backgroundColor: const Color(0xFF16213E),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Row(
            children: [
              const Icon(Icons.explore, size: 18, color: Color(0xFFE94560)),
              const SizedBox(width: 8),
              Text(
                '冒险模式 - 第 $_floor 层',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          actions: [
            if (_exploring)
              TextButton(
                onPressed: _ended ? null : _retreat,
                child: const Text(
                  '撤退',
                  style: TextStyle(fontSize: 12, color: Color(0xFFE94560)),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            // ── 血条区域 ──
            _buildHpBar(),
            // ── 宠物信息 ──
            _buildPetInfo(pet.name, pet.level),
            // ── 冒险日志/事件区域 ──
            Expanded(child: _buildContent()),
            // ── 操作按钮 ──
            _buildActions(pet.name),
          ],
        ),
      ),
    );
  }

  /// 血条
  Widget _buildHpBar() {
    final hpRatio = _hp / _maxHp;
    final hpColor = hpRatio > 0.5
        ? const Color(0xFF4CAF50)
        : hpRatio > 0.25
            ? const Color(0xFFFF9800)
            : const Color(0xFFE94560);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: const Color(0xFF16213E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'HP',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Text(
                '$_hp / $_maxHp',
                style: TextStyle(
                  fontSize: 12,
                  color: hpColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: hpRatio,
              backgroundColor: Colors.white.withAlpha(30),
              valueColor: AlwaysStoppedAnimation(hpColor),
              minHeight: 10,
            ),
          ),
        ],
      ),
    );
  }

  /// 宠物信息
  Widget _buildPetInfo(String name, int level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF16213E).withAlpha(200),
      child: Row(
        children: [
          const Icon(Icons.pets, size: 16, color: Color(0xFFE94560)),
          const SizedBox(width: 6),
          Text(
            '$name Lv.$level',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const Spacer(),
          if (_exploring)
            Text(
              '冒险获得: +$_totalGrowth 成长值',
              style: const TextStyle(fontSize: 11, color: Color(0xFFFFD700)),
            ),
        ],
      ),
    );
  }

  /// 内容区域（冒险日志 + 当前事件）
  Widget _buildContent() {
    if (!_exploring && !_ended) {
      // 未开始 — 冒险简介
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore, size: 64, color: Color(0xFFE94560)),
              const SizedBox(height: 16),
              const Text(
                '神秘冒险',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '带领你的宠物深入神秘领域探险！\n'
                '每层都会遇到不同的挑战，\n'
                '保持HP不为零，探索尽可能多的层数！\n\n'
                'HP归零则冒险结束。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white60,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_ended) {
      return _buildResult();
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        // 当前事件
        if (_currentEvent != null)
          _buildEventCard(_currentEvent!),
        // 历史日志
        ..._logs.reversed.take(10).map((log) => _buildLogItem(log)),
      ],
    );
  }

  /// 冒险结果
  Widget _buildResult() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _won ? Icons.emoji_events : Icons.sentiment_dissatisfied,
              size: 64,
              color: _won ? const Color(0xFFFFD700) : const Color(0xFFE94560),
            ),
            const SizedBox(height: 16),
            Text(
              _won ? '冒险成功！' : '冒险结束',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _won ? const Color(0xFFFFD700) : Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '到达了第 $_floor 层\n'
              '获得 $_totalGrowth 成长值',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.white60, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  /// 事件卡片
  Widget _buildEventCard(AdventureEvent event) {
    IconData icon;
    Color color;
    switch (event.type) {
      case AdventureEventType.battle:
        icon = Icons.local_fire_department;
        color = const Color(0xFFE94560);
      case AdventureEventType.treasure:
        icon = Icons.inventory_2;
        color = const Color(0xFFFFD700);
      case AdventureEventType.rest:
        icon = Icons.local_fire_department;
        color = const Color(0xFF4CAF50);
      case AdventureEventType.trap:
        icon = Icons.warning;
        color = const Color(0xFFFF5722);
      case AdventureEventType.boss:
        icon = Icons.dangerous;
        color = const Color(0xFFE91E63);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Text(
                event.title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.description,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white70,
              height: 1.5,
            ),
          ),
          if (event.hpChange != 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                event.hpChange > 0 ? 'HP +${event.hpChange}' : 'HP ${event.hpChange}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: event.hpChange > 0
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFE94560),
                ),
              ),
            ),
          if (event.growthReward > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '成长值 +${event.growthReward}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFFD700),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 历史日志
  Widget _buildLogItem(_AdventureLog log) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '▸ ',
            style: TextStyle(
              fontSize: 12,
              color: _getLogColor(log.type),
            ),
          ),
          Expanded(
            child: Text(
              log.text,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white54,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getLogColor(AdventureEventType type) {
    switch (type) {
      case AdventureEventType.battle:
      case AdventureEventType.trap:
        return const Color(0xFFE94560);
      case AdventureEventType.treasure:
        return const Color(0xFFFFD700);
      case AdventureEventType.rest:
        return const Color(0xFF4CAF50);
      case AdventureEventType.boss:
        return const Color(0xFFE91E63);
    }
  }

  /// 底部操作按钮
  Widget _buildActions(String petName) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF16213E),
        border: Border(top: BorderSide(color: Color(0xFF2A2A4A))),
      ),
      child: SafeArea(
        top: false,
        child: _buildActionRow(petName),
      ),
    );
  }

  Widget _buildActionRow(String petName) {
    // 未开始
    if (!_exploring && !_ended) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _startAdventure,
          icon: const Icon(Icons.explore, size: 18),
          label: const Text('开始冒险', style: TextStyle(fontSize: 15)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE94560),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
    }

    // 已结束
    if (_ended) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _ended = false;
                  _exploring = false;
                  _hp = 100;
                  _floor = 1;
                  _totalGrowth = 0;
                  _logs.clear();
                  _currentEvent = null;
                });
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('再来一次'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('返回'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE94560),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 探索中 — 显示当前事件的选择
    if (_currentEvent != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ..._currentEvent!.choices.asMap().entries.map((entry) {
            final idx = entry.key;
            final label = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _makeChoice(idx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: idx == 0
                        ? const Color(0xFFE94560)
                        : Colors.white.withAlpha(20),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                  ),
                  child: Text(label, style: const TextStyle(fontSize: 14)),
                ),
              ),
            );
          }),
        ],
      );
    }

    // 默认 — 下一层
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _nextFloor,
        icon: const Icon(Icons.navigate_next, size: 18),
        label: const Text('进入下一层', style: TextStyle(fontSize: 15)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE94560),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  // ========== 游戏逻辑 ==========

  /// 开始冒险
  void _startAdventure() {
    final pet = ref.read(petProvider).pet;
    setState(() {
      _exploring = true;
      _hp = 80 + pet.level * 5; // 等级影响HP
      _maxHp = _hp;
      _floor = 1;
      _totalGrowth = 0;
      _logs.clear();
      _addLog(AdventureEventType.rest, '冒险开始了！${pet.name}踏入了神秘领域...');
    });
    _nextFloor();
  }

  /// 进入下一层
  void _nextFloor() {
    if (_hp <= 0) {
      _endAdventure(false);
      return;
    }

    setState(() {
      _floor++;
      _addLog(AdventureEventType.rest, '→ 进入第 $_floor 层');
      _currentEvent = _generateEvent();
    });
  }

  /// 生成随机事件
  AdventureEvent _generateEvent() {
    final pet = ref.read(petProvider).pet;
    final r = _random.nextInt(100);

    // 每5层必出BOSS
    if (_floor % 5 == 0) {
      return _generateBossEvent(pet.level);
    }

    if (r < 35) {
      return _generateBattleEvent(pet.level);
    } else if (r < 55) {
      return _generateTreasureEvent(pet.level);
    } else if (r < 75) {
      return _generateRestEvent();
    } else {
      return _generateTrapEvent(pet.level);
    }
  }

  /// 战斗事件
  AdventureEvent _generateBattleEvent(int petLevel) {
    final monsterLevel = max(1, _floor ~/ 2 + 1);
    final damage = _random.nextInt(10) + 5 + monsterLevel * 2;
    final reward = _random.nextInt(8) + 3 + monsterLevel;

    final monsters = [
      '暗影狼', '岩石傀儡', '毒蘑菇精', '蝙蝠群',
      '幽灵蛇', '火焰精灵', '冰霜巨人', '荆棘怪',
    ];
    final monster = monsters[_random.nextInt(monsters.length)];

    return AdventureEvent(
      type: AdventureEventType.battle,
      title: '遭遇 $monster！',
      description: '一只凶猛的$monster挡在了前方！\n'
          'Lv.$monsterLevel 的怪物向你扑来。',
      hpChange: -damage,
      growthReward: reward,
      choices: ['勇敢战斗！', '小心防御'],
    );
  }

  /// 宝箱事件
  AdventureEvent _generateTreasureEvent(int petLevel) {
    final heal = _random.nextInt(15) + 5;
    final reward = _random.nextInt(10) + 5;

    final treasures = [
      '古老的宝箱', '发光的魔法石', '精灵的馈赠',
      '隐藏的宝藏', '神秘药水',
    ];
    final treasure = treasures[_random.nextInt(treasures.length)];

    return AdventureEvent(
      type: AdventureEventType.treasure,
      title: '发现 $treasure！',
      description: '你在角落里发现了一个$treasure，\n里面似乎有好东西！',
      hpChange: heal,
      growthReward: reward,
      choices: ['打开宝箱', '小心检查'],
    );
  }

  /// 休息事件
  AdventureEvent _generateRestEvent() {
    final heal = _random.nextInt(20) + 10;

    return AdventureEvent(
      type: AdventureEventType.rest,
      title: '发现休息点',
      description: '前方有一处安全的地方，\n可以稍作休息恢复体力。',
      hpChange: heal,
      choices: ['休息恢复', '继续前进'],
    );
  }

  /// 陷阱事件
  AdventureEvent _generateTrapEvent(int petLevel) {
    final damage = _random.nextInt(15) + 10 + petLevel;

    final traps = [
      '荆棘陷阱', '落石机关', '毒气区域',
      '流沙坑', '冰面裂缝',
    ];
    final trap = traps[_random.nextInt(traps.length)];

    return AdventureEvent(
      type: AdventureEventType.trap,
      title: '触发$trap！',
      description: '不小心踩到了$trap！\n需要想办法脱困。',
      hpChange: -damage,
      choices: ['强行突破', '小心绕行'],
    );
  }

  /// BOSS事件
  AdventureEvent _generateBossEvent(int petLevel) {
    final bossLevel = petLevel + _floor ~/ 3;
    final damage = _random.nextInt(20) + 15 + bossLevel * 2;
    final reward = _random.nextInt(30) + 20 + _floor * 3;

    final bosses = [
      '暗影龙王', '深渊魔王', '远古树精',
      '冰霜女皇', '熔岩巨兽',
    ];
    final boss = bosses[_random.nextInt(bosses.length)];

    return AdventureEvent(
      type: AdventureEventType.boss,
      title: '⚠ BOSS出现：$boss ⚠',
      description: '第 $_floor 层的守护者出现了！\n'
          'Lv.$bossLevel 的$boss散发着强大的气息...\n'
          '这将是一场艰苦的战斗！',
      hpChange: -damage,
      growthReward: reward,
      choices: ['拼死一战！', '寻找弱点'],
    );
  }

  /// 选择处理
  void _makeChoice(int index) {
    if (_currentEvent == null) return;

    final event = _currentEvent!;
    final pet = ref.read(petProvider.notifier);

    // 选择0 = 正面/激进选择，选择1 = 保守选择
    if (index == 0) {
      // 正面应对
      final actualDmg = event.hpChange < 0
          ? (event.hpChange * 0.7).round() // 勇敢应对减少30%伤害
          : event.hpChange;
      _hp = (_hp + actualDmg).clamp(0, _maxHp);
      if (event.growthReward > 0) {
        pet.addGrowth(event.growthReward);
        _totalGrowth += event.growthReward;
      }

      String logText;
      switch (event.type) {
        case AdventureEventType.battle:
          logText = '战斗胜利！获得 ${event.growthReward} 成长值';
          if (event.hpChange < 0) logText += '，损失 ${-actualDmg} HP';
          break;
        case AdventureEventType.treasure:
          logText = '获得宝物！HP +$actualDmg，成长值 +${event.growthReward}';
          break;
        case AdventureEventType.rest:
          logText = '好好休息了一番，HP +$actualDmg';
          break;
        case AdventureEventType.trap:
          logText = '强行突破！损失 ${-actualDmg} HP';
          break;
        case AdventureEventType.boss:
          logText = '击败BOSS！获得 ${event.growthReward} 成长值，损失 ${-actualDmg} HP';
          break;
      }
      _addLog(event.type, logText);
    } else {
      // 保守应对
      final actualDmg = event.hpChange;
      _hp = (_hp + actualDmg).clamp(0, _maxHp);

      String logText;
      switch (event.type) {
        case AdventureEventType.battle:
          logText = '谨慎战斗，损失 ${-actualDmg} HP，未获得成长值';
          break;
        case AdventureEventType.treasure:
          logText = '小心检查，HP +$actualDmg';
          break;
        case AdventureEventType.rest:
          logText = '稍作休息，HP +$actualDmg';
          break;
        case AdventureEventType.trap:
          logText = '小心绕行，损失 ${-actualDmg} HP';
          break;
        case AdventureEventType.boss:
          logText = '艰难战斗，损失 ${-actualDmg} HP，未获得成长值';
          break;
      }
      _addLog(event.type, logText);
    }

    setState(() {
      _currentEvent = null;
    });

    // 检查是否结束
    if (_hp <= 0) {
      _endAdventure(false);
    }
  }

  /// 撤退
  void _retreat() {
    final pet = ref.read(petProvider.notifier);
    if (_totalGrowth > 0) {
      pet.addGrowth(_totalGrowth);
    }
    _addLog(AdventureEventType.rest, '撤退了，保留了 $_totalGrowth 成长值');
    _endAdventure(true);
  }

  /// 结束冒险
  void _endAdventure(bool won) {
    // 结束时给予累计成长值
    final pet = ref.read(petProvider.notifier);
    if (_totalGrowth > 0) {
      pet.addGrowth(_totalGrowth);
    }

    setState(() {
      _ended = true;
      _won = won;
      _currentEvent = null;
    });
  }

  void _addLog(AdventureEventType type, String text) {
    _logs.add(_AdventureLog(type: type, text: text));
  }
}

/// 冒险日志条目
class _AdventureLog {
  final AdventureEventType type;
  final String text;

  const _AdventureLog({required this.type, required this.text});
}
