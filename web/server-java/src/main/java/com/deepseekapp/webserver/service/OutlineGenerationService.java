package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 网页端「大纲生成」：分阶段调用模型，输出作品 + 大事件 + 小事件两层结构。
 *
 * <p>阶段：定调 → 三幕骨架 → 分批精写大事件 → 分批展开小事件。
 * 每一步都通过 SSE 推给前端，最终 result 里带可直接保存的数据。</p>
 */
@Service
public class OutlineGenerationService {

    /** SSE 回调：阶段、增量文本、最终结果 */
    public interface Sink {
        void stage(int index, int total, String label) throws IOException;

        void delta(String text) throws IOException;

        void result(Map<String, Object> data) throws IOException;
    }

    private static final String JSON_SYSTEM =
            "你是资深中文网文策划与小说编辑。只输出严格 JSON，不要 markdown 代码块，不要任何解释文字。";

    private static final int TOTAL_STAGES = 4;

    private final NovelAiService ai;
    private final WritingService writingService;

    public OutlineGenerationService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void generate(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();
        AiSettings settings = AiSettings.from(body);

        String genre = str(body.get("genre"), "都市");
        String theme = str(body.get("theme"), "");
        String protagonist = str(body.get("protagonist"), "");
        String worldview = str(body.get("worldview"), "");
        String extra = str(body.get("extra"), "");
        int majorCount = clamp(intVal(body.get("majorCount"), 6), 3, 12);
        int minorCount = clamp(intVal(body.get("minorCount"), 3), 1, 5);

        StringBuilder setting = new StringBuilder();
        setting.append("题材：").append(genre).append('\n');
        setting.append("主题：").append(theme.isEmpty() ? "（自由发挥）" : theme).append('\n');
        setting.append("主角：").append(protagonist.isEmpty() ? "（自由发挥）" : protagonist).append('\n');
        setting.append("世界观：").append(worldview.isEmpty() ? "（自由发挥）" : worldview);
        if (!extra.isBlank()) {
            setting.append('\n').append("额外要求：").append(extra);
        }

        // ── 阶段 1：定调 ──
        sink.stage(1, TOTAL_STAGES, "定调：书名、概念与人物");
        String conceptPrompt = """
                请根据以下小说设定，生成书名、核心概念和 3 个主要人物。

                要求：
                - 书名要有网文记忆点，不要用「XX的故事」这种平淡写法；
                - concept 写清核心冲突、主角目标与最大阻力；
                - 人物写 3 个：主角、主要对手、关键配角。

                严格 JSON：
                {"title":"书名","concept":"核心概念","characters":[{"name":"姓名","role":"身份与定位","desc":"性格、欲望与行为逻辑"}]}

                设定：
                """ + setting;

        JsonNode conceptRoot = readObject(
                streamCall(JSON_SYSTEM, conceptPrompt, sink, settings),
                "模型返回的书名/概念格式无法解析，请重试");
        String title = text(conceptRoot, "title", "未命名作品");
        String concept = text(conceptRoot, "concept", "");
        JsonNode characters = conceptRoot.path("characters");

        // ── 阶段 2：三幕骨架 ──
        sink.stage(2, TOTAL_STAGES, "规划三幕与 " + majorCount + " 个大事件");
        String skeletonPrompt = """
                请规划全篇三幕结构，大事件总数必须严格等于 %d，按第一幕 30%%、第二幕 50%%、第三幕 20%% 分配
                （无法整除时第二幕多分配余量）。

                每个大事件只写标题与一句话定位（核心冲突 + 在故事弧线中的位置：铺垫/升级/转折/高潮/结局），
                不要展开细节，不要在标题或定位里出现任何编号。
                大事件之间要有递进关系：铺垫→冲突升级→危机加剧→高潮→收束；
                人物成长：每一幕结尾主角有阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→闭环」。
                伏笔只做短线：每条伏笔必须能在 5 个大事件之内埋设并回收，不要写长线伏笔；
                第三幕需覆盖前文主要伏笔的回收点。

                严格 JSON：
                {"acts":[{"act":"第一幕：开端","events":[{"title":"事件标题","position":"一句话定位"}]}]}

                设定：
                %s

                书名：%s
                核心概念：%s
                """.formatted(majorCount, setting, title, concept);

        JsonNode skeletonRoot = readObject(
                streamCall(JSON_SYSTEM, skeletonPrompt, sink, settings),
                "模型返回的三幕骨架格式无法解析，请重试");
        List<Map<String, Object>> acts = parseActs(skeletonRoot);
        List<Map<String, Object>> flatEvents = flattenEvents(acts);
        if (flatEvents.isEmpty()) {
            throw new ApiException(502, "模型没有返回可用的大纲骨架，请重试");
        }
        if (flatEvents.size() > majorCount) {
            trimEvents(acts, majorCount);
            flatEvents = flattenEvents(acts);
        }

        // ── 阶段 3：分批精写 ──
        sink.stage(3, TOTAL_STAGES, "精写大事件概述");
        String skeletonDigest = digestSkeleton(flatEvents);
        for (int start = 0; start < flatEvents.size(); start += 5) {
            int end = Math.min(start + 5, flatEvents.size());
            List<Map<String, Object>> batch = flatEvents.subList(start, end);
            String prompt = buildEventSummaryPrompt(setting, title, concept, skeletonDigest, batch);
            JsonNode root = readObject(
                    streamCall(JSON_SYSTEM, prompt, sink, settings),
                    "模型返回的大事件概述格式无法解析，请重试");
            JsonNode events = root.path("events");
            for (int i = 0; i < batch.size() && i < events.size(); i++) {
                String summary = events.get(i).path("summary").asText("").trim();
                if (!summary.isEmpty()) {
                    batch.get(i).put("summary", summary);
                }
            }
        }

        // ── 阶段 4：分批展开小事件 ──
        sink.stage(4, TOTAL_STAGES, "按大事件生成小事件");
        for (int start = 0; start < flatEvents.size(); start += 2) {
            int end = Math.min(start + 2, flatEvents.size());
            List<Map<String, Object>> batch = flatEvents.subList(start, end);
            String prompt = buildChapterPrompt(setting, title, concept, batch, minorCount);
            JsonNode root = readObject(
                    streamCall(JSON_SYSTEM, prompt, sink, settings),
                    "模型返回的小事件列表格式无法解析，请重试");
            JsonNode events = root.path("events");
            for (int i = 0; i < batch.size() && i < events.size(); i++) {
                JsonNode chapters = events.get(i).path("chapters");
                List<Map<String, Object>> list = new ArrayList<>();
                for (JsonNode chapter : chapters) {
                    String chapterTitle = chapter.path("title").asText("").trim();
                    String chapterSummary = chapter.path("summary").asText("").trim();
                    if (chapterTitle.isEmpty()) {
                        continue;
                    }
                    Map<String, Object> item = new LinkedHashMap<>();
                    item.put("title", chapterTitle);
                    item.put("summary", chapterSummary);
                    list.add(item);
                }
                if (list.size() > minorCount) {
                    list = new ArrayList<>(list.subList(0, minorCount));
                }
                batch.get(i).put("chapters", list);
            }
        }

        // ── 汇总：扁平事件列表 + 大纲正文（手机端可解析的规范格式）──
        List<Map<String, Object>> chapterRows = new ArrayList<>();
        StringBuilder outlineText = new StringBuilder();
        int index = 1;
        int actSeq = 0;
        int majorSeq = 0;
        for (Map<String, Object> act : acts) {
            actSeq++;
            outlineText.append("══ ").append(actLabel(act, actSeq)).append(" ══\n\n");
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> events = (List<Map<String, Object>>) act.get("events");
            if (events == null) {
                continue;
            }
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

                // ══ 大事件N：标题 ══（N 为全篇连续编号，与手机端 normalizeOutlineText 一致）
                outlineText.append("══ 大事件").append(majorNumber).append("：")
                        .append(majorTitle).append(" ══\n");
                String summary = str(event.get("summary"), "");
                if (!summary.isEmpty()) {
                    outlineText.append(summary).append('\n');
                }

                @SuppressWarnings("unchecked")
                List<Map<String, Object>> chapters = (List<Map<String, Object>>) event.get("chapters");
                if (chapters != null) {
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

                        // ○ 小事件N：标题（N 在每个大事件内部从 1 重新开始）
                        outlineText.append("○ 小事件").append(minorNumber).append("：")
                                .append(minorTitle).append('\n');
                        String chapterSummary = str(chapter.get("summary"), "");
                        if (!chapterSummary.isEmpty()) {
                            outlineText.append(chapterSummary).append('\n');
                        }
                        outlineText.append('\n');
                    }
                }
                outlineText.append('\n');
            }
        }

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("title", title);
        data.put("concept", concept);
        data.put("genre", genre);
        data.put("theme", theme);
        data.put("protagonist", protagonist);
        data.put("worldview", worldview);
        data.put("charactersJson", normalizeCharacters(characters, protagonist));
        data.put("skeletonJson", Json.write(acts));
        data.put("outlineText", outlineText.toString());
        data.put("chapters", chapterRows);
        data.put("majorCount", flatEvents.size());
        data.put("minorCount", minorCount);
        sink.result(data);
    }

    // ───────────────────────────── 提示词 ─────────────────────────────

    private String buildEventSummaryPrompt(StringBuilder setting, String title, String concept,
                                           String skeletonDigest, List<Map<String, Object>> batch) {
        StringBuilder batchText = new StringBuilder();
        for (int i = 0; i < batch.size(); i++) {
            batchText.append(i + 1).append(". ").append(batch.get(i).get("title"))
                    .append("（").append(str(batch.get(i).get("position"), "")).append("）\n");
        }
        return """
                请精写以下本批大事件的完整概述，标题必须与骨架完全一致、按顺序输出。

                大事件粒度（严格遵守）：
                - 大事件 = 改变故事走向的重大阶段节点（如身份揭露、势力决裂、觉醒/蜕变、终局大战），
                  应跨越时间与场景、可独立成章；
                - 禁止把单个场景、单次对话、单一动作步骤当作大事件；
                - 大事件数量多代表故事铺陈规模大，不代表粒度变细。

                写作要求：
                - 概述要写清：核心冲突、关键转折、牵扯人物、结束时留下的悬念；相邻事件要有递进，
                  不要重复已发生的情节；
                - 延续伏笔：已埋伏笔按计划回收；本批新埋伏笔要在概述中点明，并且必须能在 5 个大事件之内回收；
                  不要写长线伏笔，已回收的伏笔不要再写；
                - 不要在正文里出现任何编号。

                严格 JSON：
                {"events":[{"title":"与骨架一致的事件标题","summary":"完整概述"}]}
                必须恰好 %d 个。

                设定：
                %s

                书名：%s
                核心概念：%s

                全局骨架（仅标题与定位）：
                %s

                本批需要精写的大事件：
                %s
                """.formatted(batch.size(), setting, title, concept, skeletonDigest, batchText);
    }

    private String buildChapterPrompt(StringBuilder setting, String title, String concept,
                                      List<Map<String, Object>> batch, int minorCount) {
        StringBuilder batchText = new StringBuilder();
        for (int i = 0; i < batch.size(); i++) {
            Map<String, Object> event = batch.get(i);
            batchText.append(i + 1).append(". ").append(event.get("title")).append('\n')
                    .append("概述：").append(str(event.get("summary"), "（无）")).append("\n\n");
        }
        return """
                请为以下大事件各生成连续的小事件，每个大事件恰好 %d 个小事件，
                每个小事件一个标题和概要。小事件必须从该大事件的概述自然展开，
                小事件之间有递进，不要跨过大事件范围，不要在标题或正文里出现编号。

                ⚠️ 小事件写作要求：
                1. 每个小事件必须是独立完整的情节单元，不是大事件的一个执行步骤；
                2. 禁止把单个事件拆成时序步骤（例如「前往→发现→战斗→撤退」只算 1 个小事件）；
                3. 每个小事件应引入新的角色、地点、冲突或转折，而不是单纯推进上一个事件；
                4. 小事件组合起来必须完整覆盖该大事件概述里的全部关键情节、转折、场面、人物与伏笔；
                5. 伏笔只做短线：本批涉及的伏笔必须能在 5 个大事件之内回收，不要设计长线伏笔；
                   已经回收的伏笔不要再写。

                严格 JSON（字段名 chapters 保持不变）：
                {"events":[{"title":"大事件标题（原样）","chapters":[{"title":"小事件标题","summary":"小事件概要"}]}]}
                必须恰好 %d 个大事件、每个恰好 %d 个小事件。

                设定：
                %s

                书名：%s
                核心概念：%s

                本批大事件：
                %s
                """.formatted(minorCount, batch.size(), minorCount, setting, title, concept, batchText);
    }

    // ───────────────────────────── 解析与整理 ─────────────────────────────

    private List<Map<String, Object>> parseActs(JsonNode root) {
        List<Map<String, Object>> acts = new ArrayList<>();
        for (JsonNode actNode : root.path("acts")) {
            String actName = actNode.path("act").asText("").trim();
            List<Map<String, Object>> events = new ArrayList<>();
            for (JsonNode eventNode : actNode.path("events")) {
                String eventTitle = eventNode.path("title").asText("").trim();
                if (eventTitle.isEmpty()) {
                    continue;
                }
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("title", eventTitle);
                event.put("position", eventNode.path("position").asText("").trim());
                event.put("summary", "");
                event.put("chapters", new ArrayList<Map<String, Object>>());
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
        return acts;
    }

    @SuppressWarnings("unchecked")
    private List<Map<String, Object>> flattenEvents(List<Map<String, Object>> acts) {
        List<Map<String, Object>> flat = new ArrayList<>();
        for (Map<String, Object> act : acts) {
            Object events = act.get("events");
            if (events instanceof List<?> list) {
                for (Object item : list) {
                    if (item instanceof Map<?, ?> map) {
                        flat.add((Map<String, Object>) map);
                    }
                }
            }
        }
        return flat;
    }

    @SuppressWarnings("unchecked")
    private void trimEvents(List<Map<String, Object>> acts, int limit) {
        int remaining = limit;
        for (Map<String, Object> act : acts) {
            if (remaining <= 0) {
                act.put("events", new ArrayList<>());
                continue;
            }
            Object events = act.get("events");
            if (!(events instanceof List<?> list)) {
                continue;
            }
            if (list.size() <= remaining) {
                remaining -= list.size();
                continue;
            }
            List<Object> kept = new ArrayList<>(list.subList(0, remaining));
            act.put("events", kept);
            remaining = 0;
        }
    }

    private String digestSkeleton(List<Map<String, Object>> flatEvents) {
        StringBuilder builder = new StringBuilder();
        for (Map<String, Object> event : flatEvents) {
            builder.append("- ").append(event.get("title"))
                    .append("：").append(str(event.get("position"), ""))
                    .append('\n');
        }
        return builder.toString();
    }

    // ───────────────────────────── 模型调用与 JSON 工具 ─────────────────────────────

    private String streamCall(String system, String user, Sink sink, AiSettings settings) throws IOException {
        StringBuilder buffer = new StringBuilder();
        for (String delta : ai.stream(system, user, settings).toIterable()) {
            buffer.append(delta);
            sink.delta(delta);
        }
        return buffer.toString();
    }

    private JsonNode readObject(String raw, String errorMessage) {
        String json = extractJson(raw);
        try {
            JsonNode node = Json.MAPPER.readTree(json);
            if (node == null || !node.isObject()) {
                throw new ApiException(502, errorMessage);
            }
            return node;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(502, errorMessage);
        }
    }

    private static String extractJson(String raw) {
        String text = raw == null ? "" : raw.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start >= 0 && end > start) {
            return text.substring(start, end + 1);
        }
        return text;
    }

    private static String text(JsonNode node, String field, String fallback) {
        String value = node.path(field).asText("").trim();
        return value.isEmpty() ? fallback : value;
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

    /**
     * 人物档案转成手机端 CharacterProfile 的字段结构
     * （name / description / abilities / personality / is_protagonist）。
     * 模型给的是 name / role / desc，直接落库手机端读不到描述。
     */
    private static String normalizeCharacters(JsonNode characters, String protagonist) {
        List<Map<String, Object>> list = new ArrayList<>();
        String lead = protagonist == null ? "" : protagonist.trim();
        int position = 0;
        for (JsonNode node : characters) {
            String name = node.path("name").asText("").trim();
            if (name.isEmpty()) {
                position++;
                continue;
            }
            String role = node.path("role").asText("").trim();
            String desc = node.path("desc").asText("").trim();
            StringBuilder description = new StringBuilder();
            if (!role.isEmpty()) {
                description.append("身份：").append(role);
            }
            if (!desc.isEmpty()) {
                if (description.length() > 0) {
                    description.append("；");
                }
                description.append(desc);
            }
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("name", name);
            item.put("description", description.toString());
            item.put("abilities", "");
            item.put("personality", "");
            item.put("is_protagonist", position == 0 || (!lead.isEmpty() && lead.contains(name)));
            list.add(item);
            position++;
        }
        return Json.write(list);
    }

    /**
     * 事件 / 小事件标题清洗：去掉两端装饰与模型回显的「大事件N：」前缀，
     * 保证写进正文的标题与手机端解析出的标题一致。
     */
    private static String cleanTitle(String raw) {
        String text = raw == null ? "" : raw;
        for (int i = 0; i < 3; i++) {
            text = text.replaceAll("^[\\s═=＝*_]+", "").replaceAll("[\\s═=＝*_]+$", "");
            text = text.replaceAll("^(?:大事件|小事件|Major|事件)\\s*[0-9]+\\s*[：:]\\s*", "");
        }
        return text.trim();
    }

    private static int intVal(Object value, int fallback) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(value));
        } catch (Exception ignored) {
            return fallback;
        }
    }

    private static int clamp(int value, int min, int max) {
        return Math.min(Math.max(value, min), max);
    }
}
