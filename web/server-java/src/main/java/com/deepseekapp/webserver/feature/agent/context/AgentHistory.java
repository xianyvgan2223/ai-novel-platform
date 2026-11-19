package com.deepseekapp.webserver.feature.agent.context;

import java.util.List;

/**
 * 拼给模型的历史：一段「更早对话的摘要」+ 摘要之后逐字保留的消息。
 *
 * <p>{@code summaryUpto} 是被摘要覆盖的最后一条消息 id，后续只加载更大的 id，
 * 避免重复摘要同一段历史。</p>
 */
public record AgentHistory(String summary, long summaryUpto, List<Message> messages) {

    public record Message(long id, String role, String content) {
    }

    public static AgentHistory empty() {
        return new AgentHistory("", 0L, List.of());
    }

    public boolean hasSummary() {
        return summary != null && !summary.isBlank();
    }
}
