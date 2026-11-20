package com.deepseekapp.webserver.feature.agent.context;

import java.util.List;

/**
 * 拼给模型的历史：一段「更早对话的摘要」+ 摘要之后逐字保留的消息。
 *
 * <p>{@code summaryUpto} 是被摘要覆盖的最后一条消息 id，后续只加载更大的 id，
 * 避免重复摘要同一段历史。</p>
 */
public record AgentHistory(String summary, long summaryUpto, List<Message> messages) {

    public record Message(long id, String role, String content, boolean incomplete, String toolNote) {

        /** 生成中断的消息拼给模型时的标注：明确告诉模型这段内容不完整，不要当结论用。 */
        public static final String INCOMPLETE_NOTE =
                "【系统标注：下面这条助手回复在上一次生成过程中因连接中断而失败，内容不完整，"
                        + "只能作为已经产出的上下文参考，不要把它当作完整回答，也不要原样重复引用。】\n\n";

        /** 完整的历史消息。 */
        public Message(long id, String role, String content) {
            this(id, role, content, false, null);
        }

        public Message(long id, String role, String content, boolean incomplete) {
            this(id, role, content, incomplete, null);
        }

        /** 发给模型的内容：中断过的回复带标注与工具执行情况，与正常内容区分开。 */
        public String promptContent() {
            if (!incomplete) {
                return content;
            }
            StringBuilder out = new StringBuilder(INCOMPLETE_NOTE)
                    .append(content == null ? "" : content);
            if (toolNote != null && !toolNote.isBlank()) {
                out.append("\n\n").append(toolNote);
            }
            return out.toString();
        }
    }

    public static AgentHistory empty() {
        return new AgentHistory("", 0L, List.of());
    }

    public boolean hasSummary() {
        return summary != null && !summary.isBlank();
    }
}
