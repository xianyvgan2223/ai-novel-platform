package com.deepseekapp.webserver.service;

import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Map;

/**
 * 「匹配大纲格式」：把用户粘贴的任意大纲文本，按 App 固定的三幕 / 大事件 / 小事件
 * 纯文本格式重排。只输出文本，是否保存成新作品由前端决定。
 */
@Service
public class OutlineFormatService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final String DEFAULT_SYSTEM = "你是一个专业的小说大纲格式化助手，请用纯文本格式输出。";
    private static final int INPUT_LIMIT = 20000;

    private final NovelAiService ai;
    private final WritingService writingService;

    public OutlineFormatService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void format(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();
        String input = str(body.get("input"), "");
        if (input.isBlank()) {
            throw new IllegalArgumentException("请先粘贴要格式化的大纲内容");
        }
        if (input.length() > INPUT_LIMIT) {
            input = input.substring(0, INPUT_LIMIT) + "…";
        }

        String user = """
                你是一个专业的小说大纲格式化工具。请将用户提供的大纲内容，按照以下固定格式重新组织和输出。

                固定输出格式要求（严格遵循，不要使用 markdown、表格、json 或任何标记符号，只输出纯文本）：

                1. 第一行：书名：《xxx》（如果原内容有书名则沿用，没有则根据内容提炼一个）
                2. 第二行：空行
                3. 核心概念简介（30-50 字，概括世界观、主角核心困境、故事最终落点）
                4. 然后按三幕结构组织内容，格式与「一键生成大纲」功能完全一致：

                ══ 第一幕：开端 ══
                ══ 大事件1：标题 ══
                大事件概述（50-100 字）
                ○ 小事件1：标题
                小事件概要（30-50 字）
                ○ 小事件2：标题
                小事件概要
                ══ 大事件2：标题 ══
                大事件概述
                ○ 小事件1：标题
                小事件概要

                ══ 第二幕：发展 ══
                ══ 大事件3：标题 ══
                大事件概述
                ○ 小事件1：标题
                小事件概要

                ══ 第三幕：高潮&结局 ══
                ══ 大事件N：标题 ══
                大事件概述
                ○ 小事件1：标题
                小事件概要

                注意事项：
                - 大事件用「══ 大事件N：标题 ══」，编号必须跨三幕全局连续递增，禁止每幕从 1 重新编号
                - 小事件用「○ 小事件N：标题」，编号在每个大事件内部从 1 重新开始
                - 事件概要直接写在标题的下一行，不要加任何前缀符号
                - 幕标题固定为：══ 第一幕：开端 ══ / ══ 第二幕：发展 ══ / ══ 第三幕：高潮&结局 ══
                - 保留原文中所有有价值的情节信息，不要遗漏重要内容
                - 如果原文有明确的三幕划分，请保留；如果没有，请根据内容合理划分
                - 事件数量根据原文内容灵活调整，不要强行凑数

                用户的大纲内容如下：
                ---
                %s
                ---
                """.formatted(input);

        for (String delta : ai.stream(DEFAULT_SYSTEM, user, AiSettings.from(body)).toIterable()) {
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
