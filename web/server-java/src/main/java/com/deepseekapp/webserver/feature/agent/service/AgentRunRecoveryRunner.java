package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.util.Json;
import com.fasterxml.jackson.core.type.TypeReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

/**
 * 启动恢复：上一次进程退出时还在 running 的运行，标记为 interrupted，
 * 并把已经产出的文本与工具卡片补一条历史消息。
 *
 * <p>模型 HTTP 流无法跨进程续传，所以这里恢复的是「已产出的内容 + 中断状态」；
 * 用户看到历史里的半截回答后可以发一句「继续」接着做，任务计划本身也已落库。</p>
 */
@Component
@Order(3)
public class AgentRunRecoveryRunner implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(AgentRunRecoveryRunner.class);

    private final AgentStore store;
    private final AgentConversationService conversations;

    public AgentRunRecoveryRunner(AgentStore store, AgentConversationService conversations) {
        this.store = store;
        this.conversations = conversations;
    }

    @Override
    public void run(ApplicationArguments args) {
        List<Map<String, Object>> running = store.runningRuns();
        if (running.isEmpty()) {
            return;
        }
        for (Map<String, Object> row : running) {
            String runId = text(row.get("run_id"));
            long sessionId = number(row.get("session_id"));
            String deviceId = text(row.get("device_id"));
            String content = text(row.get("text_so_far"));
            String parts = text(row.get("parts_json"));
            if (sessionId <= 0 || store.findSession(sessionId, deviceId) == null
                    || store.countMessagesByRun(runId) > 0) {
                continue;
            }
            try {
                conversations.appendAssistant(deviceId, sessionId, content,
                        finalizeParts(parts),
                        "interrupted", "服务重启，任务已中断；可以点「继续任务」接着做", null, runId);
            } catch (RuntimeException e) {
                log.warn("恢复中断消息失败（run {}）：{}", runId, e.getMessage());
            }
        }
        store.markInterrupted(System.currentTimeMillis());
        store.markTasksInterrupted(System.currentTimeMillis());
        log.info("Agent 运行恢复：{} 个未完成的运行已标记为 interrupted", running.size());
    }

    /**
     * 进程重启时运行中的工具 / 提问不会再收到返回：在恢复的消息里直接收尾，
     * 避免历史中的工具卡永远显示「执行中」。
     */
    private static String finalizeParts(String raw) {
        String text = raw == null ? "" : raw.trim();
        if (text.isEmpty()) {
            return "[]";
        }
        try {
            List<Map<String, Object>> parts = Json.MAPPER.readValue(
                    text, new TypeReference<List<Map<String, Object>>>() {
                    });
            for (Map<String, Object> part : parts) {
                Object kind = part.get("kind");
                Object status = part.get("status");
                if ("tool".equals(kind) && "running".equals(status)) {
                    part.put("status", "error");
                    part.put("error", "服务重启，工具调用已中断，未收到返回");
                } else if ("ask".equals(kind) && "waiting".equals(status)) {
                    part.put("status", "timeout");
                }
            }
            return Json.write(parts);
        } catch (Exception e) {
            log.warn("解析中断运行的 parts 失败，保留原始内容：{}", e.getMessage());
            return text;
        }
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static long number(Object value) {
        return value instanceof Number n ? n.longValue() : 0L;
    }
}
