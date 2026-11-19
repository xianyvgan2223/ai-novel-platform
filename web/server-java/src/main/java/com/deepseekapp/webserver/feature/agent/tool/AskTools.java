package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.feature.agent.runtime.AgentAskRegistry;
import com.deepseekapp.webserver.feature.agent.runtime.AgentCancelledException;
import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * 让 Agent 向用户提问：给出若干选项，用户也可以自己输入。
 *
 * <p>工具会阻塞等待前端提交答案（最多 5 分钟），期间 SSE 心跳保持连接；
 * 用户取消运行时会立刻唤醒并中止。</p>
 */
@Component
public class AskTools {

    private static final int MAX_OPTIONS = 6;
    private static final int MAX_OPTION_CHARS = 80;
    private static final long MAX_WAIT_SECONDS = 300;

    private final AgentAskRegistry asks;
    private final AgentToolSupport support;

    public AskTools(AgentAskRegistry asks, AgentToolSupport support) {
        this.asks = asks;
        this.support = support;
    }

    @Tool(name = "ask_user",
            description = "向用户提问并给出可选项，用于关键信息缺失或存在多种合理方案时。"
                    + "用户可以选择其中一项，也可以自己输入其他答案。不要在能从工具或上文推断出答案时滥用。")
    public Map<String, Object> askUser(
            @ToolParam(description = "要问用户的问题，一句话说清") String question,
            @ToolParam(description = "3-5 个候选选项，简短明确") List<String> options,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        String text = question == null || question.isBlank() ? "请选择一个选项" : question.trim();
        List<String> cleaned = new ArrayList<>();
        for (String option : options == null ? List.<String>of() : options) {
            String value = option == null ? "" : option.trim();
            if (value.isEmpty()) {
                continue;
            }
            cleaned.add(value.length() > MAX_OPTION_CHARS ? value.substring(0, MAX_OPTION_CHARS) : value);
            if (cleaned.size() >= MAX_OPTIONS) {
                break;
            }
        }
        if (cleaned.isEmpty()) {
            throw new ApiException(400, "ask_user 至少需要一个选项");
        }

        Map<String, Object> args = new LinkedHashMap<>();
        args.put("question", text);
        args.put("options", cleaned);

        return support.traced(run, "ask_user", args, () -> {
            if (run == null) {
                throw new ApiException(400, "当前对话不可用，无法向用户提问");
            }
            String askId = "ask_" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
            // 先登记再发事件：用户可能在事件到达的瞬间就点了选项，顺序反了会丢答案
            CompletableFuture<String> future = asks.register(askId, run.deviceId());
            long deadline = System.currentTimeMillis() + MAX_WAIT_SECONDS * 1000;
            try {
                run.emit(AgentEvent.of("ask",
                        "id", askId, "question", text, "options", cleaned, "allowOther", true));
                while (System.currentTimeMillis() < deadline) {
                    if (run.cancelled()) {
                        asks.cancel(askId);
                        throw new AgentCancelledException();
                    }
                    try {
                        String answer = future.get(1, TimeUnit.SECONDS);
                        run.emit(AgentEvent.of("ask_answer", "id", askId, "answer", answer));
                        Map<String, Object> out = new LinkedHashMap<>();
                        out.put("answer", answer);
                        out.put("answered", true);
                        return out;
                    } catch (TimeoutException ignored) {
                        // 继续等待，同时保持取消检查
                    }
                }
                run.emit(AgentEvent.of("ask_answer", "id", askId, "answer", "", "timeout", true));
                Map<String, Object> out = new LinkedHashMap<>();
                out.put("answer", "");
                out.put("answered", false);
                out.put("timeout", true);
                out.put("note", "用户长时间未选择；请按最合理的默认方案继续，并在回答里说明这个假设");
                return out;
            } catch (ExecutionException e) {
                throw new AgentCancelledException();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new AgentCancelledException();
            } finally {
                asks.remove(askId);
            }
        });
    }
}
