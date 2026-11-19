package com.deepseekapp.webserver.feature.bili.api;

import com.deepseekapp.webserver.feature.bili.service.BiliSettingsService;
import com.deepseekapp.webserver.feature.bili.service.BiliTranscriptService;
import com.deepseekapp.webserver.feature.bili.service.BiliTranscriptStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
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

    private static final Logger log = LoggerFactory.getLogger(BiliController.class);

    private final BiliTranscriptService service;
    private final BiliSettingsService settingsService;
    private final BiliTranscriptStore transcriptStore;

    public BiliController(BiliTranscriptService service, BiliSettingsService settingsService,
                          BiliTranscriptStore transcriptStore) {
        this.service = service;
        this.settingsService = settingsService;
        this.transcriptStore = transcriptStore;
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
            done.put("transcriptId", saveTranscript(payload, stats));
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

    /* ── 提取记录（每次完整提取自动保存） ── */

    @GetMapping("/transcripts")
    public Map<String, Object> listTranscripts() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("transcripts", transcriptStore.list());
        return Api.ok(data);
    }

    @GetMapping("/transcripts/{id}")
    public Map<String, Object> transcript(@PathVariable("id") String id) {
        return Api.ok(transcriptStore.get(id));
    }

    @DeleteMapping("/transcripts/{id}")
    public Map<String, Object> deleteTranscript(@PathVariable("id") String id) {
        boolean deleted = transcriptStore.delete(id);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("id", id);
        data.put("deleted", deleted);
        return Api.ok(data);
    }

    /**
     * 把这次提取的文字稿落盘。存储失败不影响已经流式返回的文字，
     * 只记录日志（比如磁盘满）。
     */
    private String saveTranscript(Map<String, Object> payload, Map<String, Object> stats) {
        String text = strOf(stats.get("text"));
        if (text.isBlank()) {
            return "";
        }
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("title", strOf(payload.get("title")));
        meta.put("owner", strOf(payload.get("owner")));
        meta.put("bvid", strOf(payload.get("bvid")));
        meta.put("aid", longOf(payload.get("aid")));
        meta.put("cid", longOf(payload.get("cid")));
        meta.put("page", longOf(payload.get("page")));
        meta.put("part", strOf(payload.get("part")));
        meta.put("duration", longOf(payload.get("duration")));
        meta.put("source", strOf(stats.get("source")));
        try {
            Map<String, Object> saved = transcriptStore.save(meta, text);
            return String.valueOf(saved.getOrDefault("id", ""));
        } catch (Exception e) {
            log.warn("保存B站提取记录失败：{}", e.getMessage());
            return "";
        }
    }

    private static String strOf(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
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
