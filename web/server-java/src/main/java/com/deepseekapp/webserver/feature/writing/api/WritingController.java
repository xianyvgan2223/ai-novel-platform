package com.deepseekapp.webserver.feature.writing.api;

import com.deepseekapp.webserver.feature.writing.service.WritingService;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 网页端「写作优化」接口。
 *
 * <p>POST /api/writing/optimize 流式返回改写结果（SSE）；
 * POST /api/writing/draw 抽卡，返回结构化卡片。</p>
 */
@RestController
@RequestMapping("/api/writing")
public class WritingController {

    /** 单次最多处理的原文字数 */
    private static final int MAX_TEXT_CHARS = 20000;

    private final WritingService service;

    public WritingController(WritingService service) {
        this.service = service;
    }

    @PostMapping("/optimize")
    public void optimize(@RequestBody(required = false) Map<String, Object> body,
                         HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String text = String.valueOf(payload.getOrDefault("text", ""));
        List<String> actions = service.actionsOf(payload);

        // 这些错误发生在开始写流之前，交给统一异常处理返回普通 JSON
        if (text.trim().isEmpty()) {
            throw new ApiException(400, "请先填写要优化的文稿");
        }
        if (actions.isEmpty()) {
            throw new ApiException(400, "请至少选择一个优化动作");
        }
        if (text.length() > MAX_TEXT_CHARS) {
            throw new ApiException(400, "文稿过长（" + text.length() + " 字），单次最多 " + MAX_TEXT_CHARS + " 字");
        }
        service.requireConfig();

        response.setContentType("text/event-stream;charset=UTF-8");
        response.setHeader("Cache-Control", "no-cache, no-transform");
        response.setHeader("Connection", "keep-alive");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();

        OutputStream out = response.getOutputStream();
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();

        try {
            service.streamOptimize(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException e) {
            // 浏览器中途断开：停止读取上游，不再写任何内容
        } catch (Exception e) {
            safeWriteError(out, e.getMessage() == null ? "AI 生成失败" : e.getMessage());
        }
    }

    @PostMapping("/draw")
    public Map<String, Object> draw(@RequestBody(required = false) Map<String, Object> body) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String kind = "outline".equals(String.valueOf(payload.get("kind"))) ? "outline" : "short";

        List<Map<String, Object>> cards = service.drawCards(payload);

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("kind", kind);
        data.put("cards", cards);
        return Api.ok(data);
    }

    private void writeEvent(OutputStream out, Map<String, Object> event) throws IOException {
        out.write(("data: " + Json.write(event) + "\n\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private void safeWriteError(OutputStream out, String message) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", "error");
        event.put("error", message);
        try {
            writeEvent(out, event);
        } catch (IOException ignored) {
            // 连接已经断开，无法再告知前端
        }
    }
}
