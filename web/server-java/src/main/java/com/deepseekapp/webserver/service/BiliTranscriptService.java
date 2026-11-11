package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * B站视频转文字：解析、字幕查询与提取编排。
 *
 * <p>策略：优先官方字幕（用户上传 + B站 AI 字幕），
 * 拿不到字幕时下载音频交本地 faster-whisper 转写。</p>
 */
@Service
public class BiliTranscriptService {

    /** BV 号：BV 前缀 + 10 位字母数字（分享链接里前缀可能小写） */
    private static final Pattern BV_PATTERN = Pattern.compile("[Bb][Vv][0-9A-Za-z]{10}");

    private final BiliApiService biliApi;
    private final BiliSettingsService settings;

    public BiliTranscriptService(BiliApiService biliApi, BiliSettingsService settings) {
        this.biliApi = biliApi;
        this.settings = settings;
    }

    /** 解析输入 → 视频信息 + 分P 列表 + 登录态标志 */
    public Map<String, Object> resolve(String input) throws IOException {
        String bvid = extractBvid(input);
        if (bvid.isEmpty()) {
            throw new ApiException(400, "无法识别B站视频：请粘贴包含 BV 号的视频链接，或直接输入 BV 号");
        }
        JsonNode view = biliApi.fetchView(bvid);

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("bvid", view.path("bvid").asText(bvid));
        data.put("aid", view.path("aid").asLong());
        data.put("title", view.path("title").asText(""));
        data.put("owner", view.path("owner").path("name").asText(""));
        data.put("duration", view.path("duration").asLong(0));
        data.put("sessdataConfigured", settings.configured());

        List<Map<String, Object>> pages = new ArrayList<>();
        for (JsonNode page : view.path("pages")) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("cid", page.path("cid").asLong());
            item.put("page", page.path("page").asInt(1));
            item.put("part", page.path("part").asText(""));
            item.put("duration", page.path("duration").asLong(0));
            pages.add(item);
        }
        data.put("pages", pages);

        // 附带第一P的字幕列表（需要 SESSDATA，未配置/已过期时为空列表）
        long aid = view.path("aid").asLong();
        long firstCid = pages.isEmpty() ? view.path("cid").asLong() : (Long) pages.get(0).get("cid");
        data.put("subtitles", biliApi.listSubtitles(aid, firstCid, settings.sessdata()));
        return data;
    }

    /** 指定分P 的字幕列表 */
    public List<Map<String, Object>> subtitles(long aid, long cid) throws IOException {
        return biliApi.listSubtitles(aid, cid, settings.sessdata());
    }

    /** 从任意输入里提 BV 号；找不到返回空串 */
    public static String extractBvid(String input) {
        if (input == null || input.isBlank()) {
            return "";
        }
        Matcher matcher = BV_PATTERN.matcher(input.trim());
        if (!matcher.find()) {
            return "";
        }
        // 统一前缀为大写 BV，后 10 位保持原样（大小写敏感）
        return "BV" + matcher.group().substring(2);
    }
}
