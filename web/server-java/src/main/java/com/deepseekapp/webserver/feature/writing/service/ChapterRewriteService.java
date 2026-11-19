package com.deepseekapp.webserver.feature.writing.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import com.deepseekapp.webserver.ai.NovelAiService;
import com.deepseekapp.webserver.ai.AiSettings;

/**
 * 大纲编辑里的「多选 AI 改写」：一次改写多个事件 / 小事件的标题与概要。
 */
@Service
public class ChapterRewriteService {

    private static final String JSON_SYSTEM =
            "你是资深中文小说编辑。只输出严格 JSON，不要 markdown 代码块，不要任何解释文字。";

    private static final int MAX_ITEMS = 60;

    private final NovelAiService ai;
    private final WritingService writingService;

    public ChapterRewriteService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public Map<String, Object> rewrite(Map<String, Object> body) {
        writingService.requireConfig();

        String instruction = str(body.get("instruction"), "润色标题与概要，让冲突更具体、更有钩子");
        Object rawChapters = body.get("chapters");
        if (!(rawChapters instanceof List<?> list) || list.isEmpty()) {
            throw new ApiException(400, "没有选中要改写的内容");
        }
        if (list.size() > MAX_ITEMS) {
            throw new ApiException(400, "一次最多改写 " + MAX_ITEMS + " 项");
        }

        List<Map<String, Object>> items = new ArrayList<>();
        for (Object item : list) {
            if (!(item instanceof Map<?, ?> map)) {
                continue;
            }
            String title = str(map.get("title"), "");
            String summary = str(map.get("summary"), "");
            if (title.isEmpty() && summary.isEmpty()) {
                continue;
            }
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("index", map.get("index"));
            row.put("type", str(map.get("type"), "minor"));
            row.put("title", title);
            row.put("summary", summary);
            items.add(row);
        }
        if (items.isEmpty()) {
            throw new ApiException(400, "选中的内容都是空的");
        }

        String context = str(body.get("outlineContext"), "");
        if (context.length() > 4000) {
            context = context.substring(0, 4000) + "…";
        }

        StringBuilder user = new StringBuilder();
        user.append("请按用户消息末尾的修改指令，改写下面每个条目的标题与概要。\n");
        user.append("""
                要求：
                - 条目的数量和顺序必须保持不变，index 原样返回；
                - 标题简洁、有钩子；概要写清冲突与结果；
                - 不要新增或删除剧情，不要跨条目合并；
                - 严格 JSON：{"chapters":[{"index":1,"title":"标题","summary":"概要"}]}

                """);
        if (!context.isEmpty()) {
            user.append("大纲上下文（仅供理解，不要照抄）：\n").append(context).append('\n');
        }
        user.append("\n待改写条目：\n").append(Json.write(items));
        // 修改指令每次都可能变，放到最后：前面的静态要求与大纲上下文仍能命中前缀缓存
        user.append("\n\n修改指令：\n").append(instruction).append('\n');

        String raw = ai.complete(JSON_SYSTEM, user.toString(), AiSettings.from(body));
        JsonNode root = readObject(raw);

        List<Map<String, Object>> rewritten = new ArrayList<>();
        for (JsonNode node : root.path("chapters")) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("index", node.path("index").asInt(0));
            row.put("title", node.path("title").asText("").trim());
            row.put("summary", node.path("summary").asText("").trim());
            rewritten.add(row);
        }
        if (rewritten.isEmpty()) {
            throw new ApiException(502, "模型没有返回改写结果，请重试");
        }

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("chapters", rewritten);
        return data;
    }

    private JsonNode readObject(String raw) {
        String text = raw == null ? "" : raw.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        String json = start >= 0 && end > start ? text.substring(start, end + 1) : text;
        try {
            JsonNode node = Json.MAPPER.readTree(json);
            if (node == null || !node.isObject()) {
                throw new ApiException(502, "模型返回的改写结果格式无法解析，请重试");
            }
            return node;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(502, "模型返回的改写结果格式无法解析，请重试");
        }
    }

    private static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
    }
}
