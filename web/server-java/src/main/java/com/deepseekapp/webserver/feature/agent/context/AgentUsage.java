package com.deepseekapp.webserver.feature.agent.context;

/** 一次模型请求的 token 用量（来自 API 的 usage 字段；缓存命中数可能为 0）。 */
public record AgentUsage(int promptTokens, int completionTokens, int totalTokens, int cachedTokens) {

    public int outputTokens() {
        return completionTokens;
    }
}
