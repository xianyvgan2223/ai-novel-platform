package com.deepseekapp.webserver.feature.agent.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.runtime.AgentAskRegistry;
import com.deepseekapp.webserver.feature.agent.service.AgentConversationService;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.feature.agent.service.AgentService;
import com.deepseekapp.webserver.feature.agent.service.AgentSettingsService;
import com.deepseekapp.webserver.feature.agent.service.AgentTaskService;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;

/**
 * 网页端右侧 Agent 面板接口。
 *
 * <pre>
 * POST   /api/agent/chat                  SSE：文本增量 + 工具调用/结果 + 任务计划
 * POST   /api/agent/runs/{id}/cancel      中止一次运行
 * GET    /api/agent/tools                 可用工具清单
 * GET    /api/agent/sessions              会话列表
 * POST   /api/agent/sessions              新建会话
 * GET    /api/agent/sessions/{id}         会话详情（消息 + 任务）
 * DELETE /api/agent/sessions/{id}         删除会话
 * GET    /api/agent/settings              模型设置（Key 脱敏）
 * PUT    /api/agent/settings              保存模型设置
 * </pre>
 */
@RestController
@RequestMapping("/api/agent")
public class AgentController {

    private final AgentService agentService;
    private final AgentRunRegistry registry;
    private final AgentToolCatalog toolCatalog;
    private final AgentConversationService conversations;
    private final AgentSettingsService settings;
    private final AgentTaskService tasks;
    private final AgentAskRegistry askRegistry;
    private final AppProperties props;

    public AgentController(AgentService agentService, AgentRunRegistry registry,
                           AgentToolCatalog toolCatalog, AgentConversationService conversations,
                           AgentSettingsService settings, AgentTaskService tasks,
                           AgentAskRegistry askRegistry, AppProperties props) {
        this.agentService = agentService;
        this.registry = registry;
        this.toolCatalog = toolCatalog;
        this.conversations = conversations;
        this.settings = settings;
        this.tasks = tasks;
        this.askRegistry = askRegistry;
        this.props = props;
    }

    @PostMapping("/chat")
    public void chat(@RequestBody(required = false) Map<String, Object> body,
                     HttpServletRequest request,
                     HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String message = str(payload.get("message"));

        OutputStream out = startSse(response);
        if (message.isBlank()) {
            writeEvent(out, AgentEvent.of("error", "error", "消息不能为空"));
            return;
        }

        String deviceId = RequestDevice.deviceId(request, props);
        Long sessionId = longOrNull(payload.get("sessionId"));
        AgentRun run = agentService.start(deviceId, sessionId, message);
        run.attach(out, 0);
    }

    /** 重连：从 after 之后重放事件，并继续跟随运行。 */
    @GetMapping("/runs/{id}/stream")
    public void streamRun(@PathVariable("id") String id,
                          @RequestParam(value = "after", defaultValue = "0") long after,
                          HttpServletRequest request,
                          HttpServletResponse response) throws IOException {
        OutputStream out = startSse(response);
        String deviceId = RequestDevice.deviceId(request, props);
        AgentRun run = registry.get(id);
        if (run == null || !run.deviceId().equals(deviceId)) {
            writeEvent(out, AgentEvent.of("error", "error", "运行不存在或已过期"));
            return;
        }
        run.attach(out, after);
    }

    /** 当前设备（可选某个会话）还没结束的运行，供页面刷新后接管。 */
    @GetMapping("/runs/active")
    public Map<String, Object> activeRuns(@RequestParam(value = "sessionId", required = false) Long sessionId,
                                          HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        List<Map<String, Object>> runs = new ArrayList<>();
        for (AgentRun run : registry.activeFor(deviceId, sessionId == null ? 0 : sessionId)) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("runId", run.id());
            item.put("sessionId", run.sessionId());
            item.put("lastSeq", run.lastSeq());
            item.put("startedAt", run.startedAt());
            runs.add(item);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("runs", runs);
        return Api.ok(data);
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

    /** 回答 Agent 的提问：唤醒等待中的 ask_user 工具，对话继续。 */
    @PostMapping("/asks/{id}/answer")
    public Map<String, Object> answerAsk(@PathVariable("id") String id,
                                         @RequestBody(required = false) Map<String, Object> body) {
        String answer = body == null ? "" : str(body.get("answer"));
        boolean accepted = askRegistry.answer(id, answer);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", id);
        data.put("accepted", accepted);
        return Api.ok(data);
    }

    // ── 会话 ──

    @GetMapping("/sessions")
    public Map<String, Object> sessions(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("sessions", conversations.list(deviceId, 50));
        return Api.ok(data);
    }

    @PostMapping("/sessions")
    public Map<String, Object> createSession(@RequestBody(required = false) Map<String, Object> body,
                                             HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        String title = body == null ? "新对话" : str(body.get("title"));
        return Api.ok(conversations.create(deviceId, title.isBlank() ? "新对话" : title));
    }

    @GetMapping("/sessions/{id}")
    public Map<String, Object> sessionDetail(@PathVariable("id") long id, HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        Map<String, Object> detail = conversations.detail(deviceId, id);
        detail.put("tasks", tasks.list(id));
        return Api.ok(detail);
    }

    @DeleteMapping("/sessions/{id}")
    public Map<String, Object> deleteSession(@PathVariable("id") long id, HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        conversations.delete(deviceId, id);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", id);
        data.put("deleted", true);
        return Api.ok(data);
    }

    // ── 设置 ──

    @GetMapping("/settings")
    public Map<String, Object> settings(HttpServletRequest request) {
        return Api.ok(settings.view(RequestDevice.deviceId(request, props)));
    }

    @PutMapping("/settings")
    public Map<String, Object> saveSettings(@RequestBody(required = false) Map<String, Object> body,
                                            HttpServletRequest request) {
        Map<String, Object> payload = body == null ? Map.of() : body;
        return Api.ok(settings.save(RequestDevice.deviceId(request, props), payload));
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

    private static Long longOrNull(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        try {
            String text = str(value);
            return text.isEmpty() ? null : Long.parseLong(text);
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
