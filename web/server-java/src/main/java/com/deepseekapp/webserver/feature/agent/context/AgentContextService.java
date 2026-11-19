package com.deepseekapp.webserver.feature.agent.context;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.service.AgentConversationService;
import com.deepseekapp.webserver.feature.agent.service.AgentLlmClient;
import com.deepseekapp.webserver.feature.agent.service.AgentOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 上下文占用与自动压缩。
 *
 * <p>规则对齐 DeepSeek Harness 的 compaction-basic：窗口 W、输出预留 O、余量 B 时，
 * 压力达到 {@code min(W × 0.8, W − O − B)} 就把最旧的一段历史摘要成
 * {@code <compacted-summary>} 检查点，最近约 16% 的对话保持原文，摘要会写进
 * {@code agent_sessions.summary}，之后的轮次只加载摘要之后的消息。</p>
 *
 * <p>压缩前的压力优先用 API 返回的真实 {@code prompt_tokens}，没有时用
 * {@link TokenEstimator} 估算。</p>
 */
@Service
public class AgentContextService {

    private static final Logger log = LoggerFactory.getLogger(AgentContextService.class);
    private static final int SUMMARY_MAX_TOKENS = 4096;
    private static final int MIN_WINDOW = 8192;

    private static final String SUMMARY_INSTRUCTION = """
            你是一个会话压缩引擎。把上面的对话压缩成一份结构化检查点，让另一个模型在没有原始历史的情况下也能继续工作。
            只输出下面的 Markdown 结构，每个小节都必须保留；没有内容写「无」。用简洁条目，不要写散文。

            ## 用户目标与要求
            - [用户最初和变化后的目标；关键措辞尽量保留原话]
            ## 已确认的设定与事实
            - [书名、题材、人物、世界观、用户偏好等]
            ## 查到的数据与作品
            - [表名、记录 id、标题、统计数字，保留准确 id]
            ## 已生成并保存的内容
            - [作品 outlineId、章节 chapterId/eventIndex、标题、字数]
            ## 进行中的任务
            - [已完成到哪一步、下一步做什么]
            ## 关键约束
            - [用户明确要求或禁止的事项]

            规则：
            - 保留准确的 id、书名、章节序号、数字，不要编造不存在的数据。
            - 不要提到「压缩」这件事，不要调用任何工具，只输出检查点文本。
            - 如果对话里已有 <compacted-summary> 块，把它当作更早的检查点：保留仍然成立的事实，丢弃过时的，合并成一份新的。
            """;

    private final AppProperties props;
    private final AgentConversationService conversations;
    private final AgentLlmClient llm;

    public AgentContextService(AppProperties props, AgentConversationService conversations, AgentLlmClient llm) {
        this.props = props;
        this.conversations = conversations;
        this.llm = llm;
    }

    /** 一次压缩尝试的结果；没有压缩时 compacted=false，history 原样返回。 */
    public record Compacted(AgentHistory history, ContextBudget budget, int estimatedTokens,
                            boolean compacted, int compactedCount, int freedTokens) {
    }

    /** 当前生效的上下文窗口：面板里显式设置优先，否则用服务端默认（1M）。 */
    public int window(AgentOptions options) {
        if (options.contextWindow() != null && options.contextWindow() > 0) {
            return options.contextWindow();
        }
        return Math.max(MIN_WINDOW, props.getAgentContextWindow());
    }

    public ContextBudget budget(AgentOptions options) {
        int maxOutput = options.maxTokens() == null ? 32768 : options.maxTokens();
        return ContextBudget.of(window(options), maxOutput,
                props.getAgentContextThresholdRatio(), props.getAgentHeadroomTokens(),
                props.getAgentRetainRatio());
    }

    /** 估算「这次请求」的上下文占用：system + 工具 schema + 历史 + 待发消息。 */
    public int estimate(String systemPrompt, int toolTokens, AgentHistory history, String pendingUserMessage) {
        int total = TokenEstimator.estimateMessage(systemPrompt) + Math.max(0, toolTokens);
        if (history.hasSummary()) {
            total += TokenEstimator.estimateMessage(summaryBlock(history.summary()));
        }
        for (AgentHistory.Message message : history.messages()) {
            total += TokenEstimator.estimateMessage(message.content());
        }
        total += TokenEstimator.estimateMessage(pendingUserMessage);
        return total;
    }

    /**
     * 到阈值就压缩最旧的一段历史。
     *
     * @param force true 表示手动 / 溢出恢复，即使没到阈值也压缩
     */
    public Compacted compactIfNeeded(AgentRun run, String deviceId, long sessionId, AgentOptions options,
                                     AgentHistory history, String systemPrompt, int toolTokens,
                                     String pendingUserMessage, boolean force) {
        ContextBudget budget = budget(options);
        int estimated = estimate(systemPrompt, toolTokens, history, pendingUserMessage);
        int measured = (int) Math.min(Integer.MAX_VALUE, conversations.contextTokens(deviceId, sessionId));
        int pressure = measured > 0
                ? Math.max(measured + TokenEstimator.estimateMessage(pendingUserMessage), estimated)
                : estimated;

        if (!force && !budget.needsCompaction(pressure)) {
            return new Compacted(history, budget, pressure, false, 0, 0);
        }

        List<AgentHistory.Message> all = history.messages();
        int keepFrom = all.size();
        int kept = 0;
        for (int i = all.size() - 1; i >= 0; i--) {
            int tokens = TokenEstimator.estimateMessage(all.get(i).content());
            if (kept + tokens > budget.retain() && keepFrom < all.size()) {
                break;
            }
            kept += tokens;
            keepFrom = i;
        }
        List<AgentHistory.Message> toCompact = all.subList(0, keepFrom);
        List<AgentHistory.Message> keep = new ArrayList<>(all.subList(keepFrom, all.size()));
        if (toCompact.isEmpty()) {
            return new Compacted(history, budget, pressure, false, 0, 0);
        }

        int before = 0;
        for (AgentHistory.Message message : toCompact) {
            before += TokenEstimator.estimateMessage(message.content());
        }

        String summary;
        try {
            summary = summarize(options, systemPrompt, history.summary(), toCompact);
        } catch (RuntimeException e) {
            log.warn("Agent 历史压缩失败（session {}）：{}", sessionId, e.getMessage());
            if (force) {
                throw e;
            }
            // 自动压缩失败就按原样继续，交给模型/溢出重试兜底
            return new Compacted(history, budget, pressure, false, 0, 0);
        }
        if (summary.isBlank()) {
            return new Compacted(history, budget, pressure, false, 0, 0);
        }

        long upto = toCompact.get(toCompact.size() - 1).id();
        conversations.saveSummary(deviceId, sessionId, summary, upto);
        conversations.saveContextTokens(deviceId, sessionId, 0);

        AgentHistory compacted = new AgentHistory(summary, upto, keep);
        int after = estimate(systemPrompt, toolTokens, compacted, pendingUserMessage);
        int freed = Math.max(0, pressure - after);

        if (run != null) {
            run.emit(AgentEvent.of("compaction",
                    "count", toCompact.size(),
                    "kept", keep.size(),
                    "freedTokens", freed,
                    "summaryChars", summary.length(),
                    "window", budget.window(),
                    "threshold", budget.threshold(),
                    "estimatedTokens", after));
        }
        return new Compacted(compacted, budget, after, true, toCompact.size(), freed);
    }

    /** 手动压缩：不跑模型对话，只把当前历史压一次。 */
    public Map<String, Object> compactNow(String deviceId, long sessionId, AgentOptions options,
                                          String systemPrompt, int toolTokens) {
        AgentHistory history = conversations.history(deviceId, sessionId);
        if (history.messages().isEmpty()) {
            throw new com.deepseekapp.webserver.web.ApiException(400, "当前会话还没有可压缩的历史");
        }
        Compacted result = compactIfNeeded(null, deviceId, sessionId, options, history,
                systemPrompt, toolTokens, "", true);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("compacted", result.compacted());
        out.put("count", result.compactedCount());
        out.put("freedTokens", result.freedTokens());
        out.put("estimatedTokens", result.estimatedTokens());
        out.put("contextWindow", result.budget().window());
        out.put("threshold", result.budget().threshold());
        out.put("percent", result.budget().percent(result.estimatedTokens()));
        return out;
    }

    private String summarize(AgentOptions options, String systemPrompt, String priorSummary,
                             List<AgentHistory.Message> messages) {
        List<Map<String, Object>> input = new ArrayList<>();
        if (priorSummary != null && !priorSummary.isBlank()) {
            Map<String, Object> prior = new LinkedHashMap<>();
            prior.put("role", "system");
            prior.put("content", "更早对话的检查点：\n" + summaryBlock(priorSummary));
            input.add(prior);
        }
        for (AgentHistory.Message message : messages) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("role", "assistant".equals(message.role()) ? "assistant" : "user");
            row.put("content", message.content());
            input.add(row);
        }
        Map<String, Object> instruction = new LinkedHashMap<>();
        instruction.put("role", "user");
        instruction.put("content", SUMMARY_INSTRUCTION);
        input.add(instruction);
        return llm.summarize(options, systemPrompt, input, SUMMARY_MAX_TOKENS).trim();
    }

    /** 摘要注入 system prompt 时的包裹格式（与 DSH 的 checkpoint 一致）。 */
    public static String summaryBlock(String summary) {
        return "<compacted-summary>\n" + summary.trim() + "\n</compacted-summary>";
    }

    public static String summaryPreamble() {
        return """
                【更早对话的检查点（系统自动生成，可直接采信）】
                这段检查点替换了更早的历史消息：把它当作已确认的背景，不要向用户复述，也不要再向用户确认。
                """;
    }
}
