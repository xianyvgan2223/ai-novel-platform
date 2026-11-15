package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolSupport;
import com.deepseekapp.webserver.web.ApiException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.openai.OpenAiChatOptions;
import org.springframework.stereotype.Service;

import java.io.OutputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Agent 对话编排：会话持久化、面板设置、工具调用、取消与心跳。
 *
 * <p>每轮对话都会把用户消息与助手消息（含工具卡片部件）落到 MySQL，
 * 因此刷新页面后仍能查看历史。模型参数按设备设置动态构建 ChatClient。</p>
 */
@Service
public class AgentService {

    private static final Logger log = LoggerFactory.getLogger(AgentService.class);

    private static final int MAX_HISTORY = 20;
    private static final long HEARTBEAT_SECONDS = 15;

    private static final String BASE_PROMPT = """
            你是 deepseekapp 网页创作工作台的助手，可以直接调用工具读取用户的小说数据、检索情节素材、生成大纲与正文。

            规则：
            1. 需要数据时必须调用工具，不要凭印象编造书名、章节、素材或统计数字。
            2. 工具返回为空就如实说明「库里没有找到」，不要编一个结果。
            3. 生成大纲或正文前，先确认题材、主题、主角等关键信息；用户没说时使用合理默认值，并在回答里说明用了什么默认值。
            4. 生成结果不会自动保存，回答结尾提醒用户可以在页面上确认后保存。
            5. 你是只读的：不要声称已经修改、覆盖或删除任何数据。
            6. 用中文回答，简洁直接；不要整段复述工具返回的原始 JSON，挑关键信息讲。
            7. 任务需要 3 步以上时（分析整本书、批量检查章节、生成后校对等），先调用 plan_task 列出步骤，
               再逐步执行，每完成一步调用 update_task_step 回写状态，最后给出总结。
            8. 关键信息缺失或存在多种合理方案时，调用 ask_user 给用户几个选项，用户可以选也可以自己输入；
               能从工具或上文推断出来时不要滥用。
            9. 联网搜索状态：%s
            """;

    private static final ScheduledExecutorService HEARTBEAT =
            Executors.newScheduledThreadPool(2, runnable -> {
                Thread thread = new Thread(runnable, "agent-heartbeat");
                thread.setDaemon(true);
                return thread;
            });

    private final AgentToolCatalog toolCatalog;
    private final AgentRunRegistry registry;
    private final AgentConversationService conversations;
    private final AgentSettingsService settings;
    private final AgentChatClientFactory clientFactory;

    public AgentService(AgentToolCatalog toolCatalog,
                        AgentRunRegistry registry,
                        AgentConversationService conversations,
                        AgentSettingsService settings,
                        AgentChatClientFactory clientFactory) {
        this.toolCatalog = toolCatalog;
        this.registry = registry;
        this.conversations = conversations;
        this.settings = settings;
        this.clientFactory = clientFactory;
    }

    /**
     * 执行一次对话，事件直接写入 SSE 输出流。方法返回时流已结束。
     *
     * @param deviceId  当前设备
     * @param sessionId 会话 id；为空时自动新建
     * @param message   本轮用户输入
     */
    public void chat(String deviceId, Long sessionId, String message, OutputStream out) {
        AgentRun run = registry.create(deviceId, out);
        ScheduledFuture<?> heartbeat = startHeartbeat(run);
        long startedAt = System.currentTimeMillis();
        AtomicBoolean failed = new AtomicBoolean(false);
        AtomicReference<String> failure = new AtomicReference<>("");
        AtomicReference<Long> activeSession = new AtomicReference<>(0L);

        try {
            long resolved = resolveSession(deviceId, sessionId, message);
            activeSession.set(resolved);
            AgentOptions options = settings.resolve(deviceId);

            Map<String, Object> start = new LinkedHashMap<>();
            start.put("type", "start");
            start.put("runId", run.id());
            start.put("sessionId", resolved);
            start.put("title", conversations.titleOf(deviceId, resolved));
            run.emit(start);

            List<Map<String, String>> history = conversations.history(resolved, MAX_HISTORY);
            conversations.appendUser(deviceId, resolved, message);
            List<Message> messages = buildMessages(history, message);

            ChatClient client = clientFactory.clientFor(options);
            Map<String, Object> toolContext = new LinkedHashMap<>();
            toolContext.put(AgentToolSupport.RUN_ID_KEY, run.id());
            toolContext.put(AgentToolSupport.SESSION_ID_KEY, resolved);
            toolContext.put(AgentToolSupport.DEVICE_ID_KEY, deviceId);

            client.prompt()
                    .system(systemPrompt(options, deviceId))
                    .messages(messages)
                    .tools(toolCatalog.toolObjects(options.webSearch()))
                    .toolContext(toolContext)
                    .options(requestOptions(options))
                    .stream()
                    .content()
                    .takeWhile(delta -> !run.cancelled())
                    .doOnCancel(run::cancel)
                    .doOnNext(delta -> run.emit(AgentEvent.of("delta", "text", delta)))
                    .doOnError(error -> {
                        failed.set(true);
                        failure.set(error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
                        log.warn("agent run {} failed: {}", run.id(), error.toString());
                    })
                    .onErrorResume(error -> reactor.core.publisher.Flux.empty())
                    .blockLast();

            if (run.cancelled()) {
                run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
            } else if (failed.get()) {
                run.emit(AgentEvent.of("error", "error", friendly(failure.get())));
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
            if (heartbeat != null) {
                heartbeat.cancel(false);
            }
            persistAssistant(deviceId, activeSession.get(), run, failed.get(), failure.get(), startedAt);
            registry.remove(run.id());
            run.close();
        }
    }

    private void persistAssistant(String deviceId, long sessionId, AgentRun run,
                                  boolean failed, String failure, long startedAt) {
        if (sessionId <= 0) {
            return;
        }
        try {
            String status = run.cancelled() ? "cancelled" : (failed ? "error" : "done");
            conversations.appendAssistant(deviceId, sessionId, run.text(), run.partsJson(),
                    status, failed ? friendly(failure) : null, elapsed(startedAt));
        } catch (RuntimeException e) {
            log.warn("保存 Agent 助手消息失败：{}", e.getMessage());
        }
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

    private static List<Message> buildMessages(List<Map<String, String>> history, String message) {
        List<Message> out = new ArrayList<>();
        for (Map<String, String> item : history) {
            String content = item.getOrDefault("content", "");
            if (content == null || content.isBlank()) {
                continue;
            }
            out.add("assistant".equals(item.get("role"))
                    ? new AssistantMessage(content)
                    : new UserMessage(content));
        }
        out.add(new UserMessage(message));
        return out;
    }

    private static String systemPrompt(AgentOptions options, String deviceId) {
        String searchState = options.webSearch()
                ? "已开启。需要新闻、实时数据或外部资料时调用 web_search。"
                : "未开启。不要尝试搜索网页；如果确实需要实时信息，告诉用户可以在设置里打开联网搜索。";
        StringBuilder prompt = new StringBuilder(String.format(BASE_PROMPT, searchState));
        prompt.append("\n当前设备：").append(deviceId);
        if (options.systemPrompt() != null && !options.systemPrompt().isBlank()) {
            prompt.append("\n\n").append(options.systemPrompt().trim());
        }
        return prompt.toString();
    }

    private static OpenAiChatOptions requestOptions(AgentOptions options) {
        OpenAiChatOptions.Builder builder = OpenAiChatOptions.builder();
        if (options.model() != null && !options.model().isBlank()) {
            builder.model(options.model());
        }
        if (options.temperature() != null) {
            builder.temperature(Math.min(Math.max(options.temperature(), 0.0), 2.0));
        }
        if (options.maxTokens() != null) {
            builder.maxTokens(Math.min(Math.max(options.maxTokens(), 256), 32768));
        }
        if (options.topP() != null) {
            builder.topP(Math.min(Math.max(options.topP(), 0.0), 1.0));
        }
        if (options.frequencyPenalty() != null) {
            builder.frequencyPenalty(Math.min(Math.max(options.frequencyPenalty(), -2.0), 2.0));
        }
        if (options.presencePenalty() != null) {
            builder.presencePenalty(Math.min(Math.max(options.presencePenalty(), -2.0), 2.0));
        }
        return builder.build();
    }

    private static ScheduledFuture<?> startHeartbeat(AgentRun run) {
        try {
            return HEARTBEAT.scheduleAtFixedRate(() -> {
                if (run.cancelled() || run.closed()) {
                    return;
                }
                run.ping();
            }, HEARTBEAT_SECONDS, HEARTBEAT_SECONDS, TimeUnit.SECONDS);
        } catch (RuntimeException e) {
            return null;
        }
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
