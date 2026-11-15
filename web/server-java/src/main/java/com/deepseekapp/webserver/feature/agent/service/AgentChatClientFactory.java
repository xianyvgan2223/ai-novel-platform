package com.deepseekapp.webserver.feature.agent.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.openai.OpenAiChatModel;
import org.springframework.ai.openai.OpenAiChatOptions;
import org.springframework.ai.openai.api.OpenAiApi;
import org.springframework.stereotype.Component;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 按 Agent 面板设置构建 ChatClient。
 *
 * <p>Spring AI 1.0.9 的 {@code OpenAiChatOptions} 不支持按请求覆盖 apiKey/baseUrl，
 * 所以 Key 或地址变化时需要重建 {@link OpenAiChatModel}。这里按
 * {@code baseUrl|apiKey} 做小容量缓存，避免每轮对话都新建 HTTP 客户端。</p>
 */
@Component
public class AgentChatClientFactory {

    private static final Logger log = LoggerFactory.getLogger(AgentChatClientFactory.class);
    private static final int CACHE_SIZE = 8;

    private final ChatClient.Builder defaultBuilder;
    private final Map<String, ChatClient> cache = Collections.synchronizedMap(
            new LinkedHashMap<>(16, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, ChatClient> eldest) {
                    return size() > CACHE_SIZE;
                }
            });

    public AgentChatClientFactory(ChatClient.Builder defaultBuilder) {
        this.defaultBuilder = defaultBuilder;
    }

    public ChatClient clientFor(AgentOptions options) {
        if (options == null || options.apiKey() == null || options.apiKey().isBlank()) {
            return defaultBuilder.build();
        }
        String cacheKey = options.baseUrl() + "|" + options.apiKey();
        return cache.computeIfAbsent(cacheKey, key -> build(options));
    }

    private ChatClient build(AgentOptions options) {
        try {
            OpenAiApi api = OpenAiApi.builder()
                    .baseUrl(options.baseUrl())
                    .apiKey(options.apiKey())
                    .build();
            OpenAiChatOptions defaults = OpenAiChatOptions.builder()
                    .model(options.model())
                    .build();
            OpenAiChatModel model = OpenAiChatModel.builder()
                    .openAiApi(api)
                    .defaultOptions(defaults)
                    .build();
            return ChatClient.builder(model).build();
        } catch (RuntimeException e) {
            log.warn("按面板设置构建 ChatClient 失败，回退到默认配置：{}", e.getMessage());
            return defaultBuilder.build();
        }
    }
}
