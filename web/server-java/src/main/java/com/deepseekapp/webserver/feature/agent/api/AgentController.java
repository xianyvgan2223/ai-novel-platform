package com.deepseekapp.webserver.feature.agent.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.context.AgentContextService;
import com.deepseekapp.webserver.feature.agent.context.ContextBudget;
import com.deepseekapp.webserver.feature.agent.runtime.AgentAskRegistry;
import com.deepseekapp.webserver.feature.agent.service.AgentConversationService;
import com.deepseekapp.webserver.feature.agent.service.AgentDownloadService;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRunRegistry;
import com.deepseekapp.webserver.feature.agent.service.AgentLlmClient;
import com.deepseekapp.webserver.feature.agent.service.AgentOptions;
import com.deepseekapp.webserver.feature.agent.service.AgentPromptFactory;
import com.deepseekapp.webserver.feature.agent.service.AgentService;
import com.deepseekapp.webserver.feature.agent.service.AgentSettingsService;
import com.deepseekapp.webserver.feature.agent.service.AgentTaskService;
import com.deepseekapp.webserver.feature.agent.tool.AgentToolCatalog;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
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
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
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

    /** 单条消息上限，与 AgentConversationService 保持一致。 */
    private static final int MAX_MESSAGE_CHARS = 20000;
    private static final int MAX_ANSWER_CHARS = 2000;

    private final AgentService agentService;
    private final AgentRunRegistry registry;
    private final AgentToolCatalog toolCatalog;
    private final AgentConversationService conversations;
    private final AgentSettingsService settings;
    private final AgentTaskService tasks;
    private final AgentAskRegistry askRegistry;
    private final AgentDownloadService downloads;
    private final AgentContextService contextService;
    private final AppProperties props;

    public AgentController(AgentService agentService, AgentRunRegistry registry,
                           AgentToolCatalog toolCatalog, AgentConversationService conversations,
                           AgentSettingsService settings, AgentTaskService tasks,
                           AgentAskRegistry askRegistry, AgentDownloadService downloads,
                           AgentContextService contextService,
                           AppProperties props) {
        this.agentService = agentService;
        this.registry = registry;
        this.toolCatalog = toolCatalog;
        this.conversations = conversations;
        this.settings = settings;
        this.tasks = tasks;
        this.askRegistry = askRegistry;
        this.downloads = downloads;
        this.contextService = contextService;
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
        if (message.length() > MAX_MESSAGE_CHARS) {
            writeEvent(out, AgentEvent.of("error", "error",
                    "消息过长（上限 " + MAX_MESSAGE_CHARS + " 字），请分段发送"));
            return;
        }

        String deviceId = RequestDevice.deviceId(request, props);
        Long sessionId = longOrNull(payload.get("sessionId"));
        AgentRun run;
        try {
            run = agentService.start(deviceId, sessionId, message);
        } catch (ApiException e) {
            // 单飞/并发上限等拒绝原因也要走 SSE，避免响应头已提交后再抛成 500 页面
            writeEvent(out, AgentEvent.of("error", "error", e.getMessage()));
            return;
        } catch (RuntimeException e) {
            writeEvent(out, AgentEvent.of("error", "error", "启动对话失败，请稍后重试"));
            return;
        }
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
    public Map<String, Object> cancel(@PathVariable("id") String id, HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        AgentRun run = registry.get(id);
        // 只有本设备的运行才能取消；不存在/不属于本设备都返回 cancelled=false，不暴露归属
        boolean cancelled = run != null && run.deviceId().equals(deviceId) && registry.cancel(id);
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
                                         @RequestBody(required = false) Map<String, Object> body,
                                         HttpServletRequest request) {
        String answer = body == null ? "" : str(body.get("answer"));
        if (answer.length() > MAX_ANSWER_CHARS) {
            throw new ApiException(400, "回答过长（上限 " + MAX_ANSWER_CHARS + " 字）");
        }
        String deviceId = RequestDevice.deviceId(request, props);
        boolean accepted = askRegistry.answer(id, deviceId, answer);
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
        AgentOptions options = settings.resolve(deviceId);
        ContextBudget budget = contextService.budget(options);
        long tokens = conversations.contextTokens(deviceId, id);
        long cached = conversations.contextCachedTokens(deviceId, id);
        AgentConversationService.UsageTotals totals = conversations.usageTotals(deviceId, id);
        Map<String, Object> context = new LinkedHashMap<>();
        context.put("tokens", tokens);
        context.put("cachedTokens", cached);
        context.put("cachePercent", tokens > 0 ? (int) Math.round(cached * 100.0 / tokens) : 0);
        context.put("totalPromptTokens", totals.promptTokens());
        context.put("totalCachedTokens", totals.cachedTokens());
        context.put("totalCachePercent", totals.cachePercent());
        context.put("window", budget.window());
        context.put("threshold", budget.threshold());
        context.put("percent", budget.percent((int) Math.min(Integer.MAX_VALUE, tokens)));
        detail.put("context", context);
        return Api.ok(detail);
    }

    /** 手动压缩当前会话的历史（对应 DSH 的 /compact）。 */
    @PostMapping("/sessions/{id}/compact")
    public Map<String, Object> compactSession(@PathVariable("id") long id, HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        conversations.find(deviceId, id);
        if (!registry.activeFor(deviceId, id).isEmpty()) {
            throw new ApiException(409, "该会话正在生成回复，请先停止再压缩");
        }
        AgentOptions options = settings.resolve(deviceId);
        int toolTokens = AgentLlmClient.estimateToolTokens(toolCatalog.toolObjects(options.webSearch()));
        return Api.ok(contextService.compactNow(deviceId, id, options,
                AgentPromptFactory.systemPrompt(options, deviceId), toolTokens));
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

    // ── 下载库 ──

    @GetMapping("/downloads")
    public Map<String, Object> listDownloads(HttpServletRequest request) {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("downloads", downloads.list(RequestDevice.deviceId(request, props)));
        return Api.ok(data);
    }

    @DeleteMapping("/downloads/{id}")
    public Map<String, Object> deleteDownload(@PathVariable("id") long id, HttpServletRequest request) {
        downloads.delete(RequestDevice.deviceId(request, props), id);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", id);
        data.put("deleted", true);
        return Api.ok(data);
    }

    /** 把下载库里的文件发回浏览器。 */
    @GetMapping("/downloads/{id}/file")
    public void downloadFile(@PathVariable("id") long id, HttpServletRequest request,
                             HttpServletResponse response) throws IOException {
        String deviceId = RequestDevice.deviceId(request, props);
        Map<String, Object> record = downloads.find(deviceId, id);
        Path file = downloads.resolveFile(deviceId, id);
        String filename = String.valueOf(record.getOrDefault("filename", "download.bin"));
        String mime = String.valueOf(record.getOrDefault("mime", "application/octet-stream"));
        response.setContentType(mime.isBlank() ? "application/octet-stream" : mime);
        response.setContentLengthLong(Files.size(file));
        response.setHeader("Content-Disposition",
                "attachment; filename*=UTF-8''" + URLEncoder.encode(filename, StandardCharsets.UTF_8));
        Files.copy(file, response.getOutputStream());
        response.flushBuffer();
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
