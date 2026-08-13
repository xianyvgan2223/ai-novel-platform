// lib/game/trpg/model/dice.dart
// 骰子系统 — DnD 风格 d20 判定与通用骰面解析

import 'dart:math';

/// 一次掷骰结果
class RollResult {
  /// 骰子表达式，如 "2d6+3"
  final String formula;

  /// 每颗骰子的点数
  final List<int> rolls;

  /// 固定加值
  final int modifier;

  const RollResult({
    required this.formula,
    required this.rolls,
    required this.modifier,
  });

  int get total => rolls.fold(0, (a, b) => a + b) + modifier;

  /// 可读明细，如 "2d6+3 = [5, 2] + 3 = 10"
  String get detail => '$formula = [${rolls.join(', ')}] + $modifier = $total';

  @override
  String toString() => detail;
}

class Dice {
  static final Random _random = Random();

  /// 掷单个 [sides] 面骰子，返回 1..sides
  static int roll(int sides) => 1 + _random.nextInt(sides);

  static int d20() => roll(20);

  /// 优势：掷两次取大（返回两次点数与结果）
  static RollResult d20Advantage() {
    final a = d20();
    final b = d20();
    final keep = max(a, b);
    return RollResult(
      formula: 'd20(优势)',
      rolls: [keep],
      modifier: 0,
    );
  }

  /// 劣势：掷两次取小
  static RollResult d20Disadvantage() {
    final a = d20();
    final b = d20();
    final keep = min(a, b);
    return RollResult(
      formula: 'd20(劣势)',
      rolls: [keep],
      modifier: 0,
    );
  }

  /// 掷 [count] 个 [sides] 面骰子，加 [modifier]
  static RollResult d(int count, int sides, int modifier) {
    final rolls = List.generate(count, (_) => roll(sides));
    return RollResult(
      formula: '${count}d$sides${modifier >= 0 ? '+' : ''}$modifier',
      rolls: rolls,
      modifier: modifier,
    );
  }

  /// 解析骰子表达式，支持 "2d6+3" / "1d20" / "d8" / "2d6-1" / "3d4"
  /// 无法解析时抛 ArgumentError
  static RollResult parse(String formula) {
    final trimmed = formula.trim().toLowerCase().replaceAll(' ', '');
    final match = RegExp(
      r'^(\d*)d(\d+)([+-]\d+)?$',
    ).firstMatch(trimmed);
    if (match == null) {
      throw ArgumentError('无法解析骰子表达式: $formula');
    }
    final count = int.tryParse(match.group(1) ?? '') ?? 1;
    final sides = int.tryParse(match.group(2)!)!;
    final modifier = int.tryParse(match.group(3) ?? '') ?? 0;
    return d(count, sides, modifier);
  }
}
