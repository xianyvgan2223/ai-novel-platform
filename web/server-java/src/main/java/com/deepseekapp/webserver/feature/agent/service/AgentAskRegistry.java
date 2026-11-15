package com.deepseekapp.webserver.feature.agent.service;

import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 等待用户选择的登记表：askId → 未完成的 Future。
 * 前端提交答案后唤醒对应工具调用，对话继续往下走。
 */
@Component
public class AgentAskRegistry {

    private final Map<String, CompletableFuture<String>> pending = new ConcurrentHashMap<>();

    public CompletableFuture<String> register(String askId) {
        CompletableFuture<String> future = new CompletableFuture<>();
        pending.put(askId, future);
        return future;
    }

    public boolean answer(String askId, String answer) {
        CompletableFuture<String> future = pending.remove(askId);
        if (future == null) {
            return false;
        }
        future.complete(answer == null ? "" : answer);
        return true;
    }

    public void remove(String askId) {
        pending.remove(askId);
    }

    /** 运行被取消时唤醒等待中的工具，让它尽快退出。 */
    public void cancel(String askId) {
        CompletableFuture<String> future = pending.remove(askId);
        if (future != null) {
            future.completeExceptionally(new AgentCancelledException());
        }
    }
}
