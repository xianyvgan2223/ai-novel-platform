package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.util.OutboundUrlGuard;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
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
        out.put("model", normalizeModel(row == null ? "" : text(row.get("model"))));
        out.put("modelOptions", List.of(
                Map.of("id", "deepseek-flash", "label", "DeepSeek Flash",
                        "description", "响应更快，适合日常对话与快速生成"),
                Map.of("id", "deepseek-v4-pro", "label", "DeepSeek Pro",
                        "description", "推理更强，适合复杂任务与长文创作")));
        out.put("temperature", row == null || row.get("temperature") == null ? 1.0 : row.get("temperature"));
        out.put("maxTokens", row == null || row.get("max_tokens") == null ? 32768 : row.get("max_tokens"));
        out.put("topP", row == null ? null : row.get("top_p"));
        out.put("frequencyPenalty", row == null ? null : row.get("frequency_penalty"));
        out.put("presencePenalty", row == null ? null : row.get("presence_penalty"));
        out.put("systemPrompt", row == null ? "" : text(row.get("system_prompt")));
        out.put("contextWindow", row == null ? 0 : intOr(row.get("context_window"), 0));
        out.put("webSearch", row != null && truthy(row.get("web_search")));
        out.put("searchCount", row == null ? 5 : intOr(row.get("search_count"), 5));
        out.put("searchNeedContent", row != null && truthy(row.get("search_need_content")));
        out.put("stream", row == null || truthy(row.get("stream")));
        out.put("thinking", row == null || truthy(row.get("thinking")));
        out.put("reasoningEffort", normalizeEffort(row == null ? "" : text(row.get("reasoning_effort"))));
        out.put("reasoningEfforts", List.of("none", "low", "high", "max"));
        out.put("defaults", Map.of(
                "baseUrl", props.getDeepseekBaseUrl(),
                "model", "deepseek-flash",
                "temperature", 1.0,
                "maxTokens", 32768,
                "searchCount", 5,
                "stream", true,
                "thinking", true,
                "reasoningEffort", "high",
                "contextWindow", props.getAgentContextWindow(),
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
        try {
            baseUrl = OutboundUrlGuard.requireModelBaseUrl(baseUrl).toString();
        } catch (ApiException e) {
            // 旧的非法地址（例如 http://任意公网主机）直接回落到默认地址，避免带着 Key 出网
            baseUrl = text(props.getDeepseekBaseUrl());
        }
        String model = row == null ? "" : text(row.get("model"));
        if (model.isBlank()) {
            model = text(props.getDeepseekModel());
        }
        model = normalizeModel(model);
        return new AgentOptions(
                key,
                baseUrl,
                model,
                dbl(row == null ? null : row.get("temperature")) == null
                        ? 1.0 : dbl(row.get("temperature")),
                integer(row == null ? null : row.get("max_tokens")) == null
                        ? 32768 : integer(row.get("max_tokens")),
                dbl(row == null ? null : row.get("top_p")),
                dbl(row == null ? null : row.get("frequency_penalty")),
                dbl(row == null ? null : row.get("presence_penalty")),
                row == null ? "" : text(row.get("system_prompt")),
                integer(row == null ? null : row.get("context_window")),
                row != null && truthy(row.get("web_search")),
                row == null ? 5 : intOr(row.get("search_count"), 5),
                row != null && truthy(row.get("search_need_content")),
                row == null || truthy(row.get("stream")),
                row == null || truthy(row.get("thinking")),
                normalizeEffort(row == null ? "" : text(row.get("reasoning_effort"))));
    }

    public Map<String, Object> save(String deviceId, Map<String, Object> body) {
        Map<String, Object> existing = store.findSettings(deviceId);
        String currentKey = existing == null ? "" : text(existing.get("api_key"));
        String submitted = text(body.get("apiKey"));
        // 传 null 或 clearApiKey=true 表示「清除密钥」；脱敏值/空串表示「不修改」
        boolean clear = Boolean.TRUE.equals(body.get("clearApiKey"))
                || (body.containsKey("apiKey") && body.get("apiKey") == null);
        String key = clear ? "" : (submitted.contains("***") || submitted.isBlank() ? currentKey : submitted.trim());
        if (key.length() > 255) {
            throw new ApiException(400, "API Key 过长");
        }

        String baseUrl = normalizeBaseUrl(text(pick(body, existing, "baseUrl", "base_url")));
        String model = normalizeModel(text(pick(body, existing, "model", "model")));
        if (!model.matches("[A-Za-z0-9._:\\-/]{1,64}")) {
            throw new ApiException(400, "模型名不合法（只允许字母、数字和 . _ : / -，最长 64）");
        }
        String systemPrompt = text(pick(body, existing, "systemPrompt", "system_prompt"));
        if (systemPrompt.length() > 20000) {
            throw new ApiException(400, "系统提示词过长（上限 20000 字）");
        }

        Map<String, Object> row = new LinkedHashMap<>();
        row.put("deviceId", deviceId);
        row.put("apiKey", key);
        row.put("baseUrl", baseUrl);
        row.put("model", model);
        row.put("temperature", clampDouble(dbl(pick(body, existing, "temperature", "temperature")), 0.0, 2.0));
        row.put("maxTokens", clampInt(integer(pick(body, existing, "maxTokens", "max_tokens")), 256, 32768));
        row.put("topP", clampDouble(dbl(pick(body, existing, "topP", "top_p")), 0.0, 1.0));
        row.put("frequencyPenalty",
                clampDouble(dbl(pick(body, existing, "frequencyPenalty", "frequency_penalty")), -2.0, 2.0));
        row.put("presencePenalty",
                clampDouble(dbl(pick(body, existing, "presencePenalty", "presence_penalty")), -2.0, 2.0));
        row.put("systemPrompt", systemPrompt);
        row.put("contextWindow", Math.min(2_000_000,
                Math.max(0, intOr(pick(body, existing, "contextWindow", "context_window"), 0))));
        row.put("webSearch", boolPick(body, existing, "webSearch", "web_search"));
        row.put("searchCount", clampInt(intOr(pick(body, existing, "searchCount", "search_count"), 5), 1, 20));
        row.put("searchNeedContent", boolPick(body, existing, "searchNeedContent", "search_need_content"));
        row.put("stream", boolPick(body, existing, "stream", "stream", true));
        row.put("thinking", boolPick(body, existing, "thinking", "thinking", true));
        row.put("reasoningEffort",
                normalizeEffort(text(pick(body, existing, "reasoningEffort", "reasoning_effort"))));
        row.put("now", System.currentTimeMillis());
        store.upsertSettings(row);
        return view(deviceId);
    }

    /**
     * 校验并规范化模型地址：必须是 https，或「本机/内网 + http」的本地代理。
     * 这条链路会带着用户的 API Key 出网，不能让请求体把它指到任意主机。
     */
    private static String normalizeBaseUrl(String raw) {
        if (raw.isBlank()) {
            return "";
        }
        String normalized = OutboundUrlGuard.requireModelBaseUrl(raw).toString();
        while (normalized.endsWith("/")) {
            normalized = normalized.substring(0, normalized.length() - 1);
        }
        if (normalized.length() > 255) {
            throw new ApiException(400, "模型地址过长（上限 255）");
        }
        return normalized;
    }

    private static Double clampDouble(Double value, double min, double max) {
        return value == null ? null : Math.min(max, Math.max(min, value));
    }

    private static Integer clampInt(Integer value, int min, int max) {
        return value == null ? null : Math.min(max, Math.max(min, value));
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
        return boolPick(body, existing, bodyKey, columnKey, false);
    }

    private static boolean boolPick(Map<String, Object> body, Map<String, Object> existing,
                                    String bodyKey, String columnKey, boolean fallback) {
        Object value = body.containsKey(bodyKey)
                ? body.get(bodyKey)
                : (existing == null ? null : existing.get(columnKey));
        return value == null ? fallback : truthy(value);
    }

    /** 界面简称 → 真实 API 标识：Pro 必须带 v4，flash 的两个旧别名统一收敛。 */
    private static String normalizeModel(String model) {
        String value = model == null ? "" : model.trim();
        if (value.isEmpty()) {
            return "deepseek-flash";
        }
        if ("deepseek-pro".equalsIgnoreCase(value)) {
            return "deepseek-v4-pro";
        }
        if ("deepseek-chat".equalsIgnoreCase(value) || "deepseek-v4-flash".equalsIgnoreCase(value)) {
            return "deepseek-flash";
        }
        return value;
    }

    /** 思考深度只接受 none / low / high / max，异常值回落到 high。 */
    private static String normalizeEffort(String effort) {
        String value = effort == null ? "" : effort.trim().toLowerCase();
        return switch (value) {
            case "none", "low", "high", "max" -> value;
            default -> "high";
        };
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
