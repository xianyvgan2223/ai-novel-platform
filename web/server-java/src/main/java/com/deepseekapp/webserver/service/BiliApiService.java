package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongConsumer;

/**
 * B站 Web API 客户端（Java 21 HttpClient）。
 *
 * <p>统一封装 User-Agent / Referer / SESSDATA Cookie；
 * player/wbi/v2 与 playurl 需要 WBI 签名（{@link WbiSigner}）。
 * 音频 CDN 直链必须带 UA + Referer，否则 403。</p>
 */
@Service
public class BiliApiService {

    public static final String USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    private static final String API_BASE = "https://api.bilibili.com";
    private static final String REFERER = "https://www.bilibili.com";

    private final WbiSigner wbiSigner;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(20))
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    public BiliApiService(WbiSigner wbiSigner) {
        this.wbiSigner = wbiSigner;
    }

    /** GET /x/web-interface/view?bvid= → data 节点 */
    public JsonNode fetchView(String bvid) throws IOException {
        HttpRequest request = baseBuilder(API_BASE + "/x/web-interface/view?bvid=" + bvid).GET().build();
        return getJson(request);
    }

    /** GET /x/player/wbi/v2?aid=&cid=（WBI 签名，带 SESSDATA）→ data 节点 */
    public JsonNode fetchPlayerInfo(long aid, long cid, String sessdata) throws IOException {
        String url = wbiSigner.signedUrl(API_BASE + "/x/player/wbi/v2", Map.of(
                "aid", String.valueOf(aid),
                "cid", String.valueOf(cid)));
        HttpRequest.Builder builder = baseBuilder(url);
        if (sessdata != null && !sessdata.isBlank()) {
            builder.header("Cookie", "SESSDATA=" + sessdata);
        }
        return getJson(builder.GET().build());
    }

    /** playerInfo → 字幕列表 [{lan, lanDoc, ai, url}]；无字幕返回空列表 */
    public List<Map<String, Object>> listSubtitles(long aid, long cid, String sessdata) throws IOException {
        JsonNode subtitles = fetchPlayerInfo(aid, cid, sessdata).path("subtitle").path("subtitles");
        List<Map<String, Object>> result = new ArrayList<>();
        for (JsonNode item : subtitles) {
            String lan = item.path("lan").asText("");
            String rawUrl = item.path("subtitle_url").asText("");
            if (lan.isEmpty() || rawUrl.isEmpty()) {
                continue;
            }
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("lan", lan);
            entry.put("lanDoc", item.path("lan_doc").asText(lan));
            entry.put("ai", lan.startsWith("ai-"));
            entry.put("url", rawUrl.startsWith("//") ? "https:" + rawUrl : rawUrl);
            result.add(entry);
        }
        return result;
    }

    /** 下载字幕 JSON → 每条字幕的正文文本（按时间轴顺序） */
    public List<String> fetchSubtitleLines(String subtitleUrl) throws IOException {
        HttpRequest request = baseBuilder(subtitleUrl).GET().build();
        HttpResponse<String> response = send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (response.statusCode() != 200) {
            throw new ApiException(502, "下载字幕失败：HTTP " + response.statusCode());
        }
        JsonNode body = Json.MAPPER.readTree(response.body()).path("body");
        List<String> lines = new ArrayList<>();
        for (JsonNode item : body) {
            String content = item.path("content").asText("");
            if (!content.isBlank()) {
                lines.add(content);
            }
        }
        return lines;
    }

    /** GET /x/player/playurl?avid=&cid=&fnval=16（WBI 签名）→ 最低码率音频流地址 */
    public String bestAudioUrl(long aid, long cid) throws IOException {
        String url = wbiSigner.signedUrl(API_BASE + "/x/player/playurl", Map.of(
                "avid", String.valueOf(aid),
                "cid", String.valueOf(cid),
                "fnval", "16"));
        JsonNode data = getJson(baseBuilder(url).GET().build());
        JsonNode audio = data.path("dash").path("audio");
        if (!audio.isArray() || audio.isEmpty()) {
            throw new ApiException(502, "B站没有返回可下载的音频流（可能是付费或番剧视频）");
        }
        JsonNode best = audio.get(0);
        for (JsonNode item : audio) {
            if (item.path("bandwidth").asLong(Long.MAX_VALUE)
                    < best.path("bandwidth").asLong(Long.MAX_VALUE)) {
                best = item;
            }
        }
        String baseUrl = best.path("baseUrl").asText("");
        if (baseUrl.isEmpty()) {
            throw new ApiException(502, "音频流地址为空");
        }
        return baseUrl;
    }

    /** 流式下载音频到 target；onProgress 收到的是累计字节数（失败自动重试一次） */
    public void downloadAudio(String url, Path target, LongConsumer onProgress) throws IOException {
        IOException lastError = null;
        for (int attempt = 0; attempt < 2; attempt++) {
            try {
                downloadOnce(url, target, onProgress);
                return;
            } catch (IOException e) {
                lastError = e;
            }
        }
        throw new ApiException(502, "下载音频失败：" + lastError.getMessage());
    }

    private void downloadOnce(String url, Path target, LongConsumer onProgress) throws IOException {
        HttpRequest request = baseBuilder(url).GET().build();
        HttpResponse<InputStream> response = send(request, HttpResponse.BodyHandlers.ofInputStream());
        if (response.statusCode() != 200) {
            throw new IOException("HTTP " + response.statusCode());
        }
        long total = response.headers().firstValueAsLong("Content-Length").orElse(0);
        try (InputStream in = response.body(); var out = Files.newOutputStream(target)) {
            byte[] buffer = new byte[64 * 1024];
            long downloaded = 0;
            int read;
            while ((read = in.read(buffer)) != -1) {
                out.write(buffer, 0, read);
                downloaded += read;
                if (onProgress != null) {
                    onProgress.accept(downloaded);
                }
            }
            if (total > 0 && downloaded != total) {
                throw new IOException("下载不完整：" + downloaded + "/" + total + " 字节");
            }
        }
    }

    /** 带 SESSDATA 调 nav → {valid, uname}，用于保存配置时校验。
     *  无效 Cookie 时 nav 返回 code -101（账号未登录），这里视为校验不通过而非接口错误。 */
    public Map<String, Object> checkSessdata(String sessdata) throws IOException {
        HttpRequest request = baseBuilder(API_BASE + "/x/web-interface/nav")
                .header("Cookie", "SESSDATA=" + sessdata)
                .GET().build();
        HttpResponse<String> response = send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (response.statusCode() == 412 || response.statusCode() == 429) {
            throw new ApiException(429, "B站接口暂时拒绝访问（HTTP " + response.statusCode() + " 风控），请稍后重试");
        }
        if (response.statusCode() != 200) {
            throw new ApiException(502, "校验 SESSDATA 失败：HTTP " + response.statusCode());
        }
        JsonNode root;
        try {
            root = Json.MAPPER.readTree(response.body());
        } catch (Exception e) {
            throw new ApiException(502, "B站接口返回了无法解析的内容");
        }
        int code = root.path("code").asInt(-1);
        JsonNode data = root.path("data");
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("valid", code == 0 && data.path("isLogin").asBoolean(false));
        result.put("uname", code == 0 ? data.path("uname").asText("") : "");
        return result;
    }

    /* ── 内部工具 ── */

    private HttpRequest.Builder baseBuilder(String url) {
        return HttpRequest.newBuilder(uri(url))
                .timeout(Duration.ofSeconds(60))
                .header("User-Agent", USER_AGENT)
                .header("Referer", REFERER)
                .header("Accept", "application/json, text/plain, */*");
    }

    private static URI uri(String url) {
        try {
            return URI.create(url);
        } catch (IllegalArgumentException e) {
            throw new ApiException(502, "B站返回的地址无法解析");
        }
    }

    private <T> HttpResponse<T> send(HttpRequest request, HttpResponse.BodyHandler<T> handler) throws IOException {
        try {
            return http.send(request, handler);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(504, "B站请求被中断");
        }
    }

    /** 统一出口：HTTP 状态 + 业务 code 校验，返回 data 节点 */
    private JsonNode getJson(HttpRequest request) throws IOException {
        HttpResponse<String> response = send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        int status = response.statusCode();
        if (status == 412 || status == 429) {
            throw new ApiException(429, "B站接口暂时拒绝访问（HTTP " + status + " 风控），请稍后重试");
        }
        if (status != 200) {
            throw new ApiException(502, "B站接口返回 HTTP " + status);
        }
        JsonNode root;
        try {
            root = Json.MAPPER.readTree(response.body());
        } catch (Exception e) {
            throw new ApiException(502, "B站接口返回了无法解析的内容");
        }
        int code = root.path("code").asInt(-1);
        if (code != 0) {
            String message = root.path("message").asText("");
            throw new ApiException(404, "B站接口报错（code " + code + "）："
                    + (message.isEmpty() ? "未知错误" : message));
        }
        return root.path("data");
    }
}
