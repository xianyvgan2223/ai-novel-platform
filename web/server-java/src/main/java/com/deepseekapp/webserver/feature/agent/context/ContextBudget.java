package com.deepseekapp.webserver.feature.agent.context;

/**
 * 上下文预算：把「窗口多大、什么时候压缩、保留多少原文」算成一组整数。
 *
 * <p>公式对齐 DeepSeek Harness 的 compaction-basic：
 * 阈值 = {@code floor(min(W × thresholdRatio, W − 输出预留 − headroom))}，
 * 保留预算 = {@code (W − 输出预留) × retainRatio}。纯函数，便于单测。</p>
 */
public record ContextBudget(int window, int maxOutput, int headroom, int threshold, int retain) {

    public static final double DEFAULT_THRESHOLD_RATIO = 0.8;
    public static final double DEFAULT_RETAIN_RATIO = 0.16;
    public static final int DEFAULT_HEADROOM_TOKENS = 65_536;

    public static ContextBudget of(int window, int maxOutput, double thresholdRatio,
                                   int headroom, double retainRatio) {
        int w = Math.max(1024, window);
        int out = Math.max(0, maxOutput);
        int reserve = Math.max(0, headroom);
        double ratio = thresholdRatio > 0 && thresholdRatio <= 1 ? thresholdRatio : DEFAULT_THRESHOLD_RATIO;

        int base = Math.max(1, w - out);
        int raw = (int) Math.floor(Math.min(w * ratio, (double) w - out - reserve));
        // 小窗口（例如自建模型）算出来可能是 0 或负数，至少留 5% 的可用空间
        int floor = Math.max(1, (int) Math.round(w * 0.05));
        int threshold = Math.max(Math.min(floor, base), Math.min(raw, base));

        double rr = retainRatio > 0 && retainRatio < 1 ? retainRatio : DEFAULT_RETAIN_RATIO;
        int retain = Math.min(base, Math.max(1, (int) Math.floor(base * rr)));
        if (retain >= threshold) {
            retain = Math.max(1, threshold / 2);
        }
        return new ContextBudget(w, out, reserve, threshold, retain);
    }

    /** 已经到阈值，需要压缩。 */
    public boolean needsCompaction(int tokens) {
        return tokens >= threshold;
    }

    /** 展示用的占用百分比（0-100）。 */
    public int percent(int tokens) {
        if (tokens <= 0) {
            return 0;
        }
        return (int) Math.min(100, Math.round(tokens * 100.0 / window));
    }
}
