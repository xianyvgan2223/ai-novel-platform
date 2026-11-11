package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.util.Json;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.Map;
import java.util.TreeMap;

/**
 * B站 WBI 签名。
 *
 * <p>2023 年 3 月起部分 Web 接口（player/wbi/v2、playurl 等）要求 query
 * 携带 wts / w_rid。密钥来自 nav 接口的 wbi_img（img_url / sub_url 文件名），
 * 内存缓存 12 小时（官方有效期约 1 天，取保守值）。</p>
 *
 * <p>算法来源：SocialSisterYi/bilibili-API-collect 的 misc/sign/wbi 文档。</p>
 */
@Service
public class WbiSigner {

    /** WBI key 混淆表 */
    private static final int[] MIX_TABLE = {
            46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
            33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
            26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36,
            20, 34, 44, 52};

    private static final String NAV_URL = "https://api.bilibili.com/x/web-interface/nav";
    private static final long KEY_TTL_MS = 12 * 60 * 60 * 1000L;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(20))
            .build();

    private record Keys(String imgKey, String subKey, long expiresAtMs) {
    }

    private volatile Keys cache;

    /** 对 baseUrl+params 做 WBI 签名，返回带 wts / w_rid 的完整 URL */
    public synchronized String signedUrl(String baseUrl, Map<String, String> params) throws IOException {
        Keys keys = keys();
        TreeMap<String, String> sorted = new TreeMap<>(params);
        sorted.put("wts", String.valueOf(System.currentTimeMillis() / 1000));

        StringBuilder query = new StringBuilder();
        for (Map.Entry<String, String> entry : sorted.entrySet()) {
            if (query.length() > 0) {
                query.append('&');
            }
            query.append(enc(entry.getKey())).append('=').append(enc(entry.getValue()));
        }
        String rid = md5Hex(query + mixedKey(keys));
        return baseUrl + "?" + query + "&w_rid=" + rid;
    }

    /** 取 img/sub key：优先缓存，过期则调 nav 刷新（失败时降级重取一次） */
    private Keys keys() throws IOException {
        Keys cached = cache;
        if (cached != null && cached.expiresAtMs() > System.currentTimeMillis()) {
            return cached;
        }
        IOException lastError = null;
        for (int attempt = 0; attempt < 2; attempt++) {
            try {
                HttpRequest request = HttpRequest.newBuilder(URI.create(NAV_URL))
                        .timeout(Duration.ofSeconds(20))
                        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
                        .GET()
                        .build();
                HttpResponse<String> response;
                try {
                    response = http.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new IOException("获取 WBI 密钥被中断", e);
                }
                if (response.statusCode() != 200) {
                    throw new IOException("获取 WBI 密钥失败：HTTP " + response.statusCode());
                }
                JsonNode wbi = Json.MAPPER.readTree(response.body()).path("data").path("wbi_img");
                String imgKey = keyFromUrl(wbi.path("img_url").asText(""));
                String subKey = keyFromUrl(wbi.path("sub_url").asText(""));
                if (imgKey.isEmpty() || subKey.isEmpty()) {
                    throw new IOException("WBI 密钥格式异常");
                }
                Keys fresh = new Keys(imgKey, subKey, System.currentTimeMillis() + KEY_TTL_MS);
                cache = fresh;
                return fresh;
            } catch (IOException e) {
                lastError = e;
            }
        }
        throw lastError;
    }

    /** https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png → 7cd084941338484aae1ad9425b84077c */
    private static String keyFromUrl(String url) {
        if (url == null || url.isEmpty()) {
            return "";
        }
        int slash = url.lastIndexOf('/');
        int dot = url.lastIndexOf('.');
        String name = dot > slash ? url.substring(slash + 1, dot) : url.substring(slash + 1);
        return name.length() > 32 ? name.substring(0, 32) : name;
    }

    /** (imgKey+subKey) 64 字符按混淆表重排，取前 32 位作为签名密钥 */
    private static String mixedKey(Keys keys) {
        String raw = keys.imgKey() + keys.subKey();
        StringBuilder mixed = new StringBuilder(32);
        for (int index : MIX_TABLE) {
            if (index < raw.length()) {
                mixed.append(raw.charAt(index));
            }
            if (mixed.length() == 32) {
                break;
            }
        }
        return mixed.toString();
    }

    private static String md5Hex(String text) {
        try {
            MessageDigest digest = MessageDigest.getInstance("MD5");
            byte[] bytes = digest.digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(32);
            for (byte b : bytes) {
                hex.append(Character.forDigit((b >> 4) & 0xF, 16))
                        .append(Character.forDigit(b & 0xF, 16));
            }
            return hex.toString();
        } catch (Exception e) {
            throw new IllegalStateException("MD5 不可用", e);
        }
    }

    /** B站 WBI 的 percent-encoding：与标准 URLEncoder 的三处差异需要修正 */
    private static String enc(String value) {
        String encoded = URLEncoder.encode(value, StandardCharsets.UTF_8);
        return encoded.replace("+", "%20").replace("*", "%2A").replace("%7E", "~");
    }
}
