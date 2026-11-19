package com.deepseekapp.webserver.feature.agent.runtime;

import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 等待用户选择的登记表：askId → 未完成的 Future + 归属设备。
 *
 * <p>带上 deviceId 是为了让答题接口也能做设备校验：askId 虽然随机，
 * 但只靠它就能替别的会话答题，属于越权面。</p>
 */
@Component
public class AgentAskRegistry {

    public record Ask(String deviceId, long createdAt, CompletableFuture<String> future) {
    }

    private final Map<String, Ask> pending = new ConcurrentHashMap<>();

    public CompletableFuture<String> register(String askId, String deviceId) {
        CompletableFuture<String> future = new CompletableFuture<>();
        pending.put(askId, new Ask(deviceId == null ? "" : deviceId, System.currentTimeMillis(), future));
        return future;
    }

    /** 只有同一台设备才能回答；返回 false 表示已超时/不存在/不是本设备的提问。 */
    public boolean answer(String askId, String deviceId, String answer) {
        Ask ask = pending.get(askId);
        if (ask == null || !ask.deviceId().equals(deviceId == null ? "" : deviceId)) {
            return false;
        }
        if (!pending.remove(askId, ask)) {
            return false;
        }
        ask.future().complete(answer == null ? "" : answer);
        return true;
    }

    public void remove(String askId) {
        pending.remove(askId);
    }

    /** 运行被取消时唤醒等待中的工具，让它尽快退出。 */
    public void cancel(String askId) {
        Ask ask = pending.remove(askId);
        if (ask != null) {
            ask.future().completeExceptionally(new AgentCancelledException());
        }
    }

    public int pendingCount() {
        return pending.size();
    }
}
