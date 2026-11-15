package com.deepseekapp.webserver.feature.writing.api;

import com.deepseekapp.webserver.feature.writing.service.OutlineStageService;
import com.deepseekapp.webserver.feature.writing.service.WritingService;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * 网页端「一键生成大纲」分阶段接口（与移动端流程对齐）。
 *
 * <pre>
 * POST /api/writing/novel/outline/stages/concept   定调：书名 + 核心概念
 * POST /api/writing/novel/outline/stages/skeleton  粗骨架：三幕 + 大事件标题/定位
 * POST /api/writing/novel/outline/stages/events    分批精写大事件 + 伏笔账本
 * POST /api/writing/novel/outline/stages/minor     按块展开小事件
 * </pre>
 *
 * 每个阶段独立返回 SSE；前端在阶段之间暂停，实现「粗骨架 / 大事件 / 小事件」检查点。
 */
@RestController
@RequestMapping("/api/writing/novel/outline/stages")
public class OutlineStageController {

    private final WritingService writingService;
    private final OutlineStageService stageService;

    public OutlineStageController(WritingService writingService, OutlineStageService stageService) {
        this.writingService = writingService;
        this.stageService = stageService;
    }

    @PostMapping("/concept")
    public void concept(@RequestBody(required = false) Map<String, Object> body,
                        HttpServletResponse response) throws IOException {
        run(body, response, stageService::concept);
    }

    @PostMapping("/skeleton")
    public void skeleton(@RequestBody(required = false) Map<String, Object> body,
                         HttpServletResponse response) throws IOException {
        run(body, response, stageService::skeleton);
    }

    @PostMapping("/events")
    public void events(@RequestBody(required = false) Map<String, Object> body,
                       HttpServletResponse response) throws IOException {
        run(body, response, stageService::events);
    }

    @PostMapping("/minor")
    public void minor(@RequestBody(required = false) Map<String, Object> body,
                      HttpServletResponse response) throws IOException {
        run(body, response, stageService::minor);
    }

    @FunctionalInterface
    private interface StageCall {
        Map<String, Object> call(Map<String, Object> body, OutlineStageService.Sink sink) throws IOException;
    }

    private void run(Map<String, Object> body, HttpServletResponse response, StageCall call) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        try {
            Map<String, Object> result = call.call(payload, new OutlineStageService.Sink() {
                @Override
                public void stage(int index, int total, String label) throws IOException {
                    writeEvent(out, Map.of(
                            "type", "stage",
                            "index", index,
                            "total", total,
                            "label", label
                    ));
                }

                @Override
                public void delta(String text) throws IOException {
                    writeEvent(out, Map.of("type", "delta", "text", text));
                }
            });

            Map<String, Object> event = new java.util.LinkedHashMap<>();
            event.put("type", "result");
            event.put("data", result);
            writeEvent(out, event);
            writeEvent(out, Map.of("type", "done"));
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            String message = e.getMessage() == null ? "大纲生成失败" : e.getMessage();
            writeEvent(out, Map.of("type", "error", "error", message));
        }
    }

    private static OutputStream startSse(HttpServletResponse response) throws IOException {
        response.setContentType("text/event-stream;charset=UTF-8");
        response.setHeader("Cache-Control", "no-cache, no-transform");
        response.setHeader("Connection", "keep-alive");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();
        return response.getOutputStream();
    }

    private static void writeEvent(OutputStream out, Map<String, Object> event) throws IOException {
        out.write(("data: " + Json.write(event) + "\n\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }
}
