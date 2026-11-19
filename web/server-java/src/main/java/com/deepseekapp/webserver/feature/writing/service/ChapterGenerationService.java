package com.deepseekapp.webserver.feature.writing.service;

import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Map;
import com.deepseekapp.webserver.ai.NovelAiService;
import com.deepseekapp.webserver.ai.AiSettings;

/**
 * 网页端「小事件生成」：根据作品设定、当前小事件概要、上一事件结尾和人物档案，
 * 流式写出本小事件正文。结果只推给前端，保存由前端决定。
 */
@Service
public class ChapterGenerationService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final int OUTLINE_EXCERPT_LIMIT = 6000;
    private static final int PREV_CONTENT_LIMIT = 1200;

    /**
     * 静态写作规则放系统提示：同一部作品连写多章时，这段前缀可以整段命中缓存；
     * 具体设定、大纲、事件概要与前文都放在用户消息里，按「稳定的书 → 变化的事件」排列。
     */
    private static final String SYSTEM = """
            你是一位小说作家。请根据用户消息里的大纲设定，完整写出指定事件的详细正文。

            要求：
            - 本小事件开头必须承接【前文内容】结尾的场景、时间与人物状态，禁止突兀跳转；如需切换时间/地点，先用一小段过渡衔接
            - 本小事件内容必须严格围绕【当前小事件】与【事件概要】展开，禁止偏离大纲或编造大纲中不存在的情节
            - 以自然流畅的叙述方式展开，包含场景描写、对话、心理活动
            - 语言平实克制，贴近通俗小说文风；全篇比喻、排比等修辞手法不超过 1-2 处，禁止堆砌辞藻、空泛抒情
            - 用具体的动作、环境细节和人物对话推进情节，不要用比喻或抽象修辞来渲染气氛
            - 目标字数见用户消息末尾的【字数要求】
            - 结尾自然衔接【后续事件】中的下一个事件（若存在）
            - 若当前事件涉及【伏笔清单】中的伏笔，按其计划埋设或回收；清单未涉及的不要强行引入
            - 角色状态、位置与悬念需与【全局剧情状态】保持连续一致
            - 人物行为、言谈必须符合【人物档案】中设定的性格与能力，禁止擅自改变角色性格
            - 只写当前事件的内容，不要超出范围
            - 直接输出正文，不要添加注释说明
            """;

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

        user.append("\n【当前小事件】").append(str(body.get("chapterTitle"), "")).append('\n');
        user.append("【事件概要】").append(str(body.get("chapterSummary"), "（无）")).append('\n');

        String prevTitle = str(body.get("prevChapterTitle"), "");
        String prevContent = truncate(str(body.get("prevChapterContent"), ""), PREV_CONTENT_LIMIT);
        if (!prevTitle.isEmpty() || !prevContent.isEmpty()) {
            user.append("\n【上一个事件】").append(prevTitle).append('\n');
            user.append("【前文内容】\n").append(prevContent).append('\n');
        }

        String nextTitle = str(body.get("nextChapterTitle"), "");
        if (!nextTitle.isEmpty()) {
            user.append("\n【后续事件】").append(nextTitle).append('\n');
        }

        String characters = truncate(str(body.get("characters"), ""), 3000);
        if (!characters.isEmpty()) {
            user.append("\n【人物档案】\n").append(characters).append('\n');
        }

        // 已回收 / 已实现的伏笔不再注入（与手机端 filterResolvedForeshadowText 同口径）
        String foreshadows = filterResolvedForeshadows(
                truncate(str(body.get("foreshadows"), ""), 2000));
        if (!foreshadows.isEmpty()) {
            user.append("\n【伏笔清单】\n").append(foreshadows).append('\n');
        }

        String storyState = truncate(str(body.get("storyState"), ""), 2000);
        if (!storyState.isEmpty()) {
            user.append("\n【全局剧情状态】\n").append(storyState).append('\n');
        }

        user.append("\n【字数要求】").append(minWords).append('~').append(maxWords).append(" 字\n");
        if (!extra.isBlank()) {
            user.append("额外要求：").append(extra).append('\n');
        }

        for (String delta : ai.stream(SYSTEM, user.toString(), AiSettings.from(body)).toIterable()) {
            sink.delta(delta);
        }
    }

    /** 过滤已回收 / 已实现的伏笔行（与手机端「小事件详写」同一口径）。 */
    private static String filterResolvedForeshadows(String text) {
        StringBuilder out = new StringBuilder();
        for (String line : text.split("\n", -1)) {
            if (line.contains("已回收")
                    || line.contains("已实现")
                    || line.contains("已兑现")
                    || line.contains("回收完成")) {
                continue;
            }
            if (out.length() > 0) {
                out.append('\n');
            }
            out.append(line);
        }
        return out.toString().trim().replaceAll("\n{3,}", "\n\n");
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
