package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.feature.agent.runtime.AgentCancelledException;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

/**
 * 所有 Agent 工具的公共支撑：调用追踪、返回体积兜底、参数校验与小工具方法。
 *
 * <p>工具实现类只关心「怎么查/怎么生成」，事件怎么写、怎么截断都放在这里，
 * 避免每个工具重复一遍 trace 逻辑。</p>
 */
@Component
public class AgentToolSupport {

    /** 与 AgentService 约定：ToolContext 里存放当前 runId 的 key。 */
    public static final String RUN_ID_KEY = "runId";
    public static final String SESSION_ID_KEY = "sessionId";
    public static final String DEVICE_ID_KEY = "deviceId";

    public static final int MAX_PAGE_SIZE = 50;

    private static final int MAX_TEXT_CHARS = 300;
    private static final int MAX_PAYLOAD_CHARS = 8000;

    private final AgentRunRegistry registry;
    private final SchemaCatalog schema;
    private final AtomicLong sequence = new AtomicLong();

    public AgentToolSupport(AgentRunRegistry registry, SchemaCatalog schema) {
        this.registry = registry;
        this.schema = schema;
    }

    /** 从 ToolContext 取出本次运行；取不到时返回 null，工具仍可执行但没有 trace 事件。 */
    public AgentRun runOf(ToolContext context) {
        if (context == null) {
            return null;
        }
        try {
            Object value = context.getContext().get(RUN_ID_KEY);
            return value == null ? null : registry.get(String.valueOf(value));
        } catch (RuntimeException e) {
            return null;
        }
    }

    public void requireRun(AgentRun run) {
        if (run == null) {
            throw new ApiException(400, "当前对话没有绑定设备，无法读取数据");
        }
    }

    /** 当前会话 id；没有会话时返回 0（工具可自行决定是否报错）。 */
    public long sessionOf(ToolContext context) {
        Object value = contextValue(context, SESSION_ID_KEY);
        if (value instanceof Number n) {
            return n.longValue();
        }
        return number(value);
    }

    public String deviceOf(ToolContext context) {
        Object value = contextValue(context, DEVICE_ID_KEY);
        return value == null ? "" : String.valueOf(value);
    }

    private static Object contextValue(ToolContext context, String key) {
        if (context == null) {
            return null;
        }
        try {
            return context.getContext().get(key);
        } catch (RuntimeException e) {
            return null;
        }
    }

    public void requireTable(String db, String table) {
        if (db == null || db.isBlank()) {
            throw new ApiException(400, "缺少数据库名，可选：deepseek / novel");
        }
        if (!schema.hasDatabase(db)) {
            throw new ApiException(400, "未知的数据库：" + db);
        }
        if (table == null || table.isBlank()) {
            throw new ApiException(400, "缺少表名");
        }
        if (!schema.hasTable(db, table)) {
            throw new ApiException(400, "未知的表：" + table + "，可先用 get_overview 查看全部表名");
        }
    }

    /** 统一的调用追踪：进入时推 tool_call，结束时推 tool_result / tool_error。 */
    public <T> T traced(AgentRun run, String tool, Map<String, Object> args, Supplier<T> body) {
        String callId = "call_" + sequence.incrementAndGet();
        long startedAt = System.currentTimeMillis();
        if (run != null) {
            run.emit(AgentEvent.of("tool_call",
                    "id", callId, "name", tool, "args", args, "startedAt", startedAt));
        }
        try {
            if (run != null) {
                run.checkCancelled();
            }
            T result = body.get();
            if (run != null) {
                run.emit(AgentEvent.of("tool_result",
                        "id", callId,
                        "name", tool,
                        "ok", true,
                        "summary", summarize(tool, result),
                        "data", limited(result),
                        "elapsedMs", System.currentTimeMillis() - startedAt));
            }
            return result;
        } catch (AgentCancelledException e) {
            throw e;
        } catch (RuntimeException e) {
            if (run != null) {
                run.emit(AgentEvent.of("tool_error",
                        "id", callId,
                        "name", tool,
                        "error", message(e),
                        "elapsedMs", System.currentTimeMillis() - startedAt));
            }
            throw e;
        }
    }

    private static String summarize(String tool, Object result) {
        Map<String, Object> map = Json.asMap(result);
        if (map == null) {
            return tool + " 执行完成";
        }
        return switch (tool) {
            case "list_data" -> "表 " + map.get("table") + " 共 " + map.get("total") + " 行，本页 "
                    + (map.get("rows") instanceof List<?> list ? list.size() : 0) + " 行";
            case "search_rag" -> "命中 " + map.getOrDefault("count", 0) + " 条素材";
            case "rag_status" -> "素材库共 " + map.getOrDefault("totalScenes", 0) + " 条情节";
            case "generate_outline" -> "大纲已生成（未保存）";
            case "list_outlines" -> "共 " + map.getOrDefault("count", 0) + " 条大纲";
            case "generate_chapter" -> "正文已生成，共 " + map.getOrDefault("chars", 0) + " 字（未保存）";
            default -> tool + " 执行完成";
        };
    }

    /** 工具返回给前端展示的内容做体积兜底，避免一次把整章正文塞进事件流。 */
    private static Object limited(Object result) {
        try {
            String json = Json.write(result);
            if (json.length() <= MAX_PAYLOAD_CHARS) {
                return result;
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("truncated", true);
            out.put("note", "返回内容过长，仅展示前 " + MAX_PAYLOAD_CHARS + " 个字符");
            out.put("preview", json.substring(0, MAX_PAYLOAD_CHARS));
            return out;
        } catch (RuntimeException e) {
            return result;
        }
    }

    public static List<Map<String, Object>> trimRows(List<Map<String, Object>> rows) {
        List<Map<String, Object>> out = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            out.add(trimRow(row));
        }
        return out;
    }

    private static Map<String, Object> trimRow(Map<String, Object> row) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<String, Object> entry : row.entrySet()) {
            Object value = entry.getValue();
            if (value instanceof String text && text.length() > MAX_TEXT_CHARS) {
                out.put(entry.getKey(), text.substring(0, MAX_TEXT_CHARS) + "…");
            } else {
                out.put(entry.getKey(), value);
            }
        }
        return out;
    }

    public static long number(Object value) {
        return value instanceof Number n ? n.longValue() : 0L;
    }

    public static int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }

    public static String blankTo(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value.trim();
    }

    public static String message(Throwable e) {
        String text = e.getMessage();
        return text == null || text.isBlank() ? e.getClass().getSimpleName() : text;
    }
}
