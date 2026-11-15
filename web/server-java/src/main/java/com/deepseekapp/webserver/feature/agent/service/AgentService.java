package com.deepseekapp.webserver.feature.agent.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.stereotype.Service;

import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolSupport;

/**
 * Agent 对话编排：把历史消息交给 Spring AI，模型按需调用工具，
 * 文本增量与工具事件通过 {@link AgentRun} 实时写到 SSE。
 *
 * <p>取消：前端 abort 或点停止后，取消接口置位 cancelled；
 * 这里的 Flux 用 takeWhile 退出并向上游传播取消（真正停掉对 DeepSeek 的请求）。</p>
 */
@Service
public class AgentService {

    private static final Logger log = LoggerFactory.getLogger(AgentService.class);

    private static final int MAX_HISTORY = 20;
    private static final long HEARTBEAT_SECONDS = 15;

    private static final String SYSTEM_PROMPT = """
            你是 deepseekapp 网页创作工作台的助手，可以直接调用工具读取用户的小说数据、检索情节素材、生成大纲与正文。

            规则：
            1. 需要数据时必须调用工具，不要凭印象编造书名、章节、素材或统计数字。
            2. 工具返回为空就如实说明「库里没有找到」，不要编一个结果。
            3. 生成大纲或正文前，先确认题材、主题、主角等关键信息；用户没说时使用合理默认值，并在回答里说明用了什么默认值。
            4. 生成结果不会自动保存，回答结尾提醒用户可以在页面上确认后保存。
            5. 你是只读的：不要声称已经修改、覆盖或删除任何数据。
            6. 用中文回答，简洁直接；不要整段复述工具返回的原始 JSON，挑关键信息讲。
            """;

    private static final ScheduledExecutorService HEARTBEAT =
            Executors.newScheduledThreadPool(2, runnable -> {
                Thread thread = new Thread(runnable, "agent-heartbeat");
                thread.setDaemon(true);
                return thread;
            });

    private final ChatClient chatClient;
    private final AgentToolCatalog toolCatalog;
    private final AgentRunRegistry registry;

    public AgentService(ChatClient.Builder builder, AgentToolCatalog toolCatalog, AgentRunRegistry registry) {
        this.chatClient = builder.build();
        this.toolCatalog = toolCatalog;
        this.registry = registry;
    }

    /**
     * 执行一次对话，事件直接写入 SSE 输出流。方法返回时流已结束。
     *
     * @param deviceId 当前设备（决定工具读写哪个数据槽位）
     * @param history  历史消息，元素形如 {role: user|assistant, content: ...}
     * @param message  本轮用户输入
     */
    public void chat(String deviceId, List<Map<String, String>> history,
                     String message, OutputStream out) {
        AgentRun run = registry.create(deviceId, out);
        ScheduledFuture<?> heartbeat = startHeartbeat(run);
        long startedAt = System.currentTimeMillis();
        AtomicBoolean failed = new AtomicBoolean(false);

        try {
            run.emit(AgentEvent.of("start", "runId", run.id()));

            List<Message> messages = buildMessages(history, message);

            chatClient.prompt()
                    .system(SYSTEM_PROMPT + "\n当前设备：" + deviceId)
                    .messages(messages)
                    .tools(toolCatalog.toolObjects())
                    .toolContext(Map.of(AgentToolSupport.RUN_ID_KEY, run.id()))
                    .stream()
                    .content()
                    .takeWhile(delta -> !run.cancelled())
                    .doOnCancel(run::cancel)
                    .doOnNext(delta -> run.emit(AgentEvent.of("delta", "text", delta)))
                    .doOnError(error -> {
                        failed.set(true);
                        log.warn("agent run {} failed: {}", run.id(), error.toString());
                    })
                    .onErrorResume(error -> reactor.core.publisher.Flux.empty())
                    .blockLast();

            if (run.cancelled()) {
                run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
            } else if (failed.get()) {
                run.emit(AgentEvent.of("error", "error", "模型调用失败，请稍后重试"));
            } else {
                run.emit(AgentEvent.of("done", "elapsedMs", elapsed(startedAt)));
            }
        } catch (AgentCancelledException e) {
            run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
        } catch (Exception e) {
            if (run.cancelled()) {
                run.emit(AgentEvent.of("cancelled", "elapsedMs", elapsed(startedAt)));
            } else {
                log.warn("agent run {} error", run.id(), e);
                run.emit(AgentEvent.of("error",
                        "error", e.getMessage() == null ? "对话失败" : e.getMessage()));
            }
        } finally {
            if (heartbeat != null) {
                heartbeat.cancel(false);
            }
            registry.remove(run.id());
            run.close();
        }
    }

    private static List<Message> buildMessages(List<Map<String, String>> history, String message) {
        List<Message> out = new ArrayList<>();
        List<Map<String, String>> safeHistory = history == null ? List.of() : history;
        int from = Math.max(0, safeHistory.size() - MAX_HISTORY);
        for (Map<String, String> item : safeHistory.subList(from, safeHistory.size())) {
            String content = item.getOrDefault("content", "");
            if (content == null || content.isBlank()) {
                continue;
            }
            String role = item.getOrDefault("role", "user");
            out.add("assistant".equals(role) ? new AssistantMessage(content) : new UserMessage(content));
        }
        out.add(new UserMessage(message));
        return out;
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

    private static long elapsed(long startedAt) {
        return System.currentTimeMillis() - startedAt;
    }
}
