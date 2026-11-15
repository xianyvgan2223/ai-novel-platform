package com.deepseekapp.webserver.ai;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Flux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Spring AI 封装：所有小说写作相关的模型调用都走这里。
 *
 * <p>底层是 OpenAI 兼容协议（application.yml 里的 spring.ai.openai.*），
 * 对接 DeepSeek；密钥由启动时从 web/server/.env 注入。</p>
 */
@Service
public class NovelAiService {

    private final ChatClient chatClient;

    public NovelAiService(ChatClient.Builder builder) {
        this.chatClient = builder.build();
    }

    /** 非流式：一次性拿到完整文本（用于分阶段的结构化 JSON） */
    public String complete(String system, String user) {
        return complete(system, user, null);
    }

    public String complete(String system, String user, AiSettings settings) {
        String finalSystem = settings == null ? system : settings.applySystem(system);
        ChatClient.ChatClientRequestSpec spec = chatClient.prompt()
                .system(finalSystem)
                .user(user);
        if (settings != null && settings.hasOptions()) {
            spec = spec.options(settings.options());
        }
        String content = spec.call().content();
        return content == null ? "" : content;
    }

    /**
     * 流式 JSON 阶段：要求服务端以 response_format={"type":"json_object"} 约束输出。
     * 用于定调 / 粗骨架 / 大事件精写 / 伏笔账本。
     */
    public Flux<String> streamJson(String system, String user, AiSettings settings) {
        AiSettings effective = settings == null ? AiSettings.jsonOnly(null) : AiSettings.jsonOnly(settings);
        String finalSystem = effective.applySystem(system);
        ChatClient.ChatClientRequestSpec spec = chatClient.prompt()
                .system(finalSystem)
                .user(user)
                .options(effective.options());
        return spec.stream().content();
    }

    /** 流式：逐段返回模型输出 */
    public Flux<String> stream(String system, String user) {
        return stream(system, user, null);
    }

    public Flux<String> stream(String system, String user, AiSettings settings) {
        String finalSystem = settings == null ? system : settings.applySystem(system);
        ChatClient.ChatClientRequestSpec spec = chatClient.prompt()
                .system(finalSystem)
                .user(user);
        if (settings != null && settings.hasOptions()) {
            spec = spec.options(settings.options());
        }
        return spec.stream().content();
    }

    /**
     * 多轮对话流式输出：history 按 user / assistant 角色交替传入，
     * 用于「大纲编辑」的 AI 对话（保留上下文，能接着上一轮结果继续改）。
     */
    public Flux<String> streamMessages(String system, List<Map<String, String>> history, AiSettings settings) {
        String finalSystem = settings == null ? system : settings.applySystem(system);
        List<Message> messages = new ArrayList<>();
        messages.add(new SystemMessage(finalSystem));
        for (Map<String, String> item : history) {
            String content = item.getOrDefault("content", "");
            if (content == null || content.isBlank()) {
                continue;
            }
            String role = item.getOrDefault("role", "user");
            messages.add("assistant".equals(role)
                    ? new AssistantMessage(content)
                    : new UserMessage(content));
        }
        ChatClient.ChatClientRequestSpec spec = chatClient.prompt().messages(messages);
        if (settings != null && settings.hasOptions()) {
            spec = spec.options(settings.options());
        }
        return spec.stream().content();
    }
}
