package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.util.Json;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 一次 Agent 对话的运行实例：持有 SSE 输出流与取消标志。
 *
 * <p>取消链路：前端 abort / 点停止 → 取消接口置位 cancelled；
 * LLM 流通过 takeWhile 退出，工具与长任务在检查点抛
 * {@link AgentCancelledException} 立刻中止。写流失败（浏览器断开）同样视为取消，
 * 避免前端已经停了、后端还在烧 token。</p>
 */
public final class AgentRun {

    private final String id;
    private final String deviceId;
    private final OutputStream out;
    private final long startedAt = System.currentTimeMillis();
    private final AtomicBoolean cancelled = new AtomicBoolean(false);
    private final Object writeLock = new Object();
    private volatile boolean closed;

    AgentRun(String id, String deviceId, OutputStream out) {
        this.id = id;
        this.deviceId = deviceId;
        this.out = out;
    }

    public String id() {
        return id;
    }

    public String deviceId() {
        return deviceId;
    }

    public long startedAt() {
        return startedAt;
    }

    public boolean cancelled() {
        return cancelled.get();
    }

    public boolean closed() {
        return closed;
    }

    public void cancel() {
        cancelled.set(true);
    }

    /** 工具与长任务内的取消检查点。 */
    public void checkCancelled() {
        if (cancelled.get()) {
            throw new AgentCancelledException();
        }
    }

    public void emit(Map<String, Object> event) {
        write("data: " + Json.write(event) + "\n\n");
    }

    /** SSE 注释行心跳：不产生事件，只保持连接。 */
    public void ping() {
        write(": ping\n\n");
    }

    private void write(String payload) {
        if (closed) {
            return;
        }
        synchronized (writeLock) {
            if (closed) {
                return;
            }
            try {
                out.write(payload.getBytes(StandardCharsets.UTF_8));
                out.flush();
            } catch (IOException e) {
                // 浏览器已经断开：标记取消，让上层尽快收尾
                cancelled.set(true);
                closed = true;
            }
        }
    }

    public void close() {
        synchronized (writeLock) {
            closed = true;
            try {
                out.flush();
            } catch (IOException ignored) {
                // 连接已断
            }
        }
    }
}
