import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/application/chat_context_budget.dart';

/// 移动端上下文预算：公式与网页端 / DSH 的 compaction-basic 一致。
void main() {
  test('1M 窗口、默认输出预留下的阈值与保留预算', () {
    final budget = ChatContextBudget.of(maxTokens: 4096);
    // min(1M×0.8, 1M−4096−65536) = 800000
    expect(budget.window, 1000000);
    expect(budget.threshold, 800000);
    // (1M−4096)×0.16 ≈ 159345
    expect(budget.retain, greaterThan(150000));
    expect(budget.retain, lessThan(budget.threshold));
    expect(budget.needsCompaction(799999), isFalse);
    expect(budget.needsCompaction(800000), isTrue);
    expect(budget.percent(800000), 80);
  });

  test('小窗口回退到 5% 兜底，且保留预算小于阈值', () {
    // 32k 窗口、4k 输出预留：W−O−headroom 为负，回落到窗口 5% 的兜底阈值
    final budget = ChatContextBudget.of(maxTokens: 4096, window: 32768);
    expect(budget.threshold, 1638);
    expect(budget.retain, greaterThan(0));
    expect(budget.retain, lessThan(budget.threshold));

    // 退化场景（输出预留比窗口还大）：不能出现 0 或负数
    final degenerate = ChatContextBudget.of(maxTokens: 32768, window: 4000);
    expect(degenerate.threshold, greaterThan(0));
    expect(degenerate.retain, greaterThan(0));
  });

  test('保留段选择：至少保留最后一条，最近的优先', () {
    // 每条 100 tokens，保留 250 → 只保留最后两条
    expect(ChatContextBudget.keepFrom([100, 100, 100, 100], 250), 2);
    // 全部都在预算内 → 0（无需压缩）
    expect(ChatContextBudget.keepFrom([10, 10], 1000), 0);
    // 空列表
    expect(ChatContextBudget.keepFrom([], 100), 0);
    // 最后一条超大：仍然保留它（不能压缩到空）
    expect(ChatContextBudget.keepFrom([10, 10, 9999], 100), 2);
  });

  test('token 估算：中文按字、英文按 3.5 字符', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('你好世界'), 4);
    expect(estimateTokens('hello world'), 4);
    expect(estimateTokens('你好 world'), 4);
    expect(estimateMessageTokens('你好'), estimateTokens('你好') + 4);
  });

  test('官方两个模型的窗口都是 1M', () {
    expect(contextWindowForModel('deepseek-flash'), 1000000);
    expect(contextWindowForModel('deepseek-v4-pro'), 1000000);
    expect(contextWindowForModel('custom-model'), 1000000);
  });
}
