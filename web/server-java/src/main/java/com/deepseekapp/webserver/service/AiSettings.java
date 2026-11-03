package com.deepseekapp.webserver.service;

import org.springframework.ai.openai.OpenAiChatOptions;

import java.util.Map;

/**
 * 单次模型调用的设置（模型 / 温度 / 最大 tokens / 追加系统提示），
 * 来自网页「AI 设置」，与手机端 outline_settings / chapter_settings 对齐。
 */
public record AiSettings(String model, Double temperature, Integer maxTokens, String systemPrompt) {

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
        return new AiSettings(model, temperature, maxTokens, systemPrompt);
    }

    public boolean hasOptions() {
        return !model.isEmpty() || temperature != null || maxTokens != null;
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
        return builder.build();
    }

    /** 把用户在设置里写的系统提示词追加到基础提示词后面 */
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
