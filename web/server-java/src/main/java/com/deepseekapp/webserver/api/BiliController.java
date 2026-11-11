package com.deepseekapp.webserver.api;

import com.deepseekapp.webserver.service.BiliSettingsService;
import com.deepseekapp.webserver.service.BiliTranscriptService;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 网页端「B站视频转文字」接口。
 *
 * <p>POST /api/bili/resolve 解析视频信息；
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

    private static long longOf(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        try {
            return Long.parseLong(String.valueOf(value));
        } catch (Exception e) {
            return 0;
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
}
