package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.context.AgentUsage;
import com.deepseekapp.webserver.feature.agent.context.TokenEstimator;
import com.deepseekapp.webserver.feature.agent.runtime.AgentCancelledException;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.support.ToolCallbacks;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.definition.ToolDefinition;
import org.springframework.stereotype.Component;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;

/**
 * Agent 的原始流式客户端（OpenAI 兼容协议）。
 *
 * <p>为什么不直接用 Spring AI：1.0.9 的 OpenAI 分片结构里没有 {@code reasoning_content}，
 * 无法把思考过程流式推给前端；同时 {@code thinking} 开关也不在 ChatOptions 里。
 * 这里自己解析 SSE，可以同时拿到 content、reasoning_content 与增量 tool_calls，
 * 并完整控制工具循环。</p>
 */
@Component
public class AgentLlmClient {

    private static final int RETRY_ATTEMPTS = 3;
    /** 首 token 之前的重试退避（毫秒）。 */
    private static final long[] RETRY_BACKOFF_MS = {800, 2000};

    public interface Sink {
        void content(String text);

        void reasoning(String text);

        /** 每轮请求结束时的真实 token 用量（来自 API usage 字段）。 */
        default void usage(AgentUsage usage) {
        }
    }

    private record ToolCall(String id, String name, StringBuilder arguments) {
    }

    private record RoundResult(String content, String reasoning, List<ToolCall> toolCalls) {
    }

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();
    private final AppProperties props;

    public AgentLlmClient(AppProperties props) {
        this.props = props;
    }

    /**
     * 执行一轮完整的对话（可能包含多轮工具调用），文本与思考过程通过 sink 实时推送。
     *
     * @return 最终助手正文（可能为空）
     */
    public String run(AgentOptions options,
                      String systemPrompt,
                      List<Map<String, Object>> conversation,
                      Object[] toolObjects,
                      Map<String, Object> toolContext,
                      BooleanSupplier cancelled,
                      Sink sink) {
        List<Map<String, Object>> messages = new ArrayList<>();
        Map<String, Object> system = new LinkedHashMap<>();
        system.put("role", "system");
        system.put("content", systemPrompt);
        messages.add(system);
        messages.addAll(conversation);

        List<Map<String, Object>> tools = toolDefinitions(toolObjects);
        Map<String, ToolCallback> callbacks = callbackMap(toolObjects);

        int maxRounds = Math.max(1, props.getAgentMaxRounds());
        for (int round = 0; round < maxRounds; round++) {
            RoundResult result = round(options, messages, tools, cancelled, sink);

            if (result.toolCalls().isEmpty()) {
                return result.content();
            }

            Map<String, Object> assistant = new LinkedHashMap<>();
            assistant.put("role", "assistant");
            assistant.put("content", result.content());
            List<Map<String, Object>> calls = new ArrayList<>();
            for (ToolCall call : result.toolCalls()) {
                Map<String, Object> function = new LinkedHashMap<>();
                function.put("name", call.name());
                function.put("arguments", call.arguments().toString());
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("id", call.id());
                item.put("type", "function");
                item.put("function", function);
                calls.add(item);
            }
            assistant.put("tool_calls", calls);
            if (!result.reasoning().isBlank()) {
                // 思考模式的工具回合必须把 reasoning_content 带回，否则部分模型会 400
                assistant.put("reasoning_content", result.reasoning());
            }
            messages.add(assistant);

            for (ToolCall call : result.toolCalls()) {
                if (cancelled.getAsBoolean()) {
                    throw new AgentCancelledException();
                }
                String output;
                ToolCallback callback = callbacks.get(call.name());
                if (callback == null) {
                    output = "未知工具：" + call.name();
                } else {
                    try {
                        String arguments = call.arguments().toString().trim();
                        output = callback.call(arguments.isEmpty() ? "{}" : arguments,
                                new ToolContext(toolContext));
                    } catch (AgentCancelledException e) {
                        throw e;
                    } catch (RuntimeException e) {
                        output = "工具执行失败：" + (e.getMessage() == null
                                ? e.getClass().getSimpleName() : e.getMessage());
                    }
                }
                Map<String, Object> toolMessage = new LinkedHashMap<>();
                toolMessage.put("role", "tool");
                toolMessage.put("tool_call_id", call.id());
                toolMessage.put("content", output == null ? "" : output);
                messages.add(toolMessage);
            }
        }

        // 轮次用尽：再给模型一次不带工具的收尾机会，让它把已经查到/生成的内容说清楚，
        // 而不是直接抛错让整轮回答作废
        RoundResult last = round(options, messages, List.of(), cancelled, sink);
        return last.content();
    }

    /**
     * 单轮请求 + 退避重试。
     *
     * <p>只重试「还没吐出任何内容」的失败（429 / 5xx / 连接失败），否则重试会把
     * 已经推给前端的文本再推一遍。重试期间保持取消检查。</p>
     */
    private RoundResult round(AgentOptions options, List<Map<String, Object>> messages,
                              List<Map<String, Object>> tools,
                              BooleanSupplier cancelled, Sink sink) {
        for (int attempt = 0; attempt < RETRY_ATTEMPTS; attempt++) {
            AtomicBoolean emitted = new AtomicBoolean(false);
            Sink counting = new Sink() {
                @Override
                public void content(String text) {
                    emitted.set(true);
                    sink.content(text);
                }

                @Override
                public void reasoning(String text) {
                    emitted.set(true);
                    sink.reasoning(text);
                }

                @Override
                public void usage(AgentUsage usage) {
                    sink.usage(usage);
                }
            };
            try {
                return options.stream()
                        ? streamRound(options, messages, tools, cancelled, counting)
                        : callRound(options, messages, tools, cancelled, counting);
            } catch (AgentCancelledException e) {
                throw e;
            } catch (ApiException e) {
                boolean retryable = e.getStatus() == 429 || e.getStatus() >= 500;
                if (attempt == RETRY_ATTEMPTS - 1 || emitted.get() || !retryable) {
                    throw e;
                }
                sleepBackoff(attempt, cancelled);
            }
        }
        throw new ApiException(502, "模型调用失败，请稍后重试");
    }

    private static void sleepBackoff(int attempt, BooleanSupplier cancelled) {
        long delay = RETRY_BACKOFF_MS[Math.min(attempt, RETRY_BACKOFF_MS.length - 1)];
        try {
            Thread.sleep(delay);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "模型调用被中断");
        }
        if (cancelled.getAsBoolean()) {
            throw new AgentCancelledException();
        }
    }

    /**
     * 一次性摘要调用：不流式、不带工具、关闭思考，只取返回文本。
     * 系统提示词与主对话保持一致，让提供方的 KV 缓存前缀仍然命中。
     */
    public String summarize(AgentOptions options, String systemPrompt,
                            List<Map<String, Object>> messages, int maxTokens) {
        List<Map<String, Object>> payloadMessages = new ArrayList<>();
        Map<String, Object> system = new LinkedHashMap<>();
        system.put("role", "system");
        system.put("content", systemPrompt);
        payloadMessages.add(system);
        payloadMessages.addAll(messages);

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("model", options.model());
        payload.put("messages", payloadMessages);
        payload.put("stream", false);
        payload.put("thinking", Map.of("type", "disabled"));
        payload.put("max_tokens", Math.max(256, Math.min(maxTokens, 8192)));

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(chatUrl(options.baseUrl())))
                .timeout(Duration.ofSeconds(Math.max(60, props.getAgentLlmTimeoutSeconds())))
                .header("Authorization", "Bearer " + options.apiKey())
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(Json.write(payload), StandardCharsets.UTF_8))
                .build();
        try {
            HttpResponse<String> response = http.send(request,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() >= 400) {
                throw new ApiException(response.statusCode(), "历史压缩失败：" + shorten(response.body()));
            }
            Map<String, Object> root = Json.asMap(Json.parse(response.body()));
            if (root == null) {
                throw new ApiException(502, "历史压缩失败：模型返回为空");
            }
            List<?> choices = root.get("choices") instanceof List<?> list ? list : List.of();
            Map<String, Object> choice = choices.isEmpty() ? null : Json.asMap(choices.get(0));
            Map<String, Object> message = choice == null ? null : Json.asMap(choice.get("message"));
            String content = message == null ? "" : text(message.get("content")).trim();
            if (content.isEmpty()) {
                throw new ApiException(502, "历史压缩失败：摘要为空");
            }
            return content;
        } catch (ApiException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "历史压缩被中断");
        } catch (IOException e) {
            throw new ApiException(502, "历史压缩失败：" + e.getMessage());
        }
    }

    /** 工具 schema 对上下文的固定占用估算（每轮都会随请求发送）。 */
    public static int estimateToolTokens(Object[] toolObjects) {
        List<Map<String, Object>> tools = toolDefinitions(toolObjects);
        return tools.isEmpty() ? 0 : TokenEstimator.estimate(Json.write(tools));
    }

    /** 解析 OpenAI 兼容的 usage 字段；没有有效数据时返回 null。 */
    static AgentUsage parseUsage(Object raw) {
        Map<String, Object> usage = Json.asMap(raw);
        if (usage == null) {
            return null;
        }
        int prompt = (int) number(usage.get("prompt_tokens"));
        int completion = (int) number(usage.get("completion_tokens"));
        int total = (int) number(usage.get("total_tokens"));
        int cached = 0;
        Map<String, Object> details = Json.asMap(usage.get("prompt_tokens_details"));
        if (details != null) {
            cached = (int) number(details.get("cached_tokens"));
        }
        if (cached <= 0) {
            cached = (int) number(usage.get("prompt_cache_hit_tokens"));
        }
        if (prompt <= 0 && completion <= 0 && total <= 0) {
            return null;
        }
        return new AgentUsage(prompt, completion, total > 0 ? total : prompt + completion, cached);
    }

    private RoundResult streamRound(AgentOptions options, List<Map<String, Object>> messages,
                                    List<Map<String, Object>> tools,
                                    BooleanSupplier cancelled, Sink sink) {
        if (cancelled.getAsBoolean()) {
            throw new AgentCancelledException();
        }
        Map<String, Object> payload = payload(options, messages, tools, true);
        HttpRequest request = request(options, payload);
        try {
            HttpResponse<InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
            if (response.statusCode() >= 400) {
                throw new ApiException(response.statusCode(), "模型调用失败：" + readBody(response.body()));
            }
            StringBuilder content = new StringBuilder();
            StringBuilder reasoning = new StringBuilder();
            Map<Integer, ToolCall> calls = new TreeMap<>();
            AgentUsage usage = null;

            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (cancelled.getAsBoolean()) {
                        throw new AgentCancelledException();
                    }
                    if (!line.startsWith("data:")) {
                        continue;
                    }
                    String data = line.substring(5).trim();
                    if (data.isEmpty()) {
                        continue;
                    }
                    if ("[DONE]".equals(data)) {
                        break;
                    }
                    Map<String, Object> root;
                    try {
                        root = Json.asMap(Json.parse(data));
                    } catch (RuntimeException e) {
                        continue;
                    }
                    if (root == null) {
                        continue;
                    }
                    // usage 只在最后一个分片上非空，且该分片的 delta 为空，必须单独读
                    AgentUsage parsed = parseUsage(root.get("usage"));
                    if (parsed != null) {
                        usage = parsed;
                    }
                    Map<String, Object> delta = firstDelta(root);
                    if (delta == null) {
                        continue;
                    }
                    String think = text(delta.get("reasoning_content"));
                    if (!think.isEmpty()) {
                        reasoning.append(think);
                        sink.reasoning(think);
                    }
                    String chunk = text(delta.get("content"));
                    if (!chunk.isEmpty()) {
                        content.append(chunk);
                        sink.content(chunk);
                    }
                    collectToolCalls(delta, calls);
                }
            }

            if (usage != null) {
                sink.usage(usage);
            }
            List<ToolCall> ordered = new ArrayList<>();
            for (ToolCall call : calls.values()) {
                if (call.name() != null && !call.name().isBlank()) {
                    ordered.add(call);
                }
            }
            return new RoundResult(content.toString(), reasoning.toString(), ordered);
        } catch (ApiException | AgentCancelledException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "模型调用被中断");
        } catch (IOException e) {
            throw new ApiException(502, "模型流读取失败：" + e.getMessage());
        }
    }

    private RoundResult callRound(AgentOptions options, List<Map<String, Object>> messages,
                                  List<Map<String, Object>> tools,
                                  BooleanSupplier cancelled, Sink sink) {
        if (cancelled.getAsBoolean()) {
            throw new AgentCancelledException();
        }
        Map<String, Object> payload = payload(options, messages, tools, false);
        HttpRequest request = request(options, payload);
        try {
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() >= 400) {
                throw new ApiException(response.statusCode(), "模型调用失败：" + shorten(response.body()));
            }
            Map<String, Object> root = Json.asMap(Json.parse(response.body()));
            if (root == null) {
                throw new ApiException(502, "模型返回为空");
            }
            AgentUsage usage = parseUsage(root.get("usage"));
            List<?> choices = root.get("choices") instanceof List<?> list ? list : List.of();
            Map<String, Object> choice = choices.isEmpty() ? null : Json.asMap(choices.get(0));
            Map<String, Object> message = choice == null ? null : Json.asMap(choice.get("message"));
            if (message == null) {
                throw new ApiException(502, "模型返回格式不正确");
            }
            String content = text(message.get("content"));
            String reasoning = text(message.get("reasoning_content"));
            if (!reasoning.isBlank()) {
                sink.reasoning(reasoning);
            }
            if (!content.isBlank()) {
                sink.content(content);
            }
            if (usage != null) {
                sink.usage(usage);
            }
            List<ToolCall> calls = new ArrayList<>();
            if (message.get("tool_calls") instanceof List<?> list) {
                int index = 0;
                for (Object item : list) {
                    Map<String, Object> call = Json.asMap(item);
                    Map<String, Object> function = call == null ? null : Json.asMap(call.get("function"));
                    if (function == null) {
                        continue;
                    }
                    String id = text(call.get("id"));
                    calls.add(new ToolCall(id.isEmpty() ? "call_" + index : id,
                            text(function.get("name")),
                            new StringBuilder(text(function.get("arguments")))));
                    index++;
                }
            }
            return new RoundResult(content, reasoning, calls);
        } catch (ApiException e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "模型调用被中断");
        } catch (IOException e) {
            throw new ApiException(502, "模型调用失败：" + e.getMessage());
        }
    }

    private static Map<String, Object> payload(AgentOptions options, List<Map<String, Object>> messages,
                                               List<Map<String, Object>> tools, boolean stream) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("model", options.model());
        payload.put("messages", messages);
        payload.put("stream", stream);
        if (stream) {
            // 最后一个分片带 usage；不显式打开的话部分兼容网关会省略整个字段
            payload.put("stream_options", Map.of("include_usage", true));
        }
        if (!tools.isEmpty()) {
            payload.put("tools", tools);
        }
        if (options.temperature() != null) {
            payload.put("temperature", clamp(options.temperature(), 0.0, 2.0));
        }
        if (options.maxTokens() != null) {
            payload.put("max_tokens", Math.min(Math.max(options.maxTokens(), 256), 32768));
        }
        if (options.topP() != null) {
            payload.put("top_p", clamp(options.topP(), 0.0, 1.0));
        }
        if (options.frequencyPenalty() != null) {
            payload.put("frequency_penalty", clamp(options.frequencyPenalty(), -2.0, 2.0));
        }
        if (options.presencePenalty() != null) {
            payload.put("presence_penalty", clamp(options.presencePenalty(), -2.0, 2.0));
        }
        if (!options.thinking()) {
            payload.put("thinking", Map.of("type", "disabled"));
        } else {
            payload.put("reasoning_effort", options.reasoningEffort());
        }
        return payload;
    }

    private HttpRequest request(AgentOptions options, Map<String, Object> payload) {
        return HttpRequest.newBuilder()
                .uri(URI.create(chatUrl(options.baseUrl())))
                .timeout(Duration.ofSeconds(Math.max(30, props.getAgentLlmTimeoutSeconds())))
                .header("Authorization", "Bearer " + options.apiKey())
                .header("Content-Type", "application/json")
                .header("Accept", "text/event-stream")
                .POST(HttpRequest.BodyPublishers.ofString(Json.write(payload), StandardCharsets.UTF_8))
                .build();
    }

    private static List<Map<String, Object>> toolDefinitions(Object[] toolObjects) {
        List<Map<String, Object>> tools = new ArrayList<>();
        if (toolObjects == null || toolObjects.length == 0) {
            return tools;
        }
        for (ToolCallback callback : ToolCallbacks.from(toolObjects)) {
            ToolDefinition definition = callback.getToolDefinition();
            Map<String, Object> function = new LinkedHashMap<>();
            function.put("name", definition.name());
            function.put("description", definition.description());
            function.put("parameters", Json.parse(definition.inputSchema()));
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("type", "function");
            item.put("function", function);
            tools.add(item);
        }
        // 反射拿到的工具顺序不保证跨进程一致；按名字排序，保证每次请求的前缀逐字节相同
        tools.sort(java.util.Comparator.comparing(item ->
                String.valueOf(((Map<?, ?>) item.get("function")).get("name"))));
        return tools;
    }

    private static Map<String, ToolCallback> callbackMap(Object[] toolObjects) {
        Map<String, ToolCallback> out = new LinkedHashMap<>();
        if (toolObjects == null) {
            return out;
        }
        for (ToolCallback callback : ToolCallbacks.from(toolObjects)) {
            out.put(callback.getToolDefinition().name(), callback);
        }
        return out;
    }

    private static void collectToolCalls(Map<String, Object> delta, Map<Integer, ToolCall> calls) {
        if (!(delta.get("tool_calls") instanceof List<?> list)) {
            return;
        }
        for (Object item : list) {
            Map<String, Object> call = Json.asMap(item);
            if (call == null) {
                continue;
            }
            int index = (int) number(call.get("index"));
            ToolCall existing = calls.computeIfAbsent(index,
                    key -> new ToolCall("", "", new StringBuilder()));
            String id = text(call.get("id"));
            if (!id.isEmpty()) {
                existing = new ToolCall(id, existing.name(), existing.arguments());
            }
            Map<String, Object> function = Json.asMap(call.get("function"));
            String name = function == null ? "" : text(function.get("name"));
            if (function != null && !name.isEmpty()) {
                existing = new ToolCall(existing.id(), name, existing.arguments());
            }
            if (function != null && function.get("arguments") != null) {
                existing.arguments().append(text(function.get("arguments")));
            }
            calls.put(index, existing);
        }
    }

    private static Map<String, Object> firstDelta(Map<String, Object> root) {
        if (!(root.get("choices") instanceof List<?> choices) || choices.isEmpty()) {
            return null;
        }
        Map<String, Object> choice = Json.asMap(choices.get(0));
        return choice == null ? null : Json.asMap(choice.get("delta"));
    }

    private static String chatUrl(String baseUrl) {
        String base = baseUrl == null || baseUrl.isBlank() ? "https://api.deepseek.com" : baseUrl.trim();
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        if (base.endsWith("/v1")) {
            return base + "/chat/completions";
        }
        return base + "/v1/chat/completions";
    }

    private static String readBody(InputStream in) {
        try (InputStream stream = in) {
            return shorten(new String(stream.readAllBytes(), StandardCharsets.UTF_8));
        } catch (IOException e) {
            return "HTTP 错误";
        }
    }

    private static String shorten(String text) {
        String value = text == null ? "" : text;
        return value.length() > 300 ? value.substring(0, 300) : value;
    }

    private static String text(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static double number(Object value) {
        return value instanceof Number n ? n.doubleValue() : 0;
    }

    private static double clamp(double value, double min, double max) {
        return Math.min(max, Math.max(min, value));
    }
}
