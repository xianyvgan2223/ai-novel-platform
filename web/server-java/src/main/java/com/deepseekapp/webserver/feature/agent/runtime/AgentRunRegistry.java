package com.deepseekapp.webserver.feature.agent.runtime;

import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 运行注册表：runId → AgentRun。
 *
 * <p>运行结束后不立即移除，保留一段时间供重连客户端重放事件；
 * 真正过期（默认 10 分钟）或超过容量上限时才清理。</p>
 */
@Component
public class AgentRunRegistry {

    private static final int MAX_RUNS = 64;
    private static final long KEEP_FINISHED_MS = 10 * 60 * 1000;

    private final Map<String, AgentRun> runs = new ConcurrentHashMap<>();
    private final AgentRunListener listener;

    public AgentRunRegistry(AgentRunListener listener) {
        this.listener = listener;
    }

    public AgentRun create(String deviceId, long sessionId) {
        evict();
        String id = UUID.randomUUID().toString().replace("-", "");
        AgentRun run = new AgentRun(id, deviceId, sessionId, listener);
        runs.put(id, run);
        if (listener != null) {
            listener.onStart(run);
        }
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

    /** 某台设备（可选某个会话）还没结束的运行，用于页面刷新后接管。 */
    public List<AgentRun> activeFor(String deviceId, long sessionId) {
        List<AgentRun> out = new ArrayList<>();
        for (AgentRun run : runs.values()) {
            if (run.finished() || !run.deviceId().equals(deviceId)) {
                continue;
            }
            if (sessionId > 0 && run.sessionId() != sessionId) {
                continue;
            }
            out.add(run);
        }
        out.sort(Comparator.comparingLong(AgentRun::startedAt));
        return out;
    }

    public int size() {
        return runs.size();
    }

    private void evict() {
        runs.entrySet().removeIf(entry -> entry.getValue().expired(KEEP_FINISHED_MS));
        if (runs.size() < MAX_RUNS) {
            return;
        }
        runs.values().stream()
                .filter(run -> run.finished())
                .min(Comparator.comparingLong(AgentRun::startedAt))
                .ifPresent(run -> runs.remove(run.id()));
        if (runs.size() >= MAX_RUNS) {
            runs.values().stream()
                    .min(Comparator.comparingLong(AgentRun::startedAt))
                    .ifPresent(oldest -> {
                        oldest.cancel();
                        runs.remove(oldest.id());
                    });
        }
    }
}
