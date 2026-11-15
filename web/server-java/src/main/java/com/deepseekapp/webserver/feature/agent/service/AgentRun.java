package com.deepseekapp.webserver.feature.agent.service;

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
    /** 本轮对话的「部件」时间线：文本段 + 工具卡片，用于落库与历史回放。 */
    private final List<Map<String, Object>> parts = Collections.synchronizedList(new ArrayList<>());
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
        record(event);
        write("data: " + Json.write(event) + "\n\n");
    }

    /** 把事件同步进部件列表，保证落库内容与前端看到的完全一致。 */
    private void record(Map<String, Object> event) {
        String type = String.valueOf(event.get("type"));
        switch (type) {
            case "delta" -> {
                String text = String.valueOf(event.getOrDefault("text", ""));
                if (text.isEmpty()) {
                    return;
                }
                synchronized (parts) {
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
                // start / done / cancelled / stage / task 不进消息部件
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
