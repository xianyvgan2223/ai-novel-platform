package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Agent 会话与消息的读写。 */
@Service
public class AgentConversationService {

    private static final int TITLE_MAX = 24;

    private final AgentStore store;

    public AgentConversationService(AgentStore store) {
        this.store = store;
    }

    public Map<String, Object> create(String deviceId, String title) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("deviceId", deviceId);
        row.put("title", normalizeTitle(title));
        row.put("now", System.currentTimeMillis());
        store.insertSession(row);
        long id = ((Number) row.get("id")).longValue();
        return view(store.findSession(id, deviceId));
    }

    public List<Map<String, Object>> list(String deviceId, int limit) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> row : store.listSessions(deviceId, Math.max(1, Math.min(limit, 100)))) {
            out.add(view(row));
        }
        return out;
    }

    public Map<String, Object> find(String deviceId, long id) {
        Map<String, Object> row = store.findSession(id, deviceId);
        if (row == null) {
            throw new ApiException(404, "会话不存在");
        }
        return view(row);
    }

    public void delete(String deviceId, long id) {
        store.deleteMessages(id);
        store.deleteTasks(id);
        store.deleteSession(id, deviceId);
    }

    public Map<String, Object> detail(String deviceId, long id) {
        Map<String, Object> session = find(deviceId, id);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("session", session);
        out.put("messages", messages(id));
        return out;
    }

    public List<Map<String, Object>> messages(long sessionId) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> row : store.listMessages(sessionId)) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("id", row.get("id"));
            item.put("role", row.get("role"));
            item.put("content", row.get("content"));
            item.put("parts", parseParts(row.get("parts")));
            item.put("status", row.get("status"));
            item.put("error", row.get("error"));
            item.put("elapsedMs", row.get("elapsed_ms"));
            item.put("createdAt", row.get("created_at"));
            out.add(item);
        }
        return out;
    }

    /** 给模型用的上下文：只取文本，最后 limit 条。 */
    public List<Map<String, String>> history(long sessionId, int limit) {
        List<Map<String, String>> all = new ArrayList<>();
        for (Map<String, Object> row : store.listMessages(sessionId)) {
            String role = text(row.get("role"));
            String content = text(row.get("content"));
            if (content.isBlank() || (!"user".equals(role) && !"assistant".equals(role))) {
                continue;
            }
            if ("error".equals(text(row.get("status")))) {
                continue;
            }
            Map<String, String> item = new LinkedHashMap<>();
            item.put("role", role);
            item.put("content", content);
            all.add(item);
        }
        int from = Math.max(0, all.size() - Math.max(1, limit));
        return all.subList(from, all.size());
    }

    public void appendUser(String deviceId, long sessionId, String textValue) {
        Map<String, Object> row = messageRow(deviceId, sessionId, "user", textValue, "done", null, null);
        List<Map<String, Object>> parts = new ArrayList<>();
        Map<String, Object> part = new LinkedHashMap<>();
        part.put("kind", "text");
        part.put("text", textValue);
        parts.add(part);
        row.put("parts", Json.write(parts));
        store.insertMessage(row);
        store.touchSession(sessionId, deviceId, System.currentTimeMillis());
    }

    public void appendAssistant(String deviceId, long sessionId, String content, String partsJson,
                                String status, String error, Long elapsedMs) {
        Map<String, Object> row = messageRow(deviceId, sessionId, "assistant", content, status, error, elapsedMs);
        row.put("parts", partsJson == null || partsJson.isBlank() ? "[]" : partsJson);
        store.insertMessage(row);
        store.touchSession(sessionId, deviceId, System.currentTimeMillis());
    }

    /** 首条用户消息自动作为会话标题。 */
    public void ensureTitle(String deviceId, long sessionId, String text) {
        Map<String, Object> session = store.findSession(sessionId, deviceId);
        if (session == null || !text(session.get("title")).isBlank()) {
            return;
        }
        store.renameSession(sessionId, deviceId, normalizeTitle(text), System.currentTimeMillis());
    }

    public String titleOf(String deviceId, long sessionId) {
        Map<String, Object> session = store.findSession(sessionId, deviceId);
        return session == null ? "" : text(session.get("title"));
    }

    private Map<String, Object> messageRow(String deviceId, long sessionId, String role, String content,
                                           String status, String error, Long elapsedMs) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("sessionId", sessionId);
        row.put("deviceId", deviceId);
        row.put("role", role);
        row.put("content", content == null ? "" : content);
        row.put("status", status);
        row.put("error", error);
        row.put("elapsedMs", elapsedMs);
        row.put("now", System.currentTimeMillis());
        return row;
    }

    private static Map<String, Object> view(Map<String, Object> row) {
        if (row == null) {
            return null;
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", row.get("id"));
        out.put("title", row.get("title"));
        out.put("messageCount", row.get("message_count"));
        out.put("createdAt", row.get("created_at"));
        out.put("updatedAt", row.get("updated_at"));
        return out;
    }

    @SuppressWarnings("unchecked")
    private static List<Map<String, Object>> parseParts(Object raw) {
        if (raw == null || String.valueOf(raw).isBlank()) {
            return List.of();
        }
        try {
            Object parsed = Json.parse(String.valueOf(raw));
            return parsed instanceof List<?> list ? (List<Map<String, Object>>) list : List.of();
        } catch (RuntimeException e) {
            return List.of();
        }
    }

    private static String normalizeTitle(String title) {
        String value = title == null ? "" : title.trim().replaceAll("\\s+", " ");
        if (value.isEmpty()) {
            return "新对话";
        }
        return value.length() > TITLE_MAX ? value.substring(0, TITLE_MAX) + "…" : value;
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }
}
