package com.deepseekapp.webserver.feature.writing.service;

import com.deepseekapp.webserver.ai.AiSettings;
import com.deepseekapp.webserver.ai.NovelAiService;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 「小说灵感」的通用 AI 调用：前端按移动端同一套规则拼好 system + messages，
 * 这里只负责校验配置并流式返回，不参与灵感数据的存储。
 */
@Service
public class InspirationAiService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private final NovelAiService ai;
    private final WritingService writingService;

    public InspirationAiService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void stream(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();
        String system = str(body.get("systemPrompt"));
        List<Map<String, String>> messages = messages(body.get("messages"));
        if (messages.isEmpty()) {
            throw new IllegalArgumentException("灵感指令不能为空");
        }
        AiSettings settings = AiSettings.from(body);
        for (String delta : ai.streamMessages(system, messages, settings).toIterable()) {
            if (delta == null || delta.isEmpty()) {
                continue;
            }
            sink.delta(delta);
        }
    }

    private static List<Map<String, String>> messages(Object raw) {
        List<Map<String, String>> list = new ArrayList<>();
        if (!(raw instanceof List<?> items)) {
            return list;
        }
        for (Object item : items) {
            if (!(item instanceof Map<?, ?> map)) {
                continue;
            }
            String role = map.get("role") == null ? "user" : String.valueOf(map.get("role"));
            String content = map.get("content") == null ? "" : String.valueOf(map.get("content")).trim();
            if (content.isEmpty()) {
                continue;
            }
            Map<String, String> message = new LinkedHashMap<>();
            message.put("role", "assistant".equals(role) ? "assistant" : "user");
            message.put("content", content);
            list.add(message);
        }
        return list;
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }
}