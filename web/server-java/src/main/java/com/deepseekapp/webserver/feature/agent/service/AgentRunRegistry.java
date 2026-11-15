package com.deepseekapp.webserver.feature.agent.service;

import org.springframework.stereotype.Component;

import java.io.OutputStream;
import java.util.Comparator;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 运行中的 Agent 实例表：runId → AgentRun。
 * 取消接口按 runId 找到实例并置位取消标志。
 */
@Component
public class AgentRunRegistry {

    /** 本地单机服务，同时运行的对话不会多，这里只做兜底上限。 */
    private static final int MAX_RUNS = 64;

    private final Map<String, AgentRun> runs = new ConcurrentHashMap<>();

    public AgentRun create(String deviceId, OutputStream out) {
        evictIfNeeded();
        String id = UUID.randomUUID().toString().replace("-", "");
        AgentRun run = new AgentRun(id, deviceId, out);
        runs.put(id, run);
        return run;
    }

    public AgentRun get(String id) {
        return id == null || id.isBlank() ? null : runs.get(id);
    }

    public boolean cancel(String id) {
        AgentRun run = get(id);
        if (run == null) {
            return false;
        }
        run.cancel();
        return true;
    }

    public void remove(String id) {
        if (id != null && !id.isBlank()) {
            runs.remove(id);
        }
    }

    public int size() {
        return runs.size();
    }

    private void evictIfNeeded() {
        if (runs.size() < MAX_RUNS) {
            return;
        }
        runs.entrySet().removeIf(entry -> entry.getValue().closed());
        if (runs.size() < MAX_RUNS) {
            return;
        }
        // 仍有大量活跃 run：优先淘汰开始最早的那个，避免无限增长
        runs.values().stream()
                .min(Comparator.comparingLong(AgentRun::startedAt))
                .ifPresent(oldest -> {
                    oldest.cancel();
                    runs.remove(oldest.id());
                });
    }
}
