package com.deepseekapp.webserver.feature.agent.service;

/** Agent 单次运行使用的模型参数（来自面板设置，缺省回落到 .env / application.yml）。 */
public record AgentOptions(
        String apiKey,
        String baseUrl,
        String model,
        Double temperature,
        Integer maxTokens,
        Double topP,
        Double frequencyPenalty,
        Double presencePenalty,
        String systemPrompt,
        /** 面板覆盖的上下文窗口（0/null 表示按模型默认 1M） */
        Integer contextWindow,
        boolean webSearch,
        int searchCount,
        boolean searchNeedContent,
        boolean stream,
        boolean thinking,
        String reasoningEffort
) {

    /** record 默认 toString 会带出明文 Key，日志/异常里一旦打印就是泄露，这里统一脱敏。 */
    @Override
    public String toString() {
        return "AgentOptions[model=" + model
                + ", baseUrl=" + baseUrl
                + ", apiKey=" + (apiKey == null || apiKey.isBlank() ? "" : "***")
                + ", temperature=" + temperature
                + ", maxTokens=" + maxTokens
                + ", topP=" + topP
                + ", contextWindow=" + contextWindow
                + ", stream=" + stream
                + ", thinking=" + thinking
                + ", reasoningEffort=" + reasoningEffort
                + ", webSearch=" + webSearch
                + "]";
    }
}
