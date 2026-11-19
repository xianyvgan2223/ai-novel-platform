package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 运行日志：把 Agent 运行状态与已产出的内容检查点写进 MySQL。
 *
 * <p>只对内存中的运行做异步写入，不阻塞模型流：非增量事件（工具调用、提问、任务）
 * 立即落一次检查点；token 增量按 800ms 节流。同一运行同时只排队一个检查点，
 * 避免数据库抖动时快照在队列里无限堆积。进程重启后由
 * {@link AgentRunRecoveryRunner} 把残留的 running 运行标记为 interrupted。</p>
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
    private final Set<String> pendingCheckpoints = ConcurrentHashMap.newKeySet();

    public AgentJournal(AgentStore store) {
        this.store = store;
    }

    @Override
    public void onStart(AgentRun run) {
        Map<String, Object> row = new java.util.LinkedHashMap<>();
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
        // 只保留一个在途检查点：真正执行时再取最新快照，既省序列化也不丢最新状态
        if (!pendingCheckpoints.add(run.id())) {
            return;
        }
        submit(() -> {
            try {
                store.checkpointRun(run.id(), run.lastSeq(), run.text(), run.partsJson(), "running");
            } finally {
                pendingCheckpoints.remove(run.id());
            }
        }, "checkpoint run " + run.id());
    }

    @Override
    public void onFinish(AgentRun run, String status, String error) {
        lastCheckpoint.remove(run.id());
        pendingCheckpoints.remove(run.id());
        String text = run.text();
        String parts = run.partsJson();
        long seq = run.lastSeq();
        submit(() -> store.finishRun(run.id(), seq, text, parts, status, error, System.currentTimeMillis()),
                "finish run " + run.id());
    }

    private void submit(Runnable task, String action) {
        writer.submit(() -> {
            for (int attempt = 0; attempt < 2; attempt++) {
                try {
                    task.run();
                    return;
                } catch (RuntimeException e) {
                    if (attempt == 0) {
                        try {
                            Thread.sleep(150);
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                        continue;
                    }
                    log.warn("Agent 运行日志写入失败（{}）：{}", action, e.getMessage());
                }
            }
        });
    }
}
