package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 「小事件详写」：把已有的大纲正文拆成「大事件 → 小事件」两层结构。
 *
 * <p>用于网页上已有大纲、但还没有小事件数据的作品；拆出来的结构由前端写入
 * outline_chapters，后续可以逐个生成正文。</p>
 */
@Service
public class OutlineSplitService {

    private static final String JSON_SYSTEM =
            "你是资深中文小说编辑。只输出严格 JSON，不要 markdown 代码块，不要任何解释文字。";

    private static final int MAX_OUTLINE_CHARS = 30000;

    private final NovelAiService ai;
    private final WritingService writingService;

    public OutlineSplitService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public Map<String, Object> split(Map<String, Object> body) {
        writingService.requireConfig();

        String outlineText = str(body.get("outlineText"), "").trim();
        if (outlineText.isEmpty()) {
            throw new ApiException(400, "这部作品还没有大纲正文，无法拆分小事件");
        }
        if (outlineText.length() > MAX_OUTLINE_CHARS) {
            throw new ApiException(400, "大纲过长（" + outlineText.length() + " 字），请先截短或分段");
        }

        StringBuilder user = new StringBuilder();
        user.append("""
                请把下面的小说大纲拆成可直接写作的「大事件 → 小事件」两层结构。

                要求：
                - 每个大事件下 1~5 个小事件，小事件标题简洁、有钩子；
                - 每个小事件概要写清本小事件冲突与结果；
                - 大事件概述完整清晰；
                - 保留原大纲的剧情顺序，不要新增或删改核心情节；
                - 严格 JSON，不要 Markdown、不要解释。

                JSON：
                {"acts":[{"act":"第一幕：开端","events":[{"title":"大事件标题","summary":"大事件概述","chapters":[{"title":"小事件标题","summary":"小事件概要"}]}]}]}

                小说设定：
                """);
        user.append("书名：").append(str(body.get("title"), "（未命名）")).append('\n');
        user.append("类型：").append(str(body.get("genre"), "")).append('\n');
        user.append("主题：").append(str(body.get("theme"), "")).append('\n');
        user.append("主角：").append(str(body.get("protagonist"), "")).append('\n');
        user.append("世界观：").append(str(body.get("worldview"), "")).append('\n');
        user.append("\n大纲正文：\n").append(outlineText);

        String raw = ai.complete(JSON_SYSTEM, user.toString(), AiSettings.from(body));
        JsonNode root = readObject(raw);

        List<Map<String, Object>> acts = new ArrayList<>();
        List<Map<String, Object>> chapterRows = new ArrayList<>();
        StringBuilder outlineTextBuilder = new StringBuilder();
        int index = 1;

        for (JsonNode actNode : root.path("acts")) {
            String actName = actNode.path("act").asText("").trim();
            List<Map<String, Object>> events = new ArrayList<>();
            for (JsonNode eventNode : actNode.path("events")) {
                String eventTitle = eventNode.path("title").asText("").trim();
                if (eventTitle.isEmpty()) {
                    continue;
                }
                String eventSummary = eventNode.path("summary").asText("").trim();

                Map<String, Object> event = new LinkedHashMap<>();
                event.put("title", eventTitle);
                event.put("summary", eventSummary);

                List<Map<String, Object>> chapters = new ArrayList<>();
                for (JsonNode chapterNode : eventNode.path("chapters")) {
                    String chapterTitle = chapterNode.path("title").asText("").trim();
                    if (chapterTitle.isEmpty()) {
                        continue;
                    }
                    Map<String, Object> chapter = new LinkedHashMap<>();
                    chapter.put("title", chapterTitle);
                    chapter.put("summary", chapterNode.path("summary").asText("").trim());
                    chapters.add(chapter);
                }
                if (chapters.isEmpty()) {
                    continue;
                }
                event.put("chapters", chapters);
                events.add(event);
            }
            if (events.isEmpty()) {
                continue;
            }
            Map<String, Object> act = new LinkedHashMap<>();
            act.put("act", actName.isEmpty() ? "第" + (acts.size() + 1) + "幕" : actName);
            act.put("events", events);
            acts.add(act);
        }

        if (acts.isEmpty()) {
            throw new ApiException(502, "模型没有返回可用的小事件结构，请重试");
        }

        int actSeq = 0;
        int majorSeq = 0;
        for (Map<String, Object> act : acts) {
            actSeq++;
            outlineTextBuilder.append("══ ").append(actLabel(act, actSeq)).append(" ══\n\n");
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> events = (List<Map<String, Object>>) act.get("events");
            for (Map<String, Object> event : events) {
                majorSeq++;
                int majorNumber = majorSeq;
                String majorTitle = cleanTitle(str(event.get("title"), ""));
                Map<String, Object> major = new LinkedHashMap<>();
                major.put("index", index++);
                major.put("type", "major");
                major.put("title", majorTitle);
                major.put("summary", event.get("summary"));
                chapterRows.add(major);

                outlineTextBuilder.append("══ 大事件").append(majorNumber).append("：")
                        .append(majorTitle).append(" ══\n");
                String summary = str(event.get("summary"), "");
                if (!summary.isEmpty()) {
                    outlineTextBuilder.append(summary).append('\n');
                }

                @SuppressWarnings("unchecked")
                List<Map<String, Object>> chapters = (List<Map<String, Object>>) event.get("chapters");
                int minorNumber = 0;
                for (Map<String, Object> chapter : chapters) {
                    minorNumber++;
                    String minorTitle = cleanTitle(str(chapter.get("title"), ""));
                    Map<String, Object> minor = new LinkedHashMap<>();
                    minor.put("index", index++);
                    minor.put("type", "minor");
                    minor.put("title", minorTitle);
                    minor.put("summary", chapter.get("summary"));
                    chapterRows.add(minor);

                    outlineTextBuilder.append("○ 小事件").append(minorNumber).append("：")
                            .append(minorTitle).append('\n');
                    String chapterSummary = str(chapter.get("summary"), "");
                    if (!chapterSummary.isEmpty()) {
                        outlineTextBuilder.append(chapterSummary).append('\n');
                    }
                    outlineTextBuilder.append('\n');
                }
                outlineTextBuilder.append('\n');
            }
        }

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("actsJson", Json.write(acts));
        data.put("chapters", chapterRows);
        data.put("outlineText", outlineTextBuilder.toString());
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
                throw new ApiException(502, "模型返回的拆分结果格式无法解析，请重试");
            }
            return node;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(502, "模型返回的拆章结果格式无法解析，请重试");
        }
    }

    private static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
    }

    /** 幕标题：去掉 markdown 前缀；为空时补「第N幕」 */
    private static String actLabel(Map<String, Object> act, int seq) {
        String label = str(act.get("act"), "").replaceAll("^#+\\s*", "").trim();
        return label.isEmpty() ? "第" + seq + "幕" : label;
    }

    /** 事件 / 小事件标题清洗：去掉两端装饰与模型回显的「大事件N：」前缀 */
    private static String cleanTitle(String raw) {
        String text = raw == null ? "" : raw;
        for (int i = 0; i < 3; i++) {
            text = text.replaceAll("^[\\s═=＝*_]+", "").replaceAll("[\\s═=＝*_]+$", "");
            text = text.replaceAll("^(?:大事件|小事件|Major|事件)\\s*[0-9]+\\s*[：:]\\s*", "");
        }
        return text.trim();
    }
}
