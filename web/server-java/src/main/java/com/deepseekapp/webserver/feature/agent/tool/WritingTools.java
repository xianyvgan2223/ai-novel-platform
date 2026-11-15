package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.feature.agent.service.AgentEvent;
import com.deepseekapp.webserver.feature.agent.service.AgentRun;
import com.deepseekapp.webserver.feature.writing.service.ChapterGenerationService;
import com.deepseekapp.webserver.feature.writing.service.OutlineGenerationService;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 写作类工具：一键生成大纲、列出已有大纲、生成单章正文。
 *
 * <p>生成结果只回传给前端，不写入数据库；保存由用户在前端点确认后走原有流程。</p>
 */
@Component
public class WritingTools {

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final OutlineGenerationService outlineService;
    private final ChapterGenerationService chapterService;
    private final AgentToolSupport support;

    public WritingTools(DatabaseManager databaseManager,
                        SchemaCatalog schema,
                        OutlineGenerationService outlineService,
                        ChapterGenerationService chapterService,
                        AgentToolSupport support) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.outlineService = outlineService;
        this.chapterService = chapterService;
        this.support = support;
    }

    @Tool(name = "generate_outline",
            description = "根据题材、主题、主角、世界观一键生成完整小说大纲（书名、人物、三幕结构、大事件与小事件）。"
                    + "只返回结果，不会写入数据库；耗时较长，过程中会推送阶段进度。")
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
            out.put("outline", data);
            out.put("saved", false);
            out.put("note", "结果未写入数据库；需要保存时请让用户在前端点保存");
            return out;
        });
    }

    @Tool(name = "list_outlines",
            description = "列出当前设备已有的小说大纲（按 id 倒序）。需要看具体某条的完整内容时，再用 list_data / get_row 展开。")
    public Map<String, Object> listOutlines(
            @ToolParam(description = "返回条数，默认 10，最大 50", required = false) Integer limit,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("limit", limit);
        return support.traced(run, "list_outlines", args, () -> {
            support.requireRun(run);
            String db = schema.hasTable("novel", "outline_settings") ? "novel" : "deepseek";
            if (!schema.hasTable(db, "outline_settings")) {
                throw new ApiException(404, "没有找到大纲表 outline_settings");
            }
            int size = AgentToolSupport.clamp(limit == null ? 10 : limit, 1, AgentToolSupport.MAX_PAGE_SIZE);
            return databaseManager.app(run.deviceId(), db, connection -> {
                List<Map<String, Object>> rows = Db.query(connection,
                        "SELECT * FROM outline_settings ORDER BY id DESC LIMIT ?", size);
                Map<String, Object> out = new LinkedHashMap<>();
                out.put("db", db);
                out.put("count", rows.size());
                out.put("items", AgentToolSupport.trimRows(rows));
                return out;
            });
        });
    }

    @Tool(name = "generate_chapter",
            description = "根据小说设定与该章节大纲生成一章正文。只返回文本，不会写入数据库。")
    public Map<String, Object> generateChapter(
            @ToolParam(description = "书名") String title,
            @ToolParam(description = "题材", required = false) String genre,
            @ToolParam(description = "主题", required = false) String theme,
            @ToolParam(description = "主角设定", required = false) String protagonist,
            @ToolParam(description = "世界观", required = false) String worldview,
            @ToolParam(description = "大纲全文或节选", required = false) String outlineContent,
            @ToolParam(description = "本章标题", required = false) String chapterTitle,
            @ToolParam(description = "本章事件概要", required = false) String chapterSummary,
            @ToolParam(description = "目标最少字数，默认 2000", required = false) Integer minWords,
            @ToolParam(description = "额外要求", required = false) String extra,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("title", title);
        args.put("chapterTitle", chapterTitle);
        args.put("minWords", minWords);
        return support.traced(run, "generate_chapter", args, () -> {
            support.requireRun(run);
            int min = AgentToolSupport.clamp(minWords == null ? 2000 : minWords, 300, 20000);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("title", AgentToolSupport.blankTo(title, "未命名作品"));
            body.put("genre", AgentToolSupport.blankTo(genre, ""));
            body.put("theme", AgentToolSupport.blankTo(theme, ""));
            body.put("protagonist", AgentToolSupport.blankTo(protagonist, ""));
            body.put("worldview", AgentToolSupport.blankTo(worldview, ""));
            body.put("outlineContent", AgentToolSupport.blankTo(outlineContent, ""));
            body.put("chapterTitle", AgentToolSupport.blankTo(chapterTitle, ""));
            body.put("chapterSummary", AgentToolSupport.blankTo(chapterSummary, ""));
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
            String text = produced.toString();
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("chars", text.length());
            out.put("text", text.length() > 8000 ? text.substring(0, 8000) : text);
            out.put("truncated", text.length() > 8000);
            out.put("saved", false);
            out.put("note", "结果未写入数据库");
            return out;
        });
    }
}
