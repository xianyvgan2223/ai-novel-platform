package com.deepseekapp.webserver.ai;

import org.springframework.ai.openai.OpenAiChatOptions;
import org.springframework.ai.openai.api.ResponseFormat;

import java.util.Map;

/**
 * 单次模型调用的设置（模型 / 温度 / 最大 tokens / 追加系统提示 / JSON 模式），
 * 来自网页「AI 设置」，与手机端 outline_settings / chapter_settings 对齐。
 */
public record AiSettings(String model, Double temperature, Integer maxTokens, String systemPrompt,
                         boolean jsonMode) {

    /** 兼容原调用方：默认普通文本模式。 */
    public AiSettings(String model, Double temperature, Integer maxTokens, String systemPrompt) {
        this(model, temperature, maxTokens, systemPrompt, false);
    }

    /** 一键生成大纲等结构化输出使用的 JSON 模式实例。 */
    public static AiSettings jsonOnly(AiSettings source) {
        if (source == null) {
            return new AiSettings("", null, null, null, true);
        }
        return new AiSettings(source.model(), source.temperature(), source.maxTokens(),
                source.systemPrompt(), true);
    }

    public static AiSettings from(Map<String, Object> body) {
        Object raw = body.get("settings");
        if (!(raw instanceof Map<?, ?> map)) {
            return null;
        }
        String model = str(map.get("model"));
        Double temperature = dbl(map.get("temperature"));
        Integer maxTokens = integer(map.get("maxTokens"));
        String systemPrompt = str(map.get("systemPrompt"));
        if (model.isEmpty() && temperature == null && maxTokens == null && systemPrompt.isEmpty()) {
            return null;
        }
        return new AiSettings(model, temperature, maxTokens, systemPrompt, false);
    }

    public boolean hasOptions() {
        return !model.isEmpty() || temperature != null || maxTokens != null || jsonMode;
    }

    public OpenAiChatOptions options() {
        OpenAiChatOptions.Builder builder = OpenAiChatOptions.builder();
        if (!model.isEmpty()) {
            builder.model(apiModel(model));
        }
        if (temperature != null) {
            builder.temperature(Math.min(Math.max(temperature, 0.0), 2.0));
        }
        if (maxTokens != null) {
            builder.maxTokens(Math.min(Math.max(maxTokens, 256), 32768));
        }
        if (jsonMode) {
            // 官方 Chat Completions：response_format={"type":"json_object"}。
            // JSON Output 模式仍要求提示词明确要求模型输出 JSON，二者缺一不可。
            builder.responseFormat(ResponseFormat.builder()
                    .type(ResponseFormat.Type.JSON_OBJECT)
                    .build());
        }
        return builder.build();
    }

    /** 把用户在设置里写的系统提示词追加到基础提示词后面。 */
    public String applySystem(String base) {
        if (systemPrompt == null || systemPrompt.isBlank()) {
            return base;
        }
        return base + "\n\n" + systemPrompt;
    }

    private static String apiModel(String raw) {
        return "deepseek-pro".equals(raw) ? "deepseek-v4-pro" : raw;
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }

    private static Double dbl(Object value) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        try {
            return Double.parseDouble(String.valueOf(value));
        } catch (Exception ignored) {
            return null;
        }
    }

    private static Integer integer(Object value) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(value));
        } catch (Exception ignored) {
            return null;
        }
    }
}
