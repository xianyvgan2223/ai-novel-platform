package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * DeepSeek 官方网页搜索：POST {baseUrl}/v1/tools/search。
 *
 * <p>与对话共用同一个 API Key。返回结果只保留给模型阅读需要的字段，
 * 正文（need_content=true 时才有）会截断，避免一次占满上下文。</p>
 */
@Service
public class AgentWebSearchService {

    private static final int MAX_QUERY_CHARS = 128;
    private static final int MAX_COUNT = 20;
    private static final int MAX_SNIPPET_CHARS = 600;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    public List<Map<String, Object>> search(AgentOptions options, String query, int count, boolean needContent) {
        String keyword = query == null ? "" : query.trim().replaceAll("\\s+", " ");
        if (keyword.isEmpty()) {
            throw new ApiException(400, "搜索关键词不能为空");
        }
        if (keyword.length() > MAX_QUERY_CHARS) {
            keyword = keyword.substring(0, MAX_QUERY_CHARS);
        }
        if (options.apiKey() == null || options.apiKey().isBlank()) {
            throw new ApiException(400, "未配置 DeepSeek API Key，无法联网搜索");
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("query", keyword);
        body.put("count", Math.max(1, Math.min(count, MAX_COUNT)));
        body.put("need_content", needContent);

        String url = searchUrl(options.baseUrl());
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(30))
                .header("Authorization", "Bearer " + options.apiKey())
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(Json.write(body), StandardCharsets.UTF_8))
                .build();
        try {
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() >= 400) {
                throw new ApiException(response.statusCode(), "联网搜索失败：" + shorten(response.body()));
            }
            Map<String, Object> root = Json.asMap(Json.parse(response.body()));
            Object raw = root == null ? null : root.get("results");
            if (!(raw instanceof List<?> list)) {
                return List.of();
            }
            List<Map<String, Object>> out = new ArrayList<>();
            for (Object item : list) {
                Map<String, Object> row = Json.asMap(item);
                if (row == null) {
                    continue;
                }
                Map<String, Object> hit = new LinkedHashMap<>();
                hit.put("title", text(row.get("title")));
                hit.put("url", text(row.get("url")));
                hit.put("site", text(row.get("site_name")));
                hit.put("date", text(row.get("date")));
                hit.put("snippet", truncate(text(row.get("snippet")), MAX_SNIPPET_CHARS));
                String summary = text(row.get("summary"));
                if (!summary.isBlank()) {
                    // 摘要截断到与 snippet 同量级，10 条结果也不会撑爆工具事件
                    hit.put("summary", truncate(summary, MAX_SNIPPET_CHARS));
                }
                out.add(hit);
            }
            return out;
        } catch (ApiException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "联网搜索被中断");
        } catch (Exception e) {
            throw new ApiException(502, "联网搜索失败：" + e.getMessage());
        }
    }

    private static String searchUrl(String baseUrl) {
        String base = baseUrl == null || baseUrl.isBlank() ? "https://api.deepseek.com" : baseUrl.trim();
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        if (base.endsWith("/v1")) {
            return base + "/tools/search";
        }
        return base + "/v1/tools/search";
    }

    private static String shorten(String body) {
        String text = body == null ? "" : body;
        return text.length() > 300 ? text.substring(0, 300) : text;
    }

    private static String truncate(String text, int max) {
        return text.length() <= max ? text : text.substring(0, max) + "…";
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }
}
