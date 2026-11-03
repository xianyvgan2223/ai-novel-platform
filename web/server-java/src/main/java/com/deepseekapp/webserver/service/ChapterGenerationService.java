package com.deepseekapp.webserver.service;

import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Map;

/**
 * 网页端「章节生成」：根据作品设定、当前章节概要、上一章结尾和人物档案，
 * 流式写出本章正文。结果只推给前端，保存由前端决定。
 */
@Service
public class ChapterGenerationService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final int OUTLINE_EXCERPT_LIMIT = 6000;
    private static final int PREV_CONTENT_LIMIT = 1200;

    private final NovelAiService ai;
    private final WritingService writingService;

    public ChapterGenerationService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void generate(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();

        int minWords = clamp(intVal(body.get("minWords"), 2000), 300, 20000);
        int maxWords = clamp(intVal(body.get("maxWords"), 3000), minWords, 30000);
        String extra = str(body.get("extra"), "");

        StringBuilder user = new StringBuilder();
        user.append("【小说设定】\n");
        user.append("书名：").append(str(body.get("title"), "（未命名）")).append('\n');
        user.append("类型：").append(str(body.get("genre"), "")).append('\n');
        user.append("主题：").append(str(body.get("theme"), "")).append('\n');
        user.append("主角：").append(str(body.get("protagonist"), "")).append('\n');
        user.append("世界观：").append(str(body.get("worldview"), "")).append('\n');

        String outline = truncate(str(body.get("outlineContent"), ""), OUTLINE_EXCERPT_LIMIT);
        if (!outline.isEmpty()) {
            user.append("\n【大纲（节选）】\n").append(outline).append('\n');
        }

        user.append("\n【当前章节】").append(str(body.get("chapterTitle"), "")).append('\n');
        user.append("【章节概要】").append(str(body.get("chapterSummary"), "（无）")).append('\n');

        String prevTitle = str(body.get("prevChapterTitle"), "");
        String prevContent = truncate(str(body.get("prevChapterContent"), ""), PREV_CONTENT_LIMIT);
        if (!prevTitle.isEmpty() || !prevContent.isEmpty()) {
            user.append("\n【上一章】").append(prevTitle).append('\n');
            user.append("【上一章结尾】\n").append(prevContent).append('\n');
        }

        String nextTitle = str(body.get("nextChapterTitle"), "");
        if (!nextTitle.isEmpty()) {
            user.append("\n【下一章】").append(nextTitle).append('\n');
        }

        String characters = truncate(str(body.get("characters"), ""), 3000);
        if (!characters.isEmpty()) {
            user.append("\n【人物档案】\n").append(characters).append('\n');
        }

        String foreshadows = truncate(str(body.get("foreshadows"), ""), 2000);
        if (!foreshadows.isEmpty()) {
            user.append("\n【伏笔清单】\n").append(foreshadows).append('\n');
        }

        String storyState = truncate(str(body.get("storyState"), ""), 2000);
        if (!storyState.isEmpty()) {
            user.append("\n【全局剧情状态】\n").append(storyState).append('\n');
        }

        user.append("""

                要求：
                - 本章内容必须严格围绕【当前章节】与【章节概要】展开，禁止偏离大纲、编造大纲中不存在的情节；
                - 开头要承接【上一章结尾】的场景、时间与人物状态，需要换场时先用一小段过渡；
                - 结尾为【下一章】留出自然的钩子；
                - 人物行为、言谈必须符合【人物档案】，不要擅自改变性格与能力；
                - 若涉及【伏笔清单】里的伏笔，按计划埋设或回收，清单外的不要强行引入；
                - 目标字数：%d~%d 字；
                - 只输出本章正文，不要章节号、标题、注释或解释。
                """.formatted(minWords, maxWords));

        if (!extra.isBlank()) {
            user.append("额外要求：").append(extra).append('\n');
        }

        String system = "你是一位小说作家，擅长写有画面感、有节奏的中文小说正文。";
        for (String delta : ai.stream(system, user.toString(), AiSettings.from(body)).toIterable()) {
            sink.delta(delta);
        }
    }

    private static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
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

    private static String truncate(String value, int limit) {
        return value.length() <= limit ? value : value.substring(0, limit) + "…";
    }
}
