package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.context.AgentHistory;
import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Agent 会话与消息的读写。 */
@Service
public class AgentConversationService {

    private static final int TITLE_MAX = 24;
    /** 单条用户消息上限，防止整章正文直接灌进上下文。 */
    private static final int MAX_MESSAGE_CHARS = 20000;

    private final AgentStore store;
    private final AgentRunRegistry registry;
    private final AppProperties props;

    public AgentConversationService(AgentStore store, AgentRunRegistry registry, AppProperties props) {
        this.store = store;
        this.registry = registry;
        this.props = props;
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

    /**
     * 删除会话及其消息、任务与运行日志。
     *
     * <p>先按设备校验归属：sessionId 是全局自增的，缺这步就能用别的 id 清空他人数据。
     * 正在生成的会话不允许删除，避免运行结束后往已删会话里补写孤儿消息。</p>
     */
    @Transactional
    public void delete(String deviceId, long id) {
        find(deviceId, id);
        if (!registry.activeFor(deviceId, id).isEmpty()) {
            throw new ApiException(409, "该会话还有正在生成的回复，请先停止再删除");
        }
        store.deleteMessages(id, deviceId);
        store.deleteTasks(id, deviceId);
        store.deleteRuns(id, deviceId);
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
            item.put("promptTokens", row.get("prompt_tokens"));
            item.put("completionTokens", row.get("completion_tokens"));
            item.put("cachedTokens", row.get("cached_tokens"));
            item.put("createdAt", row.get("created_at"));
            out.add(item);
        }
        return out;
    }

    /**
     * 给模型用的历史：摘要之后的消息（最近 N 条，按需由 {@code AgentContextService} 压缩）。
     *
     * <p>不再按固定条数/字符截断，否则压缩永远不会触发；只在字符数超过兜底上限时
     * 从最旧的开始丢弃（正常路径由 token 压缩处理）。</p>
     */
    public AgentHistory history(String deviceId, long sessionId) {
        Map<String, Object> session = store.findSession(sessionId, deviceId);
        String summary = session == null ? "" : text(session.get("summary"));
        long upto = session == null ? 0 : number(session.get("summary_upto"));

        int limit = Math.max(1, props.getAgentHistoryMessages());
        List<Map<String, Object>> rows = new ArrayList<>(store.listMessagesAfter(sessionId, upto, limit));
        Collections.reverse(rows);

        List<AgentHistory.Message> messages = new ArrayList<>();
        int chars = 0;
        for (Map<String, Object> row : rows) {
            String role = text(row.get("role"));
            String content = text(row.get("content"));
            if (content.isBlank() || (!"user".equals(role) && !"assistant".equals(role))) {
                continue;
            }
            if ("error".equals(text(row.get("status")))) {
                continue;
            }
            messages.add(new AgentHistory.Message(number(row.get("id")), role, content));
            chars += content.length();
        }
        int maxChars = Math.max(2000, props.getAgentHistoryMaxChars());
        while (chars > maxChars && messages.size() > 1) {
            chars -= messages.getFirst().content().length();
            messages.removeFirst();
        }
        return new AgentHistory(summary, upto, messages);
    }

    /** 上次请求的精确上下文占用（prompt_tokens）；没测到过就是 0。 */
    public long contextTokens(String deviceId, long sessionId) {
        Map<String, Object> session = store.findSession(sessionId, deviceId);
        return session == null ? 0 : number(session.get("context_tokens"));
    }

    /** 上次请求命中的缓存 token 数（用于面板展示缓存命中率）。 */
    public long contextCachedTokens(String deviceId, long sessionId) {
        Map<String, Object> session = store.findSession(sessionId, deviceId);
        return session == null ? 0 : number(session.get("context_cached_tokens"));
    }

    /** 会话累计用量：Σ 所有请求的 prompt / cache hit。 */
    public record UsageTotals(long promptTokens, long cachedTokens) {
        public int cachePercent() {
            if (promptTokens <= 0) {
                return 0;
            }
            return (int) Math.round(cachedTokens * 100.0 / promptTokens);
        }
    }

    public UsageTotals usageTotals(String deviceId, long sessionId) {
        Map<String, Object> row = store.usageTotals(sessionId, deviceId);
        if (row == null) {
            return new UsageTotals(0, 0);
        }
        return new UsageTotals(number(row.get("prompt")), number(row.get("cached")));
    }

    public void saveSummary(String deviceId, long sessionId, String summary, long upto) {
        store.updateSummary(sessionId, deviceId, summary, upto, System.currentTimeMillis());
    }

    public void saveContextTokens(String deviceId, long sessionId, long tokens) {
        saveContextTokens(deviceId, sessionId, tokens, 0);
    }

    public void saveContextTokens(String deviceId, long sessionId, long tokens, long cachedTokens) {
        store.updateContextTokens(sessionId, deviceId, tokens, cachedTokens);
    }

    public void appendUser(String deviceId, long sessionId, String textValue) {
        if (textValue != null && textValue.length() > MAX_MESSAGE_CHARS) {
            throw new ApiException(413, "单条消息过长（上限 " + MAX_MESSAGE_CHARS + " 字），请分段发送");
        }
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
                                String status, String error, Long elapsedMs, String runId) {
        appendAssistant(deviceId, sessionId, content, partsJson, status, error, elapsedMs, runId, null, null, null);
    }

    public void appendAssistant(String deviceId, long sessionId, String content, String partsJson,
                                String status, String error, Long elapsedMs, String runId,
                                Integer promptTokens, Integer completionTokens) {
        appendAssistant(deviceId, sessionId, content, partsJson, status, error, elapsedMs, runId,
                promptTokens, completionTokens, null);
    }

    public void appendAssistant(String deviceId, long sessionId, String content, String partsJson,
                                String status, String error, Long elapsedMs, String runId,
                                Integer promptTokens, Integer completionTokens, Integer cachedTokens) {
        Map<String, Object> row = messageRow(deviceId, sessionId, "assistant", content, status, error, elapsedMs);
        row.put("parts", partsJson == null || partsJson.isBlank() ? "[]" : partsJson);
        row.put("runId", runId);
        row.put("promptTokens", promptTokens);
        row.put("completionTokens", completionTokens);
        row.put("cachedTokens", cachedTokens);
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
        row.put("runId", null);
        row.put("promptTokens", null);
        row.put("completionTokens", null);
        row.put("cachedTokens", null);
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
        out.put("contextTokens", row.get("context_tokens"));
        out.put("contextCachedTokens", row.get("context_cached_tokens"));
        out.put("totalPromptTokens", row.get("total_prompt_tokens"));
        out.put("totalCachedTokens", row.get("total_cached_tokens"));
        out.put("hasSummary", text(row.get("summary")).length() > 0);
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

    private static long number(Object value) {
        return value instanceof Number n ? n.longValue() : 0L;
    }
}
