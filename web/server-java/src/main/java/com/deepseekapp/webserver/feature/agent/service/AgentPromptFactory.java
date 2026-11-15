package com.deepseekapp.webserver.feature.agent.service;

import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.openai.OpenAiChatOptions;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Agent 的提示词与请求参数构建。
 *
 * <p>把「说什么」从「怎么跑」里拆出来：AgentService 只负责会话、流式与持久化，
 * 这里的静态方法全部无副作用，方便单测和调整提示词。</p>
 */
public final class AgentPromptFactory {

    private AgentPromptFactory() {
    }

    private static final String BASE_PROMPT = """
            你是 deepseekapp 网页创作工作台的助手，可以直接调用工具读取用户的小说数据、检索情节素材、生成大纲与正文。

            规则：
            1. 需要数据时必须调用工具，不要凭印象编造书名、章节、素材或统计数字。
            2. 工具返回为空就如实说明「库里没有找到」，不要编一个结果。
            3. 生成大纲或正文前，先确认题材、主题、主角等关键信息；用户没说时使用合理默认值，并在回答里说明用了什么默认值。
            4. 生成结果不会自动保存，回答结尾提醒用户可以在页面上确认后保存。
            5. 你是只读的：不要声称已经修改、覆盖或删除任何数据。
            6. 用中文回答，简洁直接；不要整段复述工具返回的原始 JSON，挑关键信息讲。
            7. 任务需要 3 步以上时（分析整本书、批量检查章节、生成后校对等），先调用 plan_task 列出步骤，
               再逐步执行，每完成一步调用 update_task_step 回写状态，最后给出总结。
            8. 关键信息缺失或存在多种合理方案时，调用 ask_user 给用户几个选项，用户可以选也可以自己输入；
               能从工具或上文推断出来时不要滥用。
            9. 联网搜索状态：%s
            """;

    public static String systemPrompt(AgentOptions options, String deviceId) {
        String searchState = options.webSearch()
                ? "已开启。需要新闻、实时数据或外部资料时调用 web_search。"
                : "未开启。不要尝试搜索网页；如果确实需要实时信息，告诉用户可以在设置里打开联网搜索。";
        StringBuilder prompt = new StringBuilder(String.format(BASE_PROMPT, searchState));
        prompt.append("\n当前设备：").append(deviceId);
        if (options.systemPrompt() != null && !options.systemPrompt().isBlank()) {
            prompt.append("\n\n").append(options.systemPrompt().trim());
        }
        return prompt.toString();
    }

    public static List<Message> buildMessages(List<Map<String, String>> history, String message) {
        List<Message> out = new ArrayList<>();
        for (Map<String, String> item : history) {
            String content = item.getOrDefault("content", "");
            if (content == null || content.isBlank()) {
                continue;
            }
            out.add("assistant".equals(item.get("role"))
                    ? new AssistantMessage(content)
                    : new UserMessage(content));
        }
        out.add(new UserMessage(message));
        return out;
    }

    public static OpenAiChatOptions requestOptions(AgentOptions options) {
        OpenAiChatOptions.Builder builder = OpenAiChatOptions.builder();
        if (options.model() != null && !options.model().isBlank()) {
            builder.model(options.model());
        }
        if (options.temperature() != null) {
            builder.temperature(Math.min(Math.max(options.temperature(), 0.0), 2.0));
        }
        if (options.maxTokens() != null) {
            builder.maxTokens(Math.min(Math.max(options.maxTokens(), 256), 32768));
        }
        if (options.topP() != null) {
            builder.topP(Math.min(Math.max(options.topP(), 0.0), 1.0));
        }
        if (options.frequencyPenalty() != null) {
            builder.frequencyPenalty(Math.min(Math.max(options.frequencyPenalty(), -2.0), 2.0));
        }
        if (options.presencePenalty() != null) {
            builder.presencePenalty(Math.min(Math.max(options.presencePenalty(), -2.0), 2.0));
        }
        return builder.build();
    }
}
