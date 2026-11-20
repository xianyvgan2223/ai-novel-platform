package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.context.AgentHistory;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Agent 的提示词与消息构建。
 *
 * <p>输出 OpenAI 兼容的普通 Map，交给 {@link AgentLlmClient} 直接发请求；
 * 不再经过 Spring AI 的 Message 体系。</p>
 */
public final class AgentPromptFactory {

    private AgentPromptFactory() {
    }

    private static final String BASE_PROMPT = """
            你是 deepseekapp 网页创作工作台的助手，可以直接调用工具读取用户的小说数据、检索情节素材、生成并保存大纲与正文。

            规则：
            1. 需要数据时必须调用工具，不要凭印象编造书名、章节、素材或统计数字。
            2. 工具返回为空就如实说明「库里没有找到」，不要编一个结果。
            3. 生成大纲或正文前，先确认题材、主题、主角等关键信息；用户没说时使用合理默认值，并在回答里说明用了什么默认值。
            4. 生成类工具会直接落库：generate_outline 保存成一部新作品（返回 outlineId），generate_chapter 把正文写进指定章节（返回 chapterId）。
               回答里要说明保存结果，不要说「不会自动保存」。
            5. 给已有作品写正文时，先 list_outlines 拿 outlineId，再 list_chapters 拿 eventIndex，然后调用 generate_chapter；
               缺参数会直接失败，不要猜 id。
            6. 除 generate_outline / generate_chapter 之外的读取工具（数据查询、检索、列表）都是只读的：
               不要声称修改、覆盖或删除了任何数据。
            7. 用中文回答，简洁直接；不要整段复述工具返回的原始 JSON，挑关键信息讲。
            8. 任务需要 3 步以上时（分析整本书、批量检查章节、生成后校对等），先调用 plan_task 列出步骤，
               再逐步执行，每完成一步调用 update_task_step 回写状态，最后给出总结。
            9. 关键信息缺失或存在多种合理方案时，调用 ask_user 给用户几个选项，用户可以选也可以自己输入；
               能从工具或上文推断出来时不要滥用。
            10. 调用 generate_outline 前，如果用户没有明确说大事件/小事件数量，先用 ask_user 询问：
                轻量（6 个大事件 / 每个 2 个小事件）、标准（8 个 / 每个 3 个）、详细（12 个 / 每个 4 个），
                并允许用户自己输入。已经明确说过的不要重复问。
            11. 重新生成大纲会创建一部新作品，不覆盖旧作品；需要改已有作品时，告诉用户去「大纲编辑」页调整。
            12. 联网搜索状态：%s
            """;

    /**
     * 系统提示词只放「跨请求不变」的内容：角色规则、设备号、用户自定义提示、压缩检查点。
     *
     * <p>不要往这里加时间、随机数、当前任务等每次都会变的东西 —— DeepSeek 的上下文缓存是
     * 前缀匹配，系统提示里任何一个字节变化都会让后面的工具 schema 与整段历史全部失配。</p>
     */
    public static String systemPrompt(AgentOptions options, String deviceId) {
        return systemPrompt(options, deviceId, "");
    }

    /** @param summary 更早对话的检查点（压缩产物）；为空则不注入 */
    public static String systemPrompt(AgentOptions options, String deviceId, String summary) {
        String searchState = options.webSearch()
                ? "已开启。需要新闻、实时数据或外部资料时调用 web_search。"
                : "未开启。不要尝试搜索网页；如果确实需要实时信息，告诉用户可以在设置里打开联网搜索。";
        StringBuilder prompt = new StringBuilder(String.format(BASE_PROMPT, searchState));
        prompt.append("\n当前设备：").append(deviceId);
        if (options.systemPrompt() != null && !options.systemPrompt().isBlank()) {
            prompt.append("\n\n").append(options.systemPrompt().trim());
        }
        if (summary != null && !summary.isBlank()) {
            prompt.append("\n\n").append(com.deepseekapp.webserver.feature.agent.context.AgentContextService.summaryPreamble())
                    .append('\n')
                    .append(com.deepseekapp.webserver.feature.agent.context.AgentContextService.summaryBlock(summary));
        }
        return prompt.toString();
    }

    /** 每次请求都会变的信息（时间）放在最后一条用户消息的末尾，保证前面的前缀可复用。 */
    public static String runtimeNote() {
        return runtimeNote(java.time.LocalDateTime.now());
    }

    public static String runtimeNote(java.time.LocalDateTime now) {
        return "【运行环境】当前时间："
                + now.format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")) + "（Asia/Shanghai）";
    }

    /** 历史 + 当前用户消息 → OpenAI 兼容的 messages（system 由客户端单独加）。 */
    public static List<Map<String, Object>> conversation(List<AgentHistory.Message> history, String message) {
        return conversation(history, message, "");
    }

    public static List<Map<String, Object>> conversation(List<AgentHistory.Message> history, String message,
                                                         String runtimeNote) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (AgentHistory.Message item : history) {
            if (item == null || item.content() == null || item.content().isBlank()) {
                continue;
            }
            if (!"user".equals(item.role()) && !"assistant".equals(item.role())) {
                continue;
            }
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("role", item.role());
            row.put("content", item.promptContent());
            out.add(row);
        }
        Map<String, Object> current = new LinkedHashMap<>();
        current.put("role", "user");
        current.put("content", runtimeNote == null || runtimeNote.isBlank()
                ? message
                : message + "\n\n" + runtimeNote);
        out.add(current);
        return out;
    }
}
