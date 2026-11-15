package com.deepseekapp.webserver.feature.writing.service;

import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import com.deepseekapp.webserver.ai.NovelAiService;
import com.deepseekapp.webserver.ai.AiSettings;

/**
 * 「大纲编辑」的 AI 多轮对话：围绕当前选中事件 / 小事件的标题与概要，
 * 结合整部大纲与同批所选事件，边聊边改。只输出标题 / 概要文本，不写正文。
 */
@Service
public class OutlineChatService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final int OUTLINE_LIMIT = 6000;

    private final NovelAiService ai;
    private final WritingService writingService;

    public OutlineChatService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void chat(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();

        List<Map<String, String>> history = messages(body.get("messages"));
        if (history.isEmpty()) {
            throw new IllegalArgumentException("请输入想让 AI 做什么");
        }

        StringBuilder system = new StringBuilder();
        system.append("""
                你是资深中文网文策划，正在协助作者修改一部小说的「事件结构」。
                你只负责事件 / 小事件的标题与概要，不写正文。

                输出规则：
                - 只输出标题和/或概要文本，纯文本；不要 markdown、不要编号、不要解释或寒暄；
                - 用户要求写 / 改写 / 细化概要时，用简明的叙述句交代事件的起因、推进与结果；
                  不要一条一条列出来，衔接要自然；篇幅与既有条目相近（通常 1-3 句，用户另有要求时从其要求）；
                - 只写大纲：只有在概要有出现场景描写、人物对白、心理刻画等内容时才能出现相应描写，其他时候禁止；
                - 用户只要求改标题时，只输出一行标题；只要求改概要时，只输出概要正文；
                - 用户追问或要求调整时，基于上一轮结果继续修改，不要另起炉灶；
                - 与【整部大纲节选】【当前事件】【同批所选的其他事件】保持一致，
                  除用户明确要求外，不改变既有剧情走向与伏笔安排。

                """);

        String outline = str(body.get("outlineContext"), "");
        if (!outline.isEmpty()) {
            system.append("【整部大纲节选】\n").append(truncate(outline, OUTLINE_LIMIT)).append("\n\n");
        }

        system.append("【当前事件】\n");
        system.append("标题：").append(str(body.get("chapterTitle"), "（未命名）")).append('\n');
        system.append("概要：").append(str(body.get("chapterSummary"), "（暂无）")).append("\n\n");

        List<Map<String, Object>> selected = selectedEvents(body.get("selectedEvents"));
        if (!selected.isEmpty()) {
            system.append("【同批所选的其他事件】\n");
            for (Map<String, Object> item : selected) {
                system.append("- ").append(str(item.get("title"), "（未命名）")).append("：")
                        .append(str(item.get("summary"), "（暂无）")).append('\n');
            }
            system.append('\n');
        }

        for (String delta : ai.streamMessages(system.toString(), history, AiSettings.from(body)).toIterable()) {
            sink.delta(delta);
        }
    }

    private static List<Map<String, String>> messages(Object raw) {
        List<Map<String, String>> list = new ArrayList<>();
        if (!(raw instanceof List<?> items)) {
            return list;
        }
        for (Object item : items) {
            if (!(item instanceof Map<?, ?> map)) {
                continue;
            }
            String role = map.get("role") == null ? "user" : String.valueOf(map.get("role"));
            String content = map.get("content") == null ? "" : String.valueOf(map.get("content")).trim();
            if (content.isEmpty()) {
                continue;
            }
            Map<String, String> message = new LinkedHashMap<>();
            message.put("role", role);
            message.put("content", content);
            list.add(message);
        }
        return list;
    }

    private static List<Map<String, Object>> selectedEvents(Object raw) {
        List<Map<String, Object>> list = new ArrayList<>();
        if (!(raw instanceof List<?> items)) {
            return list;
        }
        for (Object item : items) {
            if (!(item instanceof Map<?, ?> map)) {
                continue;
            }
            Map<String, Object> event = new LinkedHashMap<>();
            event.put("title", map.get("title"));
            event.put("summary", map.get("summary"));
            list.add(event);
        }
        return list;
    }

    private static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
    }

    private static String truncate(String value, int limit) {
        return value.length() <= limit ? value : value.substring(0, limit) + "…";
    }
}
