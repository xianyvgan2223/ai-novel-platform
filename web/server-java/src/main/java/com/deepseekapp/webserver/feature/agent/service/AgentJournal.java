package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 运行日志：把 Agent 运行状态与已产出的内容检查点写进 MySQL。
 *
 * <p>只对内存中的运行做异步写入，不阻塞模型流：非增量事件（工具调用、提问、任务）
 * 立即落一次检查点；token 增量按 800ms 节流，把当前文本与部件快照更新到
 * {@code agent_runs}。进程重启后由 {@link AgentRunRecoveryRunner} 把残留的
 * running 运行标记为 interrupted，并把已产出的内容补成一条历史消息。</p>
 */
@Component
public class AgentJournal implements AgentRunListener {

    private static final Logger log = LoggerFactory.getLogger(AgentJournal.class);
    private static final long CHECKPOINT_INTERVAL_MS = 800;

    private final AgentStore store;
    private final ExecutorService writer = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "agent-journal");
        thread.setDaemon(true);
        return thread;
    });
    private final Map<String, Long> lastCheckpoint = new ConcurrentHashMap<>();

    public AgentJournal(AgentStore store) {
        this.store = store;
    }

    @Override
    public void onStart(AgentRun run) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("runId", run.id());
        row.put("deviceId", run.deviceId());
        row.put("sessionId", run.sessionId());
        row.put("now", run.startedAt());
        submit(() -> store.insertRun(row), "insert run " + run.id());
    }

    @Override
    public void onEvent(AgentRun run, Map<String, Object> event) {
        String type = String.valueOf(event.get("type"));
        if ("delta".equals(type)) {
            long now = System.currentTimeMillis();
            Long last = lastCheckpoint.get(run.id());
            if (last != null && now - last < CHECKPOINT_INTERVAL_MS) {
                return;
            }
            lastCheckpoint.put(run.id(), now);
        }
        checkpoint(run);
    }

    @Override
    public void onFinish(AgentRun run, String status) {
        lastCheckpoint.remove(run.id());
        String text = run.text();
        String parts = run.partsJson();
        long seq = run.lastSeq();
        submit(() -> store.finishRun(run.id(), seq, text, parts, status, null, System.currentTimeMillis()),
                "finish run " + run.id());
    }

    private void checkpoint(AgentRun run) {
        String text = run.text();
        String parts = run.partsJson();
        long seq = run.lastSeq();
        submit(() -> store.checkpointRun(run.id(), seq, text, parts, "running"),
                "checkpoint run " + run.id());
    }

    private void submit(Runnable task, String action) {
        writer.submit(() -> {
            try {
                task.run();
            } catch (RuntimeException e) {
                log.warn("Agent 运行日志写入失败（{}）：{}", action, e.getMessage());
            }
        });
    }
}
