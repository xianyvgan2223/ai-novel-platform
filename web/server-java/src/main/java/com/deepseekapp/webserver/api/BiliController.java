package com.deepseekapp.webserver.api;

import com.deepseekapp.webserver.service.BiliTranscriptService;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.util.Map;

/**
 * 网页端「B站视频转文字」接口。
 *
 * <p>POST /api/bili/resolve 解析视频信息；
 * 字幕配置与 SSE 提取接口在后续版本补齐。</p>
 */
@RestController
@RequestMapping("/api/bili")
public class BiliController {

    private final BiliTranscriptService service;

    public BiliController(BiliTranscriptService service) {
        this.service = service;
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
}
