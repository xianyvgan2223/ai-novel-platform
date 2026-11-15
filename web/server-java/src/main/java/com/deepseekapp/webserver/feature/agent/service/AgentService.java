package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.runtime.AgentCancelledException;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolSupport;
import com.deepseekapp.webserver.web.ApiException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.Message;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Agent 对话编排。
 *
 * <p>执行模型：{@link #start} 同步创建会话与运行、登记用户消息，然后把模型调用
 * 提交到后台线程；控制器的请求线程只负责 {@link AgentRun#attach} 把事件写给浏览器。
 * 因此浏览器断开不会中断生成，重连后可以从任意 seq 继续接收。</p>
 */
@Service
public class AgentService {

    private static final Logger log = LoggerFactory.getLogger(AgentService.class);

    private static final int MAX_HISTORY = 20;

    private static final ExecutorService EXECUTOR = Executors.newFixedThreadPool(4, runnable -> {
        Thread thread = new Thread(runnable, "agent-run");
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
     * 创建并启动一次运行。返回后调用方应立即 {@link AgentRun#attach} 接管当前客户端；
     * 即使没有客户端接入，运行也会继续到结束。
     */
    public AgentRun start(String deviceId, Long sessionId, String message) {
        long resolved = resolveSession(deviceId, sessionId, message);
        AgentRun run = registry.create(deviceId, resolved);

        Map<String, Object> start = new LinkedHashMap<>();
        start.put("type", "start");
        start.put("runId", run.id());
        start.put("sessionId", resolved);
        start.put("title", conversations.titleOf(deviceId, resolved));
        run.emit(start);

        List<Map<String, String>> history = conversations.history(resolved, MAX_HISTORY);
        conversations.appendUser(deviceId, resolved, message);

        EXECUTOR.submit(() -> execute(run, deviceId, resolved, message, history));
        return run;
    }

    private void execute(AgentRun run, String deviceId, long sessionId, String message,
                         List<Map<String, String>> history) {
        long startedAt = System.currentTimeMillis();
        AtomicBoolean failed = new AtomicBoolean(false);
        AtomicReference<String> failure = new AtomicReference<>("");
        try {
            AgentOptions options = settings.resolve(deviceId);
            List<Message> messages = AgentPromptFactory.buildMessages(history, message);
            ChatClient client = clientFactory.clientFor(options);

            Map<String, Object> toolContext = new LinkedHashMap<>();
            toolContext.put(AgentToolSupport.RUN_ID_KEY, run.id());
            toolContext.put(AgentToolSupport.SESSION_ID_KEY, sessionId);
            toolContext.put(AgentToolSupport.DEVICE_ID_KEY, deviceId);

            client.prompt()
                    .system(AgentPromptFactory.systemPrompt(options, deviceId))
                    .messages(messages)
                    .tools(toolCatalog.toolObjects(options.webSearch()))
                    .toolContext(toolContext)
                    .options(AgentPromptFactory.requestOptions(options))
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
            String status = run.cancelled() ? "cancelled" : (failed.get() ? "error" : "done");
            persistAssistant(deviceId, sessionId, run, failed.get(), failure.get(), startedAt);
            run.markFinished(status);
        }
    }

    private void persistAssistant(String deviceId, long sessionId, AgentRun run,
                                  boolean failed, String failure, long startedAt) {
        try {
            String status = run.cancelled() ? "cancelled" : (failed ? "error" : "done");
            conversations.appendAssistant(deviceId, sessionId, run.text(), run.partsJson(),
                    status, failed ? friendly(failure) : null, elapsed(startedAt), run.id());
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
