package com.deepseekapp.webserver.feature.agent.runtime;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * 运行注册表：runId → AgentRun。
 *
 * <p>运行结束后不立即移除，保留一段时间供重连客户端重放事件；
 * 定时清理已过期/已完成的运行。容量满时拒绝新运行，**不再取消最老的活跃运行**
 * （那会让用户正在进行的对话被静默杀掉）。</p>
 */
@Component
public class AgentRunRegistry {

    private static final int MAX_RUNS = 64;
    private static final long KEEP_FINISHED_MS = 10 * 60 * 1000;

    private final Map<String, AgentRun> runs = new ConcurrentHashMap<>();
    private final AgentRunListener listener;
    private final AppProperties props;
    private final ScheduledExecutorService cleaner = Executors.newSingleThreadScheduledExecutor(runnable -> {
        Thread thread = new Thread(runnable, "agent-run-cleaner");
        thread.setDaemon(true);
        return thread;
    });

    public AgentRunRegistry(AgentRunListener listener, AppProperties props) {
        this.listener = listener;
        this.props = props;
        // 之前只在 create 时清理，没有新运行时完成的运行会一直占内存
        cleaner.scheduleWithFixedDelay(this::evictFinished, 60, 60, TimeUnit.SECONDS);
    }

    /**
     * 创建运行。
     *
     * <p>同一设备同一会话同时只允许一个运行：两个标签页各发一条会各自读同一份 history，
     * 两条 assistant 消息交错落库，历史从此错乱。</p>
     */
    public AgentRun create(String deviceId, long sessionId) {
        evict();
        if (!activeFor(deviceId, sessionId).isEmpty()) {
            throw new ApiException(409, "这个会话还有一条回复正在生成，请等它结束或先停止");
        }
        if (runs.size() >= MAX_RUNS) {
            evictFinished();
        }
        if (runs.size() >= MAX_RUNS) {
            throw new ApiException(429, "服务端正在运行的对话较多，请稍后再试");
        }
        String id = UUID.randomUUID().toString().replace("-", "");
        AgentRun run = new AgentRun(id, deviceId, sessionId, listener,
                props.getAgentDetachGraceSeconds(), props.getAgentMaxEvents());
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
    }

    private void evictFinished() {
        try {
            evict();
        } catch (RuntimeException ignored) {
            // 清理线程不能因为单次异常退出
        }
    }
}
