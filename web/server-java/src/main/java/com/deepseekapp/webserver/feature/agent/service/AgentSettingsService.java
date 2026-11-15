package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Agent 面板的模型设置：存 MySQL（按设备），读接口对 API Key 脱敏。
 *
 * <p>密钥优先级：面板保存的 Key → application.yml / 环境变量 → web/server/.env。
 * 前端提交的 Key 如果是脱敏值（含 ***）或空串，视为「不修改」。</p>
 */
@Service
public class AgentSettingsService {

    private final AgentStore store;
    private final AppProperties props;

    public AgentSettingsService(AgentStore store, AppProperties props) {
        this.store = store;
        this.props = props;
    }

    /** 供前端展示：Key 已脱敏，只保留首尾。 */
    public Map<String, Object> view(String deviceId) {
        Map<String, Object> row = store.findSettings(deviceId);
        Map<String, Object> out = new LinkedHashMap<>();
        String key = row == null ? "" : text(row.get("api_key"));
        out.put("apiKey", mask(key));
        out.put("hasApiKey", !key.isBlank());
        out.put("baseUrl", row == null ? "" : text(row.get("base_url")));
        out.put("model", row == null ? "" : text(row.get("model")));
        out.put("temperature", row == null ? null : row.get("temperature"));
        out.put("maxTokens", row == null ? null : row.get("max_tokens"));
        out.put("topP", row == null ? null : row.get("top_p"));
        out.put("frequencyPenalty", row == null ? null : row.get("frequency_penalty"));
        out.put("presencePenalty", row == null ? null : row.get("presence_penalty"));
        out.put("systemPrompt", row == null ? "" : text(row.get("system_prompt")));
        out.put("webSearch", row != null && truthy(row.get("web_search")));
        out.put("searchCount", row == null ? 5 : intOr(row.get("search_count"), 5));
        out.put("searchNeedContent", row != null && truthy(row.get("search_need_content")));
        out.put("defaults", Map.of(
                "baseUrl", props.getDeepseekBaseUrl(),
                "model", props.getDeepseekModel(),
                "hasEnvKey", props.getDeepseekApiKey() != null && !props.getDeepseekApiKey().isBlank()));
        return out;
    }

    /** 内部使用：返回包含完整 Key 的运行参数。 */
    public AgentOptions resolve(String deviceId) {
        Map<String, Object> row = store.findSettings(deviceId);
        String key = row == null ? "" : text(row.get("api_key"));
        if (key.isBlank()) {
            key = text(props.getDeepseekApiKey());
        }
        String baseUrl = row == null ? "" : text(row.get("base_url"));
        if (baseUrl.isBlank()) {
            baseUrl = text(props.getDeepseekBaseUrl());
        }
        String model = row == null ? "" : text(row.get("model"));
        if (model.isBlank()) {
            model = text(props.getDeepseekModel());
        }
        return new AgentOptions(
                key,
                baseUrl,
                model,
                dbl(row == null ? null : row.get("temperature")),
                integer(row == null ? null : row.get("max_tokens")),
                dbl(row == null ? null : row.get("top_p")),
                dbl(row == null ? null : row.get("frequency_penalty")),
                dbl(row == null ? null : row.get("presence_penalty")),
                row == null ? "" : text(row.get("system_prompt")),
                row != null && truthy(row.get("web_search")),
                row == null ? 5 : intOr(row.get("search_count"), 5),
                row != null && truthy(row.get("search_need_content")));
    }

    public Map<String, Object> save(String deviceId, Map<String, Object> body) {
        Map<String, Object> existing = store.findSettings(deviceId);
        String currentKey = existing == null ? "" : text(existing.get("api_key"));
        String submitted = text(body.get("apiKey"));
        String key = submitted.contains("***") || submitted.isBlank() ? currentKey : submitted.trim();

        Map<String, Object> row = new LinkedHashMap<>();
        row.put("deviceId", deviceId);
        row.put("apiKey", key);
        row.put("baseUrl", text(pick(body, existing, "baseUrl", "base_url")));
        row.put("model", text(pick(body, existing, "model", "model")));
        row.put("temperature", pick(body, existing, "temperature", "temperature"));
        row.put("maxTokens", pick(body, existing, "maxTokens", "max_tokens"));
        row.put("topP", pick(body, existing, "topP", "top_p"));
        row.put("frequencyPenalty", pick(body, existing, "frequencyPenalty", "frequency_penalty"));
        row.put("presencePenalty", pick(body, existing, "presencePenalty", "presence_penalty"));
        row.put("systemPrompt", text(pick(body, existing, "systemPrompt", "system_prompt")));
        row.put("webSearch", boolPick(body, existing, "webSearch", "web_search"));
        row.put("searchCount", intOr(pick(body, existing, "searchCount", "search_count"), 5));
        row.put("searchNeedContent", boolPick(body, existing, "searchNeedContent", "search_need_content"));
        row.put("now", System.currentTimeMillis());
        store.upsertSettings(row);
        return view(deviceId);
    }

    private static Object pick(Map<String, Object> body, Map<String, Object> existing,
                               String bodyKey, String columnKey) {
        if (body.containsKey(bodyKey)) {
            Object value = body.get(bodyKey);
            if (value instanceof String text && text.isBlank()) {
                return "";
            }
            return value;
        }
        return existing == null ? null : existing.get(columnKey);
    }

    /** 布尔列在 MySQL 里是 TINYINT，兼容 0/1、true/false 两种来源。 */
    private static boolean truthy(Object value) {
        if (value instanceof Boolean b) {
            return b;
        }
        if (value instanceof Number n) {
            return n.intValue() != 0;
        }
        return "1".equals(String.valueOf(value)) || "true".equalsIgnoreCase(String.valueOf(value));
    }

    private static int intOr(Object value, int fallback) {
        if (value instanceof Number n) {
            return n.intValue();
        }
        try {
            return value == null ? fallback : Integer.parseInt(String.valueOf(value));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static boolean boolPick(Map<String, Object> body, Map<String, Object> existing,
                                    String bodyKey, String columnKey) {
        Object value = body.containsKey(bodyKey)
                ? body.get(bodyKey)
                : (existing == null ? null : existing.get(columnKey));
        return truthy(value);
    }

    private static String mask(String key) {
        if (key == null || key.isBlank()) {
            return "";
        }
        if (key.length() <= 10) {
            return "****";
        }
        return key.substring(0, 5) + "****" + key.substring(key.length() - 4);
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }

    private static Double dbl(Object value) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        try {
            return value == null ? null : Double.parseDouble(String.valueOf(value));
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static Integer integer(Object value) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return value == null ? null : Integer.parseInt(String.valueOf(value));
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
