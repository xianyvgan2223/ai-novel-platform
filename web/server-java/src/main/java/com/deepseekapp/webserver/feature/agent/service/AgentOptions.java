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
        boolean webSearch,
        int searchCount,
        boolean searchNeedContent
) {
}
