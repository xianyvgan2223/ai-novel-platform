package com.deepseekapp.webserver.feature.agent.context;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 压缩阈值与保留预算，公式对齐 DSH compaction-basic。 */
class ContextBudgetTest {

    @Test
    void defaultValueForDeepSeekOneMillionWindow() {
        ContextBudget budget = ContextBudget.of(1_000_000, 32_768,
                ContextBudget.DEFAULT_THRESHOLD_RATIO, ContextBudget.DEFAULT_HEADROOM_TOKENS,
                ContextBudget.DEFAULT_RETAIN_RATIO);

        // min(1M × 0.8, 1M − 32768 − 65536) = 800000
        assertEquals(800_000, budget.threshold());
        // (1M − 32768) × 0.16 = 154757
        assertEquals(154_757, budget.retain());
        assertTrue(budget.retain() < budget.threshold());
        assertFalse(budget.needsCompaction(799_999));
        assertTrue(budget.needsCompaction(800_000));
        assertEquals(80, budget.percent(800_000));
    }

    @Test
    void headroomCapsThresholdWhenWindowIsSmall() {
        ContextBudget budget = ContextBudget.of(100_000, 8_192,
                ContextBudget.DEFAULT_THRESHOLD_RATIO, ContextBudget.DEFAULT_HEADROOM_TOKENS,
                ContextBudget.DEFAULT_RETAIN_RATIO);

        // min(100k × 0.8, 100k − 8192 − 65536) = 26272，比比例阈值更早压缩
        assertEquals(26_272, budget.threshold());
        assertTrue(budget.retain() > 0);
        assertTrue(budget.retain() < budget.threshold());
    }

    @Test
    void zeroWindowDoesNotProduceNegativeNumbers() {
        ContextBudget budget = ContextBudget.of(0, 0, 0, 0, 0);

        assertTrue(budget.window() >= 1024);
        assertTrue(budget.threshold() > 0);
        assertTrue(budget.retain() > 0);
        assertEquals(0, budget.percent(0));
        assertEquals(100, budget.percent(budget.window() * 2));
    }
}
