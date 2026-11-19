package com.deepseekapp.webserver.feature.bili.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
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

    private final AppProperties props;
    private final BiliApiService biliApi;
    private final BiliSettingsService settings;
    private final WhisperAsrService whisper;

    public BiliTranscriptService(AppProperties props, BiliApiService biliApi,
                                 BiliSettingsService settings, WhisperAsrService whisper) {
        this.props = props;
        this.biliApi = biliApi;
        this.settings = settings;
        this.whisper = whisper;
    }

    /** SSE 事件回调，由 Controller 映射成 writeEvent；写流失败抛 IOException 中断上游 */
    public interface EventSink {
        void stage(int index, int total, String label) throws IOException;

        /** percent 为 null 表示无法计算（如总大小未知），仅展示文本 */
        void progress(Integer percent, String text) throws IOException;

        void delta(String text) throws IOException;
    }

    /** 解析输入 → 视频信息 + 分P 列表 + 登录态标志 + 第一P字幕 */
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

    /** 显式本地转写前的环境前置检查（SSE 开始前抛 JSON 错误） */
    public void requireWhisper() {
        whisper.requirePython();
        if (!whisper.whisperReady()) {
            throw new ApiException(503, whisper.whisperHint());
        }
    }

    /**
     * SSE 提取主流程。mode：auto（服务端决策，默认）/ subtitle / asr。
     * 正常完成返回统计 {source, chars} 供 Controller 组 done 事件。
     */
    public Map<String, Object> streamExtract(Map<String, Object> body, EventSink sink) throws IOException {
        long aid = longOf(body.get("aid"));
        long cid = longOf(body.get("cid"));
        if (aid <= 0 || cid <= 0) {
            throw new ApiException(400, "缺少 aid / cid 参数");
        }
        String mode = strOf(body.get("mode"));
        if (mode.isEmpty() || "auto".equals(mode)) {
            mode = "auto";
        } else if (!"subtitle".equals(mode) && !"asr".equals(mode)) {
            throw new ApiException(400, "mode 仅支持 auto / subtitle / asr");
        }

        sink.stage(1, 4, "查询字幕");
        List<Map<String, Object>> subtitles = biliApi.listSubtitles(aid, cid, settings.sessdata());
        if ("auto".equals(mode)) {
            mode = subtitles.isEmpty() ? "asr" : "subtitle";
        }

        if ("subtitle".equals(mode)) {
            return extractBySubtitle(body, subtitles, aid, cid, sink);
        }
        return extractByAsr(body, aid, cid, sink);
    }

    /* ── 字幕路径 ── */

    private Map<String, Object> extractBySubtitle(Map<String, Object> body,
                                                  List<Map<String, Object>> subtitles,
                                                  long aid, long cid, EventSink sink) throws IOException {
        String url = strOf(body.get("subtitleUrl"));
        if (url.isEmpty()) {
            url = defaultSubtitleUrl(subtitles);
        }
        if (url.isEmpty()) {
            throw new ApiException(400, "该视频没有可用字幕，请改用本地转写");
        }

        sink.stage(2, 2, "下载字幕");
        StringBuilder transcript = new StringBuilder();
        long chars = 0;
        for (String line : biliApi.fetchSubtitleLines(url)) {
            transcript.append(line).append('\n');
            sink.delta(line + "\n");
            chars += line.length() + 1;
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("source", "subtitle");
        result.put("chars", chars);
        result.put("text", transcript.toString());
        return result;
    }

    /** 默认字幕：优先人工字幕 → ai-zh → 第一个 */
    private static String defaultSubtitleUrl(List<Map<String, Object>> subtitles) {
        Map<String, Object> aiZh = null;
        Map<String, Object> anyAi = null;
        for (Map<String, Object> item : subtitles) {
            String lan = String.valueOf(item.getOrDefault("lan", ""));
            if (!Boolean.TRUE.equals(item.get("ai"))) {
                return String.valueOf(item.get("url"));
            }
            if ("ai-zh".equals(lan)) {
                aiZh = item;
            }
            if (anyAi == null) {
                anyAi = item;
            }
        }
        if (aiZh != null) {
            return String.valueOf(aiZh.get("url"));
        }
        return anyAi != null ? String.valueOf(anyAi.get("url")) : "";
    }

    /* ── 本地转写路径 ── */

    private Map<String, Object> extractByAsr(Map<String, Object> body,
                                             long aid, long cid, EventSink sink) throws IOException {
        // 时长校验：优先用前端传的 duration，缺失则回查视频信息
        long durationSec = longOf(body.get("duration"));
        if (durationSec <= 0) {
            String bvid = strOf(body.get("bvid"));
            if (!bvid.isEmpty()) {
                for (JsonNode page : biliApi.fetchView(bvid).path("pages")) {
                    if (page.path("cid").asLong() == cid) {
                        durationSec = page.path("duration").asLong(0);
                        break;
                    }
                }
            }
        }
        long limitSec = props.getBiliMaxVideoMinutes() * 60L;
        if (durationSec > limitSec) {
            throw new ApiException(413, "视频过长（" + (durationSec / 60) + " 分钟），"
                    + "本地转写上限 " + props.getBiliMaxVideoMinutes() + " 分钟");
        }

        sink.stage(2, 4, "下载音频");
        Path audioPath = props.dataDirPath().resolve("bili")
                .resolve("audio_" + aid + "_" + cid + ".m4s");
        Files.createDirectories(audioPath.getParent());
        try {
            String audioUrl = biliApi.bestAudioUrl(aid, cid);
            long[] lastReport = {0};
            try {
                biliApi.downloadAudio(audioUrl, audioPath, (downloaded, total) -> {
                    // 约 1MB 上报一次，避免 SSE 事件过密
                    if (downloaded - lastReport[0] < 1024 * 1024) {
                        return;
                    }
                    lastReport[0] = downloaded;
                    try {
                        Integer percent = total > 0 ? (int) (downloaded * 100 / total) : null;
                        sink.progress(percent, "已下载 " + mb(downloaded));
                    } catch (IOException e) {
                        throw new UncheckedIOException(e);
                    }
                });
            } catch (UncheckedIOException e) {
                throw e.getCause();
            }

            sink.stage(3, 4, "本地转写");
            StringBuilder transcript = new StringBuilder();
            long chars = runWhisper(audioPath, durationSec, sink, transcript);

            sink.stage(4, 4, "完成");
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("source", "asr");
            result.put("chars", chars);
            result.put("text", transcript.toString());
            return result;
        } finally {
            Files.deleteIfExists(audioPath);
        }
    }

    private long runWhisper(Path audioPath, long durationSec, EventSink sink, StringBuilder transcript) throws IOException {
        double[] duration = {durationSec};
        long[] chars = {0};
        whisper.transcribe(audioPath, new WhisperAsrService.Listener() {
            @Override
            public void onInfo(double durationSeconds) {
                if (durationSeconds > 0) {
                    duration[0] = durationSeconds;
                }
            }

            @Override
            public void onSegment(WhisperAsrService.Segment segment) {
                String line = segment.text();
                if (line.isBlank()) {
                    return;
                }
                chars[0] += line.length() + 1;
                transcript.append(line).append('\n');
                try {
                    if (duration[0] > 0) {
                        sink.progress((int) Math.min(100, segment.end() * 100 / duration[0]),
                                "转写中 " + clock(segment.end()) + " / " + clock(duration[0]));
                    }
                    sink.delta(line + "\n");
                } catch (IOException e) {
                    // WhisperAsrService 会解包并终止子进程
                    throw new UncheckedIOException(e);
                }
            }
        });
        return chars[0];
    }

    /* ── 小工具 ── */

    private static String mb(long bytes) {
        return String.format(Locale.ROOT, "%.1f MB", bytes / 1048576.0);
    }

    private static String clock(double seconds) {
        long total = Math.round(seconds);
        return total / 60 + "分" + total % 60 + "秒";
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
}
