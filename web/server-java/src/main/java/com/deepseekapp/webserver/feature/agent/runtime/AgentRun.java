package com.deepseekapp.webserver.feature.agent.runtime;

import com.deepseekapp.webserver.util.Json;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 一次 Agent 运行：事件缓冲 + 多客户端接入。
 *
 * <p>与上一版的区别：事件先写进内存缓冲，再由 {@link #attach} 逐个客户端输出。
 * 浏览器断开只会让 attach 循环退出（标记 detached），**不会终止模型调用**；
 * 重连时用 afterSeq 重放缺失事件即可继续看。断开超过宽限期仍无人接入才取消，
 * 避免用户关掉页面后一直烧 token。</p>
 */
public final class AgentRun {

    private static final long PING_INTERVAL_MS = 15_000;

    private static final ScheduledExecutorService TIMER = Executors.newScheduledThreadPool(1, runnable -> {
        Thread thread = new Thread(runnable, "agent-detach-timer");
        thread.setDaemon(true);
        return thread;
    });

    private final String id;
    private final String deviceId;
    private final long sessionId;
    private final AgentRunListener listener;
    private final long startedAt = System.currentTimeMillis();
    private final AtomicBoolean cancelled = new AtomicBoolean(false);
    private final List<Map<String, Object>> events = new ArrayList<>();
    private final List<Map<String, Object>> parts = Collections.synchronizedList(new ArrayList<>());
    private final Object lock = new Object();
    /** 断开后等待重连的时间；超过则取消运行。 */
    private final long detachGraceSeconds;
    /** 单次运行最多保留的事件数，防止超长对话占满内存。 */
    private final int maxEvents;

    private long seq;
    private boolean finished;
    private String finishedStatus = "done";
    private String finishedError;
    private boolean attached;
    private long detachedAt;
    private long finishedAt;

    AgentRun(String id, String deviceId, long sessionId, AgentRunListener listener,
             long detachGraceSeconds, int maxEvents) {
        this.id = id;
        this.deviceId = deviceId;
        this.sessionId = sessionId;
        this.listener = listener;
        this.detachGraceSeconds = Math.max(10, detachGraceSeconds);
        this.maxEvents = Math.max(100, maxEvents);
    }

    public String id() {
        return id;
    }

    public String deviceId() {
        return deviceId;
    }

    public long sessionId() {
        return sessionId;
    }

    public long startedAt() {
        return startedAt;
    }

    public boolean cancelled() {
        return cancelled.get();
    }

    public boolean finished() {
        synchronized (lock) {
            return finished;
        }
    }

    public long lastSeq() {
        synchronized (lock) {
            return seq;
        }
    }

    public void cancel() {
        cancelled.set(true);
        synchronized (lock) {
            lock.notifyAll();
        }
    }

    public void checkCancelled() {
        if (cancelled.get()) {
            throw new AgentCancelledException();
        }
    }

    /** 写入事件：进缓冲、更新时间线、唤醒所有等待的 attach 循环。 */
    public void emit(Map<String, Object> event) {
        synchronized (lock) {
            seq++;
            event.put("seq", seq);
            events.add(event);
            if (events.size() > maxEvents) {
                events.remove(0);
            }
            record(event);
            lock.notifyAll();
        }
        if (listener != null) {
            listener.onEvent(this, event);
        }
    }

    /**
     * 把一个客户端接到运行上：先重放 afterSeq 之后的事件，再持续跟随。
     * 客户端断开时只是退出本方法，运行继续。
     */
    public void attach(OutputStream out, long afterSeq) {
        long cursor = Math.max(0, afterSeq);
        long lastWrite = System.currentTimeMillis();
        while (true) {
            List<Map<String, Object>> pending;
            boolean done;
            synchronized (lock) {
                pending = new ArrayList<>();
                for (Map<String, Object> event : events) {
                    if (seqOf(event) > cursor) {
                        pending.add(event);
                    }
                }
                done = finished;
                attached = true;
                detachedAt = 0;
            }

            for (Map<String, Object> event : pending) {
                try {
                    out.write(("data: " + Json.write(event) + "\n\n").getBytes(StandardCharsets.UTF_8));
                    out.flush();
                    cursor = seqOf(event);
                    lastWrite = System.currentTimeMillis();
                } catch (IOException e) {
                    detach();
                    return;
                }
            }

            if (done) {
                return;
            }
            if (System.currentTimeMillis() - lastWrite >= PING_INTERVAL_MS) {
                try {
                    out.write(": ping\n\n".getBytes(StandardCharsets.UTF_8));
                    out.flush();
                    lastWrite = System.currentTimeMillis();
                } catch (IOException e) {
                    detach();
                    return;
                }
            }

            synchronized (lock) {
                if (!finished) {
                    try {
                        lock.wait(500);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        detach();
                        return;
                    }
                }
            }
        }
    }

    /** 客户端断开：标记 detached，并在宽限期后检查是否需要取消。 */
    public void detach() {
        long stamp;
        synchronized (lock) {
            attached = false;
            detachedAt = System.currentTimeMillis();
            stamp = detachedAt;
        }
        TIMER.schedule(() -> {
            boolean shouldCancel;
            synchronized (lock) {
                shouldCancel = !finished && !attached && detachedAt == stamp
                        && System.currentTimeMillis() - detachedAt >= detachGraceSeconds * 1000;
            }
            if (shouldCancel) {
                cancel();
            }
        }, detachGraceSeconds, TimeUnit.SECONDS);
    }

    /**
     * 运行结束：唤醒所有 attach 循环，并把最终状态交给监听器落库。
     *
     * <p>结束前把仍在「执行中/等待中」的部件收敛掉：取消或异常时工具卡如果没有
     * 收到结果，历史消息里会永远转圈，与真实结束状态不一致。</p>
     */
    public void markFinished(String status, String error) {
        boolean first;
        String normalized = status == null ? "done" : status;
        synchronized (lock) {
            first = !finished;
            finished = true;
            finishedStatus = normalized;
            finishedError = error;
            finishedAt = System.currentTimeMillis();
            lock.notifyAll();
        }
        if (first) {
            finalizeParts();
        }
        if (first && listener != null) {
            listener.onFinish(this, finishedStatus, finishedError);
        }
    }

    public void markFinished(String status) {
        markFinished(status, null);
    }

    private void finalizeParts() {
        synchronized (parts) {
            for (Map<String, Object> part : parts) {
                Object kind = part.get("kind");
                Object status = part.get("status");
                if ("tool".equals(kind) && "running".equals(status)) {
                    part.put("status", "error");
                    part.put("error", "运行已结束，未收到工具返回");
                } else if ("ask".equals(kind) && "waiting".equals(status)) {
                    part.put("status", "timeout");
                }
            }
        }
    }

    /** 结束超过一定时间的运行可以从注册表移除。 */
    public boolean expired(long maxAgeMs) {
        synchronized (lock) {
            return finished && System.currentTimeMillis() - finishedAt > maxAgeMs;
        }
    }

    /** 当前是否有客户端连着（用于「运行中」列表过滤）。 */
    public boolean attachedClient() {
        synchronized (lock) {
            return attached;
        }
    }

    // ── 消息部件时间线 ──

    /**
     * 记录部件。与 {@link #partsJson()} 的遍历串行化：journal 在写线程里取快照，
     * 这里在模型线程里改部件，不加锁会出现读到半更新映射的风险。
     */
    private void record(Map<String, Object> event) {
        synchronized (parts) {
            recordLocked(event);
        }
    }

    private void recordLocked(Map<String, Object> event) {
        String type = String.valueOf(event.get("type"));
        switch (type) {
            case "delta" -> {
                String text = String.valueOf(event.getOrDefault("text", ""));
                if (text.isEmpty()) {
                    return;
                }
                Map<String, Object> last = parts.isEmpty() ? null : parts.get(parts.size() - 1);
                if (last != null && "text".equals(last.get("kind"))) {
                    last.put("text", String.valueOf(last.get("text")) + text);
                } else {
                    Map<String, Object> part = new LinkedHashMap<>();
                    part.put("kind", "text");
                    part.put("text", text);
                    parts.add(part);
                }
            }
            case "thinking" -> {
                String text = String.valueOf(event.getOrDefault("text", ""));
                if (text.isEmpty()) {
                    return;
                }
                Map<String, Object> last = parts.isEmpty() ? null : parts.get(parts.size() - 1);
                if (last != null && "thinking".equals(last.get("kind"))) {
                    last.put("text", String.valueOf(last.get("text")) + text);
                } else {
                    Map<String, Object> part = new LinkedHashMap<>();
                    part.put("kind", "thinking");
                    part.put("text", text);
                    parts.add(part);
                }
            }
            case "tool_call" -> {
                Map<String, Object> part = new LinkedHashMap<>();
                part.put("kind", "tool");
                part.put("id", event.get("id"));
                part.put("name", event.get("name"));
                part.put("args", event.get("args"));
                part.put("status", "running");
                parts.add(part);
            }
            case "tool_result", "tool_error" -> {
                synchronized (parts) {
                    for (int i = parts.size() - 1; i >= 0; i--) {
                        Map<String, Object> part = parts.get(i);
                        if (!"tool".equals(part.get("kind")) || !Objects.equals(part.get("id"), event.get("id"))) {
                            continue;
                        }
                        part.put("status", "tool_result".equals(type) ? "ok" : "error");
                        putIfPresent(part, "summary", event.get("summary"));
                        putIfPresent(part, "data", event.get("data"));
                        putIfPresent(part, "error", event.get("error"));
                        putIfPresent(part, "elapsedMs", event.get("elapsedMs"));
                        break;
                    }
                }
            }
            case "ask" -> {
                Map<String, Object> part = new LinkedHashMap<>();
                part.put("kind", "ask");
                part.put("id", event.get("id"));
                part.put("question", event.get("question"));
                part.put("options", event.get("options"));
                part.put("status", "waiting");
                parts.add(part);
            }
            case "ask_answer" -> {
                synchronized (parts) {
                    for (int i = parts.size() - 1; i >= 0; i--) {
                        Map<String, Object> part = parts.get(i);
                        if (!"ask".equals(part.get("kind")) || !Objects.equals(part.get("id"), event.get("id"))) {
                            continue;
                        }
                        boolean timeout = Boolean.TRUE.equals(event.get("timeout"));
                        part.put("status", timeout ? "timeout" : "answered");
                        if (event.get("answer") != null) {
                            part.put("answer", event.get("answer"));
                        }
                        break;
                    }
                }
            }
            default -> {
                // start / done / cancelled / stage / task / heartbeat 不进消息部件
            }
        }
    }

    private static void putIfPresent(Map<String, Object> target, String key, Object value) {
        if (value != null) {
            target.put(key, value);
        }
    }

    /** 纯文本内容（用于历史上下文）。 */
    public String text() {
        StringBuilder sb = new StringBuilder();
        synchronized (parts) {
            for (Map<String, Object> part : parts) {
                if ("text".equals(part.get("kind"))) {
                    sb.append(part.get("text"));
                }
            }
        }
        return sb.toString();
    }

    public String partsJson() {
        synchronized (parts) {
            return Json.write(new ArrayList<>(parts));
        }
    }

    private static long seqOf(Map<String, Object> event) {
        Object value = event.get("seq");
        return value instanceof Number n ? n.longValue() : 0;
    }
}
