package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.service.AgentAuthoringService;
import com.deepseekapp.webserver.feature.writing.service.ChapterGenerationService;
import com.deepseekapp.webserver.feature.writing.service.OutlineGenerationService;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 写作类工具：一键生成并保存大纲、列出作品与章节、为指定章节生成并保存正文。
 *
 * <p>生成结果会写进 {@code outline_records} / {@code outline_chapters}（走 SyncStore，
 * 手机端同步得到），工具的返回值里带保存后的 id，回答时可以直接告诉用户存到哪了。</p>
 */
@Component
public class WritingTools {

    /** 返回给模型的正文预览长度，完整正文已落库，避免一次把整章塞进上下文。 */
    private static final int PREVIEW_CHARS = 6000;

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final OutlineGenerationService outlineService;
    private final ChapterGenerationService chapterService;
    private final AgentAuthoringService authoring;
    private final AgentToolSupport support;

    public WritingTools(DatabaseManager databaseManager,
                        SchemaCatalog schema,
                        OutlineGenerationService outlineService,
                        ChapterGenerationService chapterService,
                        AgentAuthoringService authoring,
                        AgentToolSupport support) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.outlineService = outlineService;
        this.chapterService = chapterService;
        this.authoring = authoring;
        this.support = support;
    }

    @Tool(name = "generate_outline",
            description = "根据题材、主题、主角、世界观一键生成完整小说大纲，并自动保存为一部新作品"
                    + "（写入 outline_records 与 outline_chapters，返回 outlineId）。耗时较长，过程中会推送阶段进度。")
    public Map<String, Object> generateOutline(
            @ToolParam(description = "题材，例如 仙侠、都市、悬疑") String genre,
            @ToolParam(description = "主题或一句话核心创意", required = false) String theme,
            @ToolParam(description = "主角设定：姓名、身份、核心欲望", required = false) String protagonist,
            @ToolParam(description = "世界观设定", required = false) String worldview,
            @ToolParam(description = "大事件数量，3-12，默认 6", required = false) Integer majorCount,
            @ToolParam(description = "每个大事件下的小事件数量，1-5，默认 3", required = false) Integer minorCount,
            @ToolParam(description = "额外要求，例如「不要系统流」", required = false) String extra,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("genre", genre);
        args.put("theme", theme);
        args.put("protagonist", protagonist);
        args.put("worldview", worldview);
        args.put("majorCount", majorCount);
        args.put("minorCount", minorCount);
        args.put("extra", extra);
        return support.traced(run, "generate_outline", args, () -> {
            support.requireRun(run);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("genre", AgentToolSupport.blankTo(genre, "都市"));
            body.put("theme", AgentToolSupport.blankTo(theme, ""));
            body.put("protagonist", AgentToolSupport.blankTo(protagonist, ""));
            body.put("worldview", AgentToolSupport.blankTo(worldview, ""));
            body.put("extra", AgentToolSupport.blankTo(extra, ""));
            body.put("majorCount", AgentToolSupport.clamp(majorCount == null ? 6 : majorCount, 3, 12));
            body.put("minorCount", AgentToolSupport.clamp(minorCount == null ? 3 : minorCount, 1, 5));

            AtomicReference<Map<String, Object>> holder = new AtomicReference<>();
            try {
                outlineService.generate(body, new OutlineGenerationService.Sink() {
                    @Override
                    public void stage(int index, int total, String label) {
                        if (run != null) {
                            run.checkCancelled();
                            run.emit(AgentEvent.of("stage",
                                    "index", index, "total", total, "label", label));
                        }
                    }

                    @Override
                    public void delta(String text) {
                        // 大纲生成的中间文本是 JSON 片段，不回灌到对话里，只做取消检查
                        if (run != null) {
                            run.checkCancelled();
                        }
                    }

                    @Override
                    public void result(Map<String, Object> data) {
                        holder.set(data);
                    }
                });
            } catch (java.io.IOException e) {
                throw new ApiException(502, "大纲生成中断：" + AgentToolSupport.message(e));
            }

            Map<String, Object> data = holder.get();
            if (data == null) {
                throw new ApiException(502, "大纲生成没有返回结果，请重试");
            }

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("title", data.get("title"));
            out.put("outlineText", data.get("outlineText"));
            try {
                Map<String, Object> saved = authoring.saveOutline(run.deviceId(), data);
                out.put("saved", true);
                out.put("outlineId", saved.get("outlineId"));
                out.put("chapterCount", saved.get("chapterCount"));
                out.put("note", "已保存为作品 outlineId=" + saved.get("outlineId")
                        + "，共 " + saved.get("chapterCount") + " 章；用户可在「大纲编辑 / 章节选择」页看到");
            } catch (RuntimeException e) {
                // 生成成功但保存失败时仍把内容交回，避免整次生成白做
                out.put("saved", false);
                out.put("saveError", AgentToolSupport.message(e));
                out.put("note", "生成成功但写入数据库失败，请把大纲正文交给用户手动保存");
            }
            return out;
        });
    }

    @Tool(name = "list_outlines",
            description = "列出当前设备已有的小说作品/大纲（按 id 倒序，含题材、主题、主角与正文摘录）。"
                    + "要给已有作品写正文时，先用它拿到 outlineId。")
    public Map<String, Object> listOutlines(
            @ToolParam(description = "返回条数，默认 10，最大 50", required = false) Integer limit,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("limit", limit);
        return support.traced(run, "list_outlines", args, () -> {
            support.requireRun(run);
            String db = schema.hasTable("novel", "outline_records") ? "novel" : "deepseek";
            if (!schema.hasTable(db, "outline_records")) {
                throw new ApiException(404, "没有找到作品表 outline_records");
            }
            int size = AgentToolSupport.clamp(limit == null ? 10 : limit, 1, AgentToolSupport.MAX_PAGE_SIZE);
            return databaseManager.app(run.deviceId(), db, connection -> {
                List<Map<String, Object>> rows = Db.query(connection,
                        "SELECT id, title, genre, theme, protagonist, created_at, content "
                                + "FROM outline_records WHERE device_id = ? ORDER BY id DESC LIMIT ?",
                        run.deviceId(), size);
                List<Map<String, Object>> items = new ArrayList<>();
                for (Map<String, Object> row : rows) {
                    Map<String, Object> item = new LinkedHashMap<>(row);
                    Object rawContent = item.remove("content");
                    String content = rawContent == null ? "" : String.valueOf(rawContent);
                    item.put("contentChars", content.length());
                    item.put("excerpt", content.length() > 80 ? content.substring(0, 80) + "…" : content);
                    items.add(item);
                }
                Map<String, Object> out = new LinkedHashMap<>();
                out.put("db", db);
                out.put("table", "outline_records");
                out.put("count", items.size());
                out.put("items", items);
                return out;
            });
        });
    }

    @Tool(name = "list_chapters",
            description = "列出某部作品的全部章节（eventIndex、大/小事件、标题、概要、是否已写）。"
                    + "生成正文前先用它确认 eventIndex。")
    public Map<String, Object> listChapters(
            @ToolParam(description = "作品 id：list_outlines 或 generate_outline 返回的 outlineId") Long outlineId,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("outlineId", outlineId);
        return support.traced(run, "list_chapters", args, () -> {
            support.requireRun(run);
            if (outlineId == null) {
                throw new ApiException(400, "缺少 outlineId，请先调用 list_outlines");
            }
            Map<String, Object> outline = authoring.outline(run.deviceId(), outlineId);
            if (outline == null) {
                throw new ApiException(404, "作品不存在或不属于当前设备：" + outlineId);
            }
            List<Map<String, Object>> rows = authoring.chapters(run.deviceId(), outlineId);
            List<Map<String, Object>> items = new ArrayList<>();
            for (Map<String, Object> row : rows) {
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("eventIndex", row.get("event_index"));
                item.put("type", row.get("event_type"));
                item.put("title", row.get("event_title"));
                item.put("summary", trimText(row.get("event_summary"), 120));
                item.put("status", row.get("status"));
                item.put("written", AgentToolSupport.number(row.get("content_chars")) > 0);
                items.add(item);
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("outlineId", outlineId);
            out.put("title", outline.get("title"));
            out.put("count", items.size());
            out.put("chapters", items);
            return out;
        });
    }

    @Tool(name = "generate_chapter",
            description = "为已有作品的某一章生成正文，并自动保存到该章节（写入 outline_chapters.content）。"
                    + "必须先用 list_outlines 拿 outlineId、list_chapters 拿 eventIndex。")
    public Map<String, Object> generateChapter(
            @ToolParam(description = "作品 id（list_outlines 返回的 id）") Long outlineId,
            @ToolParam(description = "章节序号 eventIndex（list_chapters 返回的 eventIndex）") Integer eventIndex,
            @ToolParam(description = "目标最少字数，默认 2000", required = false) Integer minWords,
            @ToolParam(description = "额外要求", required = false) String extra,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("outlineId", outlineId);
        args.put("eventIndex", eventIndex);
        args.put("minWords", minWords);
        args.put("extra", extra);
        return support.traced(run, "generate_chapter", args, () -> {
            support.requireRun(run);
            if (outlineId == null) {
                throw new ApiException(400, "缺少 outlineId：先用 list_outlines 找到作品，再用 list_chapters 找章节");
            }
            Map<String, Object> outline = authoring.outline(run.deviceId(), outlineId);
            if (outline == null) {
                throw new ApiException(404, "作品不存在或不属于当前设备：" + outlineId);
            }
            if (eventIndex == null) {
                throw new ApiException(400, "缺少 eventIndex：先用 list_chapters 查看章节序号");
            }
            Map<String, Object> chapter = authoring.chapterAt(run.deviceId(), outlineId, eventIndex);
            if (chapter == null) {
                throw new ApiException(400, "作品 " + outlineId + " 里没有 eventIndex=" + eventIndex
                        + " 的章节，请先 list_chapters 查看");
            }
            Map<String, Object> prev = authoring.previousChapter(run.deviceId(), outlineId, eventIndex);

            int min = AgentToolSupport.clamp(minWords == null ? 2000 : minWords, 300, 20000);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("title", text(outline.get("title")));
            body.put("genre", text(outline.get("genre")));
            body.put("theme", text(outline.get("theme")));
            body.put("protagonist", text(outline.get("protagonist")));
            body.put("worldview", text(outline.get("worldview")));
            body.put("outlineContent", text(outline.get("content")));
            body.put("characters", text(outline.get("characters")));
            body.put("foreshadows", text(outline.get("foreshadows")));
            body.put("storyState", text(outline.get("story_state")));
            body.put("chapterTitle", text(chapter.get("event_title")));
            body.put("chapterSummary", text(chapter.get("event_summary")));
            if (prev != null) {
                body.put("prevChapterTitle", text(prev.get("event_title")));
                String prevText = text(prev.get("content"));
                body.put("prevChapterContent", prevText.isBlank() ? text(prev.get("ai_summary")) : prevText);
            }
            body.put("minWords", min);
            body.put("maxWords", Math.min(min + 1000, 30000));
            body.put("extra", AgentToolSupport.blankTo(extra, ""));

            StringBuilder produced = new StringBuilder();
            try {
                chapterService.generate(body, delta -> {
                    if (run != null) {
                        run.checkCancelled();
                    }
                    produced.append(delta);
                });
            } catch (java.io.IOException e) {
                throw new ApiException(502, "章节生成中断：" + AgentToolSupport.message(e));
            }

            String full = produced.toString();
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("chars", full.length());
            out.put("text", trimText(full, PREVIEW_CHARS));
            out.put("truncated", full.length() > PREVIEW_CHARS);
            long chapterId = AgentToolSupport.number(chapter.get("id"));
            try {
                authoring.saveChapterContent(run.deviceId(), chapterId, full);
                out.put("saved", true);
                out.put("chapterId", chapterId);
                out.put("outlineId", outlineId);
                out.put("note", "已写入章节 chapterId=" + chapterId
                        + "（作品 " + outlineId + " 第 " + eventIndex + " 章），用户可在章节正文页看到");
            } catch (RuntimeException e) {
                out.put("saved", false);
                out.put("saveError", AgentToolSupport.message(e));
                out.put("note", "生成成功但写入数据库失败，请把正文交给用户手动保存");
            }
            return out;
        });
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value).trim();
    }

    private static String trimText(Object value, int limit) {
        String text = text(value);
        return text.length() <= limit ? text : text.substring(0, limit) + "…";
    }
}
