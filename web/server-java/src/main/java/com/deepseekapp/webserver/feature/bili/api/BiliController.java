package com.deepseekapp.webserver.feature.bili.api;

import com.deepseekapp.webserver.feature.bili.service.BiliSettingsService;
import com.deepseekapp.webserver.feature.bili.service.BiliTranscriptService;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 网页端「B站视频转文字」接口。
 *
 * <p>POST /api/bili/resolve 解析视频信息；
 * POST /api/bili/extract SSE 流式提取（优先官方字幕，兜底本地转写）；
 * GET/PUT /api/bili/settings 读写 SESSDATA 登录态配置。</p>
 */
@RestController
@RequestMapping("/api/bili")
public class BiliController {

    private final BiliTranscriptService service;
    private final BiliSettingsService settingsService;

    public BiliController(BiliTranscriptService service, BiliSettingsService settingsService) {
        this.service = service;
        this.settingsService = settingsService;
    }

    @PostMapping("/resolve")
    public Map<String, Object> resolve(@RequestBody(required = false) Map<String, Object> body) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String input = String.valueOf(payload.getOrDefault("input", "")).trim();
        if (input.isEmpty()) {
            throw new ApiException(400, "请先粘贴B站视频链接或 BV 号");
        }
        return Api.ok(service.resolve(input));
    }

    @PostMapping("/subtitles")
    public Map<String, Object> subtitles(@RequestBody(required = false) Map<String, Object> body) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        long aid = longOf(payload.get("aid"));
        long cid = longOf(payload.get("cid"));
        if (aid <= 0 || cid <= 0) {
            throw new ApiException(400, "缺少 aid / cid 参数");
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("subtitles", service.subtitles(aid, cid));
        return Api.ok(data);
    }

    /** SSE：优先官方字幕（逐条 delta），无字幕走下载音频 + faster-whisper 本地转写 */
    @PostMapping("/extract")
    public void extract(@RequestBody(required = false) Map<String, Object> body,
                        HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;

        // 这些错误发生在开始写流之前，交给统一异常处理返回普通 JSON
        long aid = longOf(payload.get("aid"));
        long cid = longOf(payload.get("cid"));
        if (aid <= 0 || cid <= 0) {
            throw new ApiException(400, "缺少 aid / cid 参数");
        }
        if ("asr".equals(String.valueOf(payload.getOrDefault("mode", "auto")))) {
            // 显式要求本地转写时，提前把环境问题报成 JSON
            service.requireWhisper();
        }

        response.setContentType("text/event-stream;charset=UTF-8");
        response.setHeader("Cache-Control", "no-cache, no-transform");
        response.setHeader("Connection", "keep-alive");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();

        OutputStream out = response.getOutputStream();
        long startedAt = System.currentTimeMillis();

        try {
            Map<String, Object> stats = service.streamExtract(payload,
                    new BiliTranscriptService.EventSink() {
                        @Override
                        public void stage(int index, int total, String label) throws IOException {
                            Map<String, Object> event = new LinkedHashMap<>();
                            event.put("type", "stage");
                            event.put("index", index);
                            event.put("total", total);
                            event.put("label", label);
                            writeEvent(out, event);
                        }

                        @Override
                        public void progress(Integer percent, String text) throws IOException {
                            Map<String, Object> event = new LinkedHashMap<>();
                            event.put("type", "progress");
                            if (percent != null) {
                                event.put("percent", percent);
                            }
                            event.put("text", text);
                            writeEvent(out, event);
                        }

                        @Override
                        public void delta(String text) throws IOException {
                            Map<String, Object> event = new LinkedHashMap<>();
                            event.put("type", "delta");
                            event.put("text", text);
                            writeEvent(out, event);
                        }
                    });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("source", stats.get("source"));
            done.put("chars", stats.get("chars"));
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException e) {
            // 浏览器中途断开：停止上游，不再写任何内容
        } catch (Exception e) {
            safeWriteError(out, e.getMessage() == null ? "提取失败" : e.getMessage());
        }
    }

    @GetMapping("/settings")
    public Map<String, Object> settings() {
        return Api.ok(settingsService.info());
    }

    @PutMapping("/settings")
    public Map<String, Object> saveSettings(@RequestBody(required = false) Map<String, Object> body) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String sessdata = String.valueOf(payload.getOrDefault("sessdata", "")).trim();
        return Api.ok(settingsService.save(sessdata));
    }

    private static long longOf(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        try {
            return Long.parseLong(String.valueOf(value).trim());
        } catch (Exception e) {
            return 0;
        }
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
