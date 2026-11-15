package com.deepseekapp.webserver.feature.agent.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.service.AgentEvent;
import com.deepseekapp.webserver.feature.agent.service.AgentRunRegistry;
import com.deepseekapp.webserver.feature.agent.service.AgentService;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 网页端右侧 Agent 面板接口。
 *
 * <pre>
 * POST /api/agent/chat                  SSE：文本增量 + 工具调用/结果 + 阶段进度
 * POST /api/agent/runs/{id}/cancel      中止一次运行（真正停掉 LLM 流与工具）
 * GET  /api/agent/tools                 可用工具清单（面板空状态展示）
 * </pre>
 */
@RestController
@RequestMapping("/api/agent")
public class AgentController {

    private final AgentService agentService;
    private final AgentRunRegistry registry;
    private final AgentToolCatalog toolCatalog;
    private final AppProperties props;

    public AgentController(AgentService agentService, AgentRunRegistry registry,
                           AgentToolCatalog toolCatalog, AppProperties props) {
        this.agentService = agentService;
        this.registry = registry;
        this.toolCatalog = toolCatalog;
        this.props = props;
    }

    @PostMapping("/chat")
    public void chat(@RequestBody(required = false) Map<String, Object> body,
                     HttpServletRequest request,
                     HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String message = str(payload.get("message"));
        List<Map<String, String>> history = history(payload.get("history"));

        OutputStream out = startSse(response);
        if (message.isBlank()) {
            writeEvent(out, AgentEvent.of("error", "error", "消息不能为空"));
            return;
        }

        String deviceId = RequestDevice.deviceId(request, props);
        agentService.chat(deviceId, history, message, out);
    }

    @PostMapping("/runs/{id}/cancel")
    public Map<String, Object> cancel(@PathVariable("id") String id) {
        boolean cancelled = registry.cancel(id);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("runId", id);
        data.put("cancelled", cancelled);
        return Api.ok(data);
    }

    @GetMapping("/tools")
    public Map<String, Object> tools() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("tools", toolCatalog.describe());
        return Api.ok(data);
    }

    // ── SSE / 参数解析 ──

    private OutputStream startSse(HttpServletResponse response) throws IOException {
        response.setContentType("text/event-stream;charset=UTF-8");
        response.setHeader("Cache-Control", "no-cache, no-transform");
        response.setHeader("Connection", "keep-alive");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();
        return response.getOutputStream();
    }

    private void writeEvent(OutputStream out, Map<String, Object> event) throws IOException {
        out.write(("data: " + Json.write(event) + "\n\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }

    @SuppressWarnings("unchecked")
    private static List<Map<String, String>> history(Object value) {
        if (!(value instanceof List<?> list)) {
            return List.of();
        }
        List<Map<String, String>> out = new ArrayList<>();
        for (Object item : list) {
            if (!(item instanceof Map<?, ?> map)) {
                continue;
            }
            Map<?, ?> raw = map;
            String content = raw.get("content") == null ? "" : String.valueOf(raw.get("content"));
            if (content.isBlank()) {
                continue;
            }
            String role = raw.get("role") == null ? "user" : String.valueOf(raw.get("role"));
            Map<String, String> entry = new LinkedHashMap<>();
            entry.put("role", "assistant".equals(role) ? "assistant" : "user");
            entry.put("content", content);
            out.add(entry);
        }
        return out;
    }
}
