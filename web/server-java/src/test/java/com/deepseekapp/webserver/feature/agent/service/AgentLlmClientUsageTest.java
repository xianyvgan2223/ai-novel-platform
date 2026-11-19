package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.context.AgentUsage;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/** DeepSeek 兼容层的 usage 字段解析。 */
class AgentLlmClientUsageTest {

    @Test
    void parsesPromptCompletionAndCachedTokens() {
        Map<String, Object> usage = new LinkedHashMap<>();
        usage.put("prompt_tokens", 1234);
        usage.put("completion_tokens", 56);
        usage.put("total_tokens", 1290);
        usage.put("prompt_cache_hit_tokens", 1000);
        usage.put("prompt_cache_miss_tokens", 234);

        AgentUsage parsed = AgentLlmClient.parseUsage(usage);

        assertEquals(1234, parsed.promptTokens());
        assertEquals(56, parsed.completionTokens());
        assertEquals(1290, parsed.totalTokens());
        assertEquals(1000, parsed.cachedTokens());
    }

    @Test
    void readsCachedTokensFromDetailsWhenTopLevelMissing() {
        Map<String, Object> usage = new LinkedHashMap<>();
        usage.put("prompt_tokens", 10);
        usage.put("completion_tokens", 2);
        usage.put("total_tokens", 12);
        usage.put("prompt_tokens_details", Map.of("cached_tokens", 8));

        assertEquals(8, AgentLlmClient.parseUsage(usage).cachedTokens());
    }

    @Test
    void ignoresEmptyOrNullUsage() {
        assertNull(AgentLlmClient.parseUsage(null));
        assertNull(AgentLlmClient.parseUsage(Map.of()));
        assertNull(AgentLlmClient.parseUsage(Map.of("prompt_tokens", 0, "completion_tokens", 0)));
    }
}
