package com.deepseekapp.webserver.api;

import com.deepseekapp.webserver.service.BattleGenerationService;
import com.deepseekapp.webserver.service.ChapterGenerationService;
import com.deepseekapp.webserver.service.ChapterRewriteService;
import com.deepseekapp.webserver.service.OutlineEditService;
import com.deepseekapp.webserver.service.OutlineChatService;
import com.deepseekapp.webserver.service.OutlineFormatService;
import com.deepseekapp.webserver.service.OutlineGenerationService;
import com.deepseekapp.webserver.service.OutlineSplitService;
import com.deepseekapp.webserver.service.WritingService;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 网页端「小说创作」接口（Spring AI 驱动）：
 *
 * <pre>
 * POST /api/writing/novel/outline/generate   分阶段生成大纲（SSE）
 * POST /api/writing/novel/chapter/generate   生成章节正文（SSE）
 * POST /api/writing/novel/outline/edit       按指令修改大纲（SSE）
 * </pre>
 *
 * 所有接口只返回生成结果，落库由前端调用通用数据接口完成。
 */
@RestController
@RequestMapping("/api/writing/novel")
public class NovelWritingController {

    private final WritingService writingService;
    private final OutlineGenerationService outlineService;
    private final ChapterGenerationService chapterService;
    private final OutlineEditService outlineEditService;
    private final OutlineSplitService outlineSplitService;
    private final ChapterRewriteService chapterRewriteService;
    private final OutlineFormatService outlineFormatService;
    private final BattleGenerationService battleService;
    private final OutlineChatService outlineChatService;

    public NovelWritingController(WritingService writingService,
                                  OutlineGenerationService outlineService,
                                  ChapterGenerationService chapterService,
                                  OutlineEditService outlineEditService,
                                  OutlineSplitService outlineSplitService,
                                  ChapterRewriteService chapterRewriteService,
                                  OutlineFormatService outlineFormatService,
                                  BattleGenerationService battleService,
                                  OutlineChatService outlineChatService) {
        this.writingService = writingService;
        this.outlineService = outlineService;
        this.chapterService = chapterService;
        this.outlineEditService = outlineEditService;
        this.outlineSplitService = outlineSplitService;
        this.chapterRewriteService = chapterRewriteService;
        this.outlineFormatService = outlineFormatService;
        this.battleService = battleService;
        this.outlineChatService = outlineChatService;
    }

    @PostMapping("/outline/generate")
    public void generateOutline(@RequestBody(required = false) Map<String, Object> body,
                                HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        try {
            outlineService.generate(payload, new OutlineGenerationService.Sink() {
                @Override
                public void stage(int index, int total, String label) throws IOException {
                    Map<String, Object> event = new LinkedHashMap<>();
                    event.put("type", "stage");
                    event.put("index", index);
                    event.put("total", total);
                    event.put("label", label);
                    writeEvent(out, event);
                }

                @Override
                public void delta(String text) throws IOException {
                    Map<String, Object> event = new LinkedHashMap<>();
                    event.put("type", "delta");
                    event.put("text", text);
                    writeEvent(out, event);
                }

                @Override
                public void result(Map<String, Object> data) throws IOException {
                    Map<String, Object> event = new LinkedHashMap<>();
                    event.put("type", "result");
                    event.put("data", data);
                    writeEvent(out, event);
                }
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "大纲生成失败" : e.getMessage());
        }
    }

    @PostMapping("/chapter/generate")
    public void generateChapter(@RequestBody(required = false) Map<String, Object> body,
                                HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();
        try {
            chapterService.generate(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "小事件生成失败" : e.getMessage());
        }
    }

    @PostMapping("/outline/edit")
    public void editOutline(@RequestBody(required = false) Map<String, Object> body,
                            HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();
        try {
            outlineEditService.edit(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "大纲修改失败" : e.getMessage());
        }
    }

    /** 大纲编辑的 AI 多轮对话（SSE）：围绕选中事件的标题 / 概要边聊边改 */
    @PostMapping("/outline/chat")
    public void chatOutline(@RequestBody(required = false) Map<String, Object> body,
                            HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();
        try {
            outlineChatService.chat(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "AI 对话失败" : e.getMessage());
        }
    }

    /** 把粘贴的外部大纲重排成 App 固定格式（SSE） */
    @PostMapping("/outline/format")
    public void formatOutline(@RequestBody(required = false) Map<String, Object> body,
                              HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();
        try {
            outlineFormatService.format(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "大纲格式化失败" : e.getMessage());
        }
    }

    /** AI 写战斗：按三要素流式生成战斗场面（SSE） */
    @PostMapping("/battle/generate")
    public void generateBattle(@RequestBody(required = false) Map<String, Object> body,
                               HttpServletResponse response) throws IOException {
        Map<String, Object> payload = body == null ? Map.of() : body;
        writingService.requireConfig();

        OutputStream out = startSse(response);
        long startedAt = System.currentTimeMillis();
        StringBuilder produced = new StringBuilder();
        try {
            battleService.generate(payload, delta -> {
                produced.append(delta);
                Map<String, Object> event = new LinkedHashMap<>();
                event.put("type", "delta");
                event.put("text", delta);
                writeEvent(out, event);
            });

            Map<String, Object> done = new LinkedHashMap<>();
            done.put("type", "done");
            done.put("chars", produced.length());
            done.put("elapsedMs", System.currentTimeMillis() - startedAt);
            writeEvent(out, done);
        } catch (IOException ignored) {
            // 浏览器中途断开
        } catch (Exception e) {
            safeError(out, e.getMessage() == null ? "战斗场景生成失败" : e.getMessage());
        }
    }

    /** 按已有大纲拆出「大事件 → 章节」结构（非流式，供「大纲转章节」使用） */
    @PostMapping("/outline/split")
    public Map<String, Object> splitOutline(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> payload = body == null ? Map.of() : body;
        return Api.ok(outlineSplitService.split(payload));
    }

    /** 多选事件 / 章节，批量改写标题与概要（非流式） */
    @PostMapping("/chapters/rewrite")
    public Map<String, Object> rewriteChapters(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> payload = body == null ? Map.of() : body;
        return Api.ok(chapterRewriteService.rewrite(payload));
    }

    private OutputStream startSse(HttpServletResponse response) throws IOException {
        response.setContentType("text/event-stream;charset=UTF-8");
        response.setHeader("Cache-Control", "no-cache, no-transform");
        response.setHeader("Connection", "keep-alive");
        response.setHeader("X-Accel-Buffering", "no");
        response.flushBuffer();
        return response.getOutputStream();
    }

    private void writeEvent(OutputStream out, Map<String, Object> event) throws IOException {
        out.write(("data: " + Json.write(event) + "\n\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private void safeError(OutputStream out, String message) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", "error");
        event.put("error", message);
        try {
            writeEvent(out, event);
        } catch (IOException ignored) {
            // 连接已经断开
        }
    }
}
