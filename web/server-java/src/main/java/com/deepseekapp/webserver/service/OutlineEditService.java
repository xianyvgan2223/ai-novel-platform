package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Map;

/**
 * 网页端「大纲 AI 编辑」：按用户指令修改整篇大纲正文，流式返回修改后的完整大纲。
 */
@Service
public class OutlineEditService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final int OUTLINE_LIMIT = 30000;

    private final NovelAiService ai;
    private final WritingService writingService;

    public OutlineEditService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void edit(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();

        String outline = str(body.get("outlineText"), "");
        String instruction = str(body.get("instruction"), "");
        if (outline.isBlank()) {
            throw new ApiException(400, "当前没有可编辑的大纲");
        }
        if (instruction.isBlank()) {
            throw new ApiException(400, "请填写修改指令");
        }
        if (outline.length() > OUTLINE_LIMIT) {
            throw new ApiException(400, "大纲过长（" + outline.length() + " 字），请先分段处理");
        }

        String extra = str(body.get("extra"), "");
        String system = """
                你是资深小说编辑。请根据用户的修改指令改写这份大纲。
                只输出修改后的完整大纲正文：
                - 保持原有的层次与章节顺序，除非指令明确要求调整；
                - 不要输出解释、说明、Markdown 代码块或前后缀；
                - 未涉及的部分保持原样，不要缩写或省略。
                """;

        StringBuilder user = new StringBuilder();
        user.append("【当前大纲】\n").append(outline).append("\n\n");
        user.append("【修改指令】\n").append(instruction).append('\n');
        if (!extra.isBlank()) {
            user.append("\n额外要求：").append(extra).append('\n');
        }

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
}
