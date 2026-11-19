package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.context.AgentContextService;
import com.deepseekapp.webserver.feature.agent.context.AgentHistory;
import com.deepseekapp.webserver.feature.agent.context.AgentUsage;
import com.deepseekapp.webserver.feature.agent.context.ContextBudget;
import com.deepseekapp.webserver.feature.agent.runtime.AgentCancelledException;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolSupport;
import com.deepseekapp.webserver.web.ApiException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Agent 对话编排。
 *
 * <p>执行模型：{@link #start} 同步创建会话与运行、登记用户消息，然后把模型调用
 * 提交到后台线程；控制器的请求线程只负责 {@link AgentRun#attach} 把事件写给浏览器。
 * 模型调用由 {@link AgentLlmClient} 直接走 OpenAI 兼容协议，以便拿到流式思考内容。</p>
 *
 * <p>线程模型：run 跑在虚拟线程上（{@code ask_user}、长章节生成都会阻塞线程，
 * 固定 4 个平台线程时 4 个提问就能把整个面板卡死），并发数由信号量限制。</p>
 */
@Service
public class AgentService {

    private static final Logger log = LoggerFactory.getLogger(AgentService.class);

    private static final ExecutorService EXECUTOR = Executors.newVirtualThreadPerTaskExecutor();

    private final AgentToolCatalog toolCatalog;
    private final AgentRunRegistry registry;
    private final AgentConversationService conversations;
    private final AgentSettingsService settings;
    private final AgentLlmClient llmClient;
    private final AgentContextService contextService;
    private final AppProperties props;
    private final Semaphore slots;

    public AgentService(AgentToolCatalog toolCatalog,
                        AgentRunRegistry registry,
                        AgentConversationService conversations,
                        AgentSettingsService settings,
                        AgentLlmClient llmClient,
                        AgentContextService contextService,
                        AppProperties props) {
        this.toolCatalog = toolCatalog;
        this.registry = registry;
        this.conversations = conversations;
        this.settings = settings;
        this.llmClient = llmClient;
        this.contextService = contextService;
        this.props = props;
        this.slots = new Semaphore(Math.max(1, props.getAgentMaxConcurrentRuns()));
    }

    /**
     * 创建并启动一次运行。返回后调用方应立即 {@link AgentRun#attach} 接管当前客户端；
     * 即使没有客户端接入，运行也会继续到结束。
     */
    public AgentRun start(String deviceId, Long sessionId, String message) {
        long resolved = resolveSession(deviceId, sessionId, message);
        if (!slots.tryAcquire()) {
            throw new ApiException(429, "当前同时运行的对话过多，请稍后再试");
        }
        AgentRun run;
        try {
            run = registry.create(deviceId, resolved);
        } catch (RuntimeException e) {
            slots.release();
            throw e;
        }

        Map<String, Object> start = new LinkedHashMap<>();
        start.put("type", "start");
        start.put("runId", run.id());
        start.put("sessionId", resolved);
        start.put("title", conversations.titleOf(deviceId, resolved));
        run.emit(start);

        AgentHistory history;
        try {
            history = conversations.history(deviceId, resolved);
            conversations.appendUser(deviceId, resolved, message);
        } catch (RuntimeException e) {
            // 登记用户消息失败：不能把运行和信号量一起漏掉，否则前端会一直 attach 一个不会结束的 run
            run.markFinished("error", e.getMessage());
            slots.release();
            throw e;
        }

        EXECUTOR.submit(() -> {
            try {
                execute(run, deviceId, resolved, message, history);
            } finally {
                slots.release();
            }
        });
        return run;
    }

    private void execute(AgentRun run, String deviceId, long sessionId, String message,
                         AgentHistory history) {
        long startedAt = System.currentTimeMillis();
        AtomicBoolean failed = new AtomicBoolean(false);
        AtomicReference<String> failure = new AtomicReference<>("");
        AtomicReference<AgentUsage> lastUsage = new AtomicReference<>();
        AtomicBoolean emitted = new AtomicBoolean(false);
        try {
            if (run.cancelled()) {
                throw new AgentCancelledException();
            }
            AgentOptions options = settings.resolve(deviceId);
            Object[] toolObjects = toolCatalog.toolObjects(options.webSearch());
            int toolTokens = AgentLlmClient.estimateToolTokens(toolObjects);

            Map<String, Object> toolContext = new LinkedHashMap<>();
            toolContext.put(AgentToolSupport.RUN_ID_KEY, run.id());
            toolContext.put(AgentToolSupport.SESSION_ID_KEY, sessionId);
            toolContext.put(AgentToolSupport.DEVICE_ID_KEY, deviceId);

            AgentHistory current = history;
            boolean retried = false;
            // 每次都会变的时间放在最后一条用户消息末尾，系统提示与历史保持逐字节稳定
            final String runtimeNote = AgentPromptFactory.runtimeNote();
            final String pendingMessage = message + "\n\n" + runtimeNote;
            while (true) {
                // 接近上下文上限时先把最旧的一段压缩成摘要（会推 compaction 事件）
                AgentContextService.Compacted compacted = contextService.compactIfNeeded(
                        run, deviceId, sessionId, options, current,
                        AgentPromptFactory.systemPrompt(options, deviceId), toolTokens, pendingMessage, retried);
                current = compacted.history();
                final ContextBudget budget = compacted.budget();
                final String systemPrompt = AgentPromptFactory.systemPrompt(options, deviceId, current.summary());
                final int estimated = contextService.estimate(systemPrompt, toolTokens, current, pendingMessage);

                run.emit(AgentEvent.of("context",
                        "tokens", estimated,
                        "window", budget.window(),
                        "threshold", budget.threshold(),
                        "percent", budget.percent(estimated),
                        "compacted", compacted.compacted()));

                List<Map<String, Object>> conversation =
                        AgentPromptFactory.conversation(current.messages(), message, runtimeNote);
                try {
                    llmClient.run(
                            options,
                            systemPrompt,
                            conversation,
                            toolObjects,
                            toolContext,
                            run::cancelled,
                            new AgentLlmClient.Sink() {
                                @Override
                                public void content(String text) {
                                    if (text != null && !text.isEmpty()) {
                                        emitted.set(true);
                                        run.emit(AgentEvent.of("delta", "text", text));
                                    }
                                }

                                @Override
                                public void reasoning(String text) {
                                    if (text != null && !text.isEmpty()) {
                                        emitted.set(true);
                                        run.emit(AgentEvent.of("thinking", "text", text));
                                    }
                                }

                                @Override
                                public void usage(AgentUsage usage) {
                                    lastUsage.set(usage);
                                    conversations.saveContextTokens(deviceId, sessionId,
                                            usage.promptTokens(), usage.cachedTokens());
                                    AgentConversationService.UsageTotals totals =
                                            conversations.usageTotals(deviceId, sessionId);
                                    run.emit(AgentEvent.of("usage",
                                            "promptTokens", usage.promptTokens(),
                                            "completionTokens", usage.completionTokens(),
                                            "totalTokens", usage.totalTokens(),
                                            "cachedTokens", usage.cachedTokens(),
                                            "totalPromptTokens", totals.promptTokens(),
                                            "totalCachedTokens", totals.cachedTokens(),
                                            "totalCachePercent", totals.cachePercent(),
                                            "window", budget.window(),
                                            "threshold", budget.threshold(),
                                            "percent", budget.percent(usage.promptTokens())));
                                }
                            });
                    break;
                } catch (ApiException e) {
                    // 提供方确认上下文溢出、且还没吐出任何内容：压缩后重试一次
                    if (!retried && !emitted.get() && isContextOverflow(e)) {
                        retried = true;
                        log.info("agent run {} 上下文溢出，压缩后重试", run.id());
                        continue;
                    }
                    throw e;
                }
            }

            if (run.cancelled()) {
                run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
            } else {
                run.emit(AgentEvent.of("done", "elapsedMs", elapsed(startedAt)));
            }
        } catch (AgentCancelledException e) {
            run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
        } catch (Exception e) {
            if (run.cancelled()) {
                run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
            } else {
                failed.set(true);
                failure.set(e.getMessage());
                log.warn("agent run {} error", run.id(), e);
                run.emit(AgentEvent.of("error", "error", friendly(e.getMessage())));
            }
        } finally {
            String status = run.cancelled() ? "cancelled" : (failed.get() ? "error" : "done");
            persistAssistant(deviceId, sessionId, run, failed.get(), failure.get(), startedAt, lastUsage.get());
            run.markFinished(status, failed.get() ? friendly(failure.get()) : null);
        }
    }

    private void persistAssistant(String deviceId, long sessionId, AgentRun run,
                                  boolean failed, String failure, long startedAt, AgentUsage usage) {
        try {
            String status = run.cancelled() ? "cancelled" : (failed ? "error" : "done");
            conversations.appendAssistant(deviceId, sessionId, run.text(), run.partsJson(),
                    status, failed ? friendly(failure) : null, elapsed(startedAt), run.id(),
                    usage == null ? null : usage.promptTokens(),
                    usage == null ? null : usage.completionTokens(),
                    usage == null ? null : usage.cachedTokens());
        } catch (RuntimeException e) {
            log.warn("保存 Agent 助手消息失败：{}", e.getMessage());
        }
    }

    /** 兼容不同兼容层返回的溢出文案。 */
    private static boolean isContextOverflow(ApiException e) {
        String message = e.getMessage() == null ? "" : e.getMessage().toLowerCase();
        return message.contains("context length")
                || message.contains("maximum context")
                || message.contains("context_length_exceeded")
                || message.contains("too many tokens")
                || (message.contains("context") && (message.contains("exceed") || message.contains("too long")));
    }

    private long resolveSession(String deviceId, Long sessionId, String message) {
        if (sessionId != null && sessionId > 0) {
            try {
                conversations.find(deviceId, sessionId);
                return sessionId;
            } catch (ApiException e) {
                // 会话不存在或不属于当前设备：新建一个，避免对话直接失败
            }
        }
        Map<String, Object> created = conversations.create(deviceId, message);
        return ((Number) created.get("id")).longValue();
    }

    private static String friendly(String message) {
        if (message == null || message.isBlank()) {
            return "模型调用失败，请稍后重试";
        }
        if (message.contains("401") || message.toLowerCase().contains("unauthorized")) {
            return "API Key 无效或已过期，请在 Agent 面板的设置里更换";
        }
        if (message.contains("402") || message.toLowerCase().contains("insufficient")) {
            return "账户余额不足，请检查 DeepSeek 账户";
        }
        return message.length() > 300 ? message.substring(0, 300) : message;
    }

    private static long elapsed(long startedAt) {
        return System.currentTimeMillis() - startedAt;
    }
}
