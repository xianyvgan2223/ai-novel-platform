package com.deepseekapp.webserver.feature.writing.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 写作优化的提示词与 DeepSeek 调用。
 *
 * <p>浏览器只请求本服务，密钥不会下发到前端。
 * 密钥读取顺序：application.yml / 环境变量 DEEPSEEK_API_KEY → web/server/.env。</p>
 */
@Service
public class WritingService {

    /** 优化动作：key 与前端约定一致 */
    private static final Map<String, String> ACTION_PROMPTS = Map.of(
            "polish", "润色改写：不改变原意，优化措辞、节奏与语感，让表达更自然、准确、有余味",
            "deai", "去 AI 味：删掉模板化表达（如「首先/其次/总之/值得注意的是」、空泛排比、过度对称句、万能升华结尾），让文字像真人写的",
            "expand", "扩写：保留全部原有信息与情节，补充画面、动作、心理、环境等细节，篇幅约为原文的 1.6~2 倍",
            "condense", "精简：删掉重复、空话与过度修饰，保留全部关键信息，篇幅约为原文的 60%",
            "continue", "续写：紧接原文结尾自然写下去，延续人称、语气与情节线，不复述原文、不做总结",
            "structure", "结构诊断：不改写正文，以资深编辑的视角指出结构问题，并给出可执行的调整方案"
    );

    private static final Map<String, String> STYLE_HINTS = Map.of(
            "original", "保持原文风格与语感，只提升质量",
            "plain", "更日常口语，短句为主，少形容词",
            "literary", "更文学化，意象与通感，句式有呼吸感",
            "restrained", "更克制冷峻，少直接抒情，靠细节传递情绪",
            "hot", "更热血有张力，节奏快，情绪推得上去",
            "suspense", "更悬疑：信息差、留白、结尾留钩子",
            "ancient", "更古风，用词雅致，但不要堆砌生僻字"
    );

    private static final Map<String, String> STRENGTH_HINTS = Map.of(
            "light", "轻：小修小补，尽量保留原句",
            "medium", "中：句式和用词都可以调整，但结构与情节不动",
            "strong", "重：允许大改句段结构，只要核心信息和情绪不变"
    );

    private static final String NOT_CONFIGURED =
            "服务端未配置 AI 密钥：请在 web/server/.env 中设置 DEEPSEEK_API_KEY，然后重启服务";

    private final AppProperties props;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(20))
            .build();

    /** .env 只读一次，改完 .env 需要重启服务 */
    private Map<String, String> dotEnvValues;

    public WritingService(AppProperties props) {
        this.props = props;
    }

    /** 流式输出回调；controller 写响应失败时抛 IOException，用来中断上游读取 */
    @FunctionalInterface
    public interface DeltaSink {
        void accept(String delta) throws IOException;
    }

    public record AiConfig(String apiKey, String baseUrl, String model, long timeoutMs) {
    }

    /** 提前校验密钥，让 controller 在开始写 SSE 之前就能返回普通 JSON 错误 */
    public AiConfig requireConfig() {
        AiConfig config = resolveConfig();
        if (config.apiKey().isEmpty()) {
            throw new ApiException(503, NOT_CONFIGURED);
        }
        return config;
    }

    public void streamOptimize(Map<String, Object> body, DeltaSink sink) throws IOException {
        AiConfig config = requireConfig();
        List<String> actions = actionsOf(body);
        boolean structure = actions.contains("structure");
        Map<String, Object> settings = settingsOf(body);
        String extraPrompt = str(settings.get("systemPrompt"));

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("model", apiModel(firstNonBlank(str(settings.get("model")), config.model())));
        payload.put("messages", withExtraSystem(buildOptimizeMessages(body, actions), extraPrompt));
        payload.put("stream", true);
        payload.put("temperature", numOf(settings.get("temperature"), structure ? 0.6 : 0.9));
        payload.put("max_tokens", intOf(settings.get("maxTokens"), 4096));
        if (!enableThinking(settings)) {
            payload.put("thinking", Map.of("type", "disabled"));
        }

        HttpResponse<InputStream> response;
        try {
            response = http.send(request(config, payload), HttpResponse.BodyHandlers.ofInputStream());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(504, "AI 请求被中断");
        }
        if (response.statusCode() != 200) {
            String detail = new String(response.body().readAllBytes(), StandardCharsets.UTF_8);
            throw new ApiException(502, describeHttpError(response.statusCode(), detail));
        }

        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String trimmed = line.trim();
                if (!trimmed.startsWith("data:")) {
                    continue;
                }
                String data = trimmed.substring(5).trim();
                if (data.isEmpty() || "[DONE]".equals(data)) {
                    continue;
                }
                JsonNode chunk;
                try {
                    chunk = Json.MAPPER.readTree(data);
                } catch (Exception ignored) {
                    continue;
                }
                String delta = chunk.path("choices").path(0).path("delta").path("content").asText("");
                if (!delta.isEmpty()) {
                    sink.accept(delta);
                }
            }
        }
    }

    public List<Map<String, Object>> drawCards(Map<String, Object> body) throws IOException {
        AiConfig config = requireConfig();
        int count = countOf(body);
        Map<String, Object> settings = settingsOf(body);
        String extraPrompt = str(settings.get("systemPrompt"));
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("model", apiModel(firstNonBlank(str(settings.get("model")), config.model())));
        payload.put("messages", withExtraSystem(buildDrawMessages(body, count), extraPrompt));
        payload.put("stream", false);
        payload.put("temperature", numOf(settings.get("temperature"), 1.2));
        payload.put("max_tokens", intOf(settings.get("maxTokens"), Math.min(1200 + count * 700, 6000)));
        if (!enableThinking(settings)) {
            payload.put("thinking", Map.of("type", "disabled"));
        }

        HttpResponse<String> response;
        try {
            response = http.send(request(config, payload), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(504, "AI 请求被中断");
        }
        if (response.statusCode() != 200) {
            throw new ApiException(502, describeHttpError(response.statusCode(), response.body()));
        }

        JsonNode root = Json.MAPPER.readTree(response.body());
        String content = root.path("choices").path(0).path("message").path("content").asText("");
        return parseCards(content);
    }

    // ───────────────────────────── 提示词 ─────────────────────────────

    private List<Map<String, String>> buildOptimizeMessages(Map<String, Object> body, List<String> actions) {
        String text = str(body.get("text"));
        boolean wantsStructure = actions.contains("structure");

        String system = wantsStructure
                ? String.join("\n",
                "你是一位资深中文编辑，擅长诊断稿件结构。",
                "输出要求：只用简洁的小标题分点给建议，包括「整体判断」「具体问题」「修改方案」「建议的段落顺序」。",
                "每条建议要落到可执行的改法，不要泛泛而谈，不要复述原文。")
                : String.join("\n",
                "你是一位资深中文写作编辑，擅长把稿子改得自然、准确、有质感。",
                "输出要求：只输出改写后的正文本身。",
                "不要解释、不要点评、不要加「以下是修改后的版本」之类的前后缀，不要用 Markdown 代码块包裹。",
                "保留原文的段落划分与叙述人称；原文里的事实、人名、数字、专有名词不得改动。");

        List<String> constraints = new ArrayList<>();
        constraints.add("写作风格：" + STYLE_HINTS.getOrDefault(str(body.get("style")), STYLE_HINTS.get("original")));
        constraints.add("改动幅度：" + STRENGTH_HINTS.getOrDefault(str(body.get("strength")), STRENGTH_HINTS.get("medium")));
        String extra = str(body.get("extra")).trim();
        if (!extra.isEmpty()) {
            constraints.add("额外要求：" + extra);
        }

        List<String> actionLines = new ArrayList<>();
        for (int i = 0; i < actions.size(); i++) {
            actionLines.add((i + 1) + ". " + ACTION_PROMPTS.get(actions.get(i)));
        }

        String user = String.join("\n",
                "请按以下要求处理这篇稿子：",
                String.join("\n", actionLines),
                "",
                "约束：",
                String.join("\n", constraints),
                "",
                wantsStructure ? "待诊断的稿子：\n" : "原文：\n",
                text);

        return List.of(
                Map.of("role", "system", "content", system),
                Map.of("role", "user", "content", user));
    }

    private List<Map<String, String>> buildDrawMessages(Map<String, Object> body, int count) {
        boolean outline = "outline".equals(str(body.get("kind")));
        String role = outline
                ? "你是一位网文主编，擅长把题材和梗拆成能连载的长篇骨架。"
                : "你是一位网文短篇策划，擅长从一句梗里抽出能立刻开写的短篇点子。";
        List<String> fieldNames = outline
                ? List.of("题材与卖点", "三卷结构", "主要人物", "前五章节奏", "爽点与钩子")
                : List.of("核心冲突", "开场钩子", "主角设定", "爽点/看点");
        List<String> guide = outline
                ? List.of(
                "每张卡是一套可连载的长篇骨架，至少能支撑 60 万字。",
                "三卷结构要写清每卷的目标、主要冲突和卷末转折。",
                "主要人物写 3~4 个，标注身份、欲望与和主角的关系。",
                "前五章节奏要具体到每章发生什么、在哪一章抛出第一个钩子。")
                : List.of(
                "每张卡是一个可以直接开写的短篇（1~3 万字）点子。",
                "标题要有记忆点，不要用「XX的故事」这种平淡写法。",
                "logline 用一句话写清楚「谁、想要什么、被什么挡住」。",
                "开场钩子必须具体到一个场景或一句台词，不要写「故事一开始很悬疑」。");

        List<String> guideLines = new ArrayList<>();
        for (String line : guide) {
            guideLines.add("- " + line);
        }

        // 固定的创作规范放系统提示（同一类卡片的多次抽取可复用），用户输入放后面
        String system = String.join("\n",
                role,
                "只输出一个 JSON 对象，不要 Markdown、不要代码块围栏、不要任何解释文字。",
                "JSON 结构：{\"cards\":[{\"title\":\"标题\",\"logline\":\"一句话卖点\",\"fields\":[{\"label\":\"字段名\",\"value\":\"内容\"}]}]}",
                "fields 必须且只能包含这些 label：" + String.join("、", fieldNames) + "。",
                "",
                String.join("\n", guideLines));

        String extra = str(body.get("extra")).trim();
        String user = String.join("\n",
                "抽 " + count + " 组" + (outline ? "长篇大纲骨架" : "短篇点子") + "。",
                "cards 数组的长度必须恰好是 " + count + "，不要合并、不要省略、不要多给。",
                "题材：" + orDefault(str(body.get("genre")), "不限"),
                "视角：" + orDefault(str(body.get("perspective")), "第三人称"),
                "关键词/梗：" + orDefault(str(body.get("keywords")).trim(), "无，请自由发挥"),
                extra.isEmpty() ? "" : "额外要求：" + extra,
                "",
                count + " 组之间要有明显差异，不要只是换了名字的同构方案。");

        return List.of(
                Map.of("role", "system", "content", system),
                Map.of("role", "user", "content", user));
    }

    // ───────────────────────────── 结果解析 ─────────────────────────────

    private List<Map<String, Object>> parseCards(String raw) {
        String text = raw == null ? "" : raw.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        String candidate = start >= 0 && end > start ? text.substring(start, end + 1) : text;

        try {
            JsonNode root = Json.MAPPER.readTree(candidate);
            JsonNode cardsNode = root.path("cards");
            List<Map<String, Object>> cards = new ArrayList<>();
            if (cardsNode.isArray()) {
                for (JsonNode card : cardsNode) {
                    String title = card.path("title").asText("").trim();
                    String logline = card.path("logline").asText("").trim();
                    List<Map<String, String>> fields = new ArrayList<>();
                    for (JsonNode field : card.path("fields")) {
                        String label = field.path("label").asText("").trim();
                        String value = field.path("value").asText("").trim();
                        if (!label.isEmpty() && !value.isEmpty()) {
                            fields.add(Map.of("label", label, "value", value));
                        }
                    }
                    if (title.isEmpty() && logline.isEmpty() && fields.isEmpty()) {
                        continue;
                    }
                    Map<String, Object> out = new LinkedHashMap<>();
                    out.put("title", title.isEmpty() ? "灵感卡 " + (cards.size() + 1) : title);
                    out.put("logline", logline);
                    out.put("fields", fields);
                    cards.add(out);
                }
            }
            if (!cards.isEmpty()) {
                return cards;
            }
        } catch (Exception ignored) {
            // 模型没按 JSON 输出时，下面退化成一张原文卡
        }

        Map<String, Object> fallback = new LinkedHashMap<>();
        fallback.put("title", "灵感卡");
        fallback.put("logline", "");
        fallback.put("fields", List.of(Map.of("label", "AI 原文",
                "value", text.isEmpty() ? "模型没有返回内容" : text)));
        return List.of(fallback);
    }

    // ───────────────────────────── 内部工具 ─────────────────────────────

    private HttpRequest request(AiConfig config, Map<String, Object> payload) {
        return HttpRequest.newBuilder(URI.create(config.baseUrl() + "/chat/completions"))
                .timeout(Duration.ofMillis(config.timeoutMs()))
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + config.apiKey())
                .POST(HttpRequest.BodyPublishers.ofString(Json.write(payload), StandardCharsets.UTF_8))
                .build();
    }

    private AiConfig resolveConfig() {
        Map<String, String> env = dotEnv();
        String apiKey = firstNonBlank(props.getDeepseekApiKey(), env.get("DEEPSEEK_API_KEY"));
        String baseUrl = firstNonBlank(props.getDeepseekBaseUrl(), env.get("DEEPSEEK_BASE_URL"));
        if (baseUrl.isEmpty()) {
            baseUrl = "https://api.deepseek.com";
        }
        while (baseUrl.endsWith("/")) {
            baseUrl = baseUrl.substring(0, baseUrl.length() - 1);
        }
        String model = firstNonBlank(props.getDeepseekModel(), env.get("DEEPSEEK_MODEL"));
        if (model.isEmpty()) {
            model = "deepseek-chat";
        }
        long timeout = props.getAiTimeoutMs() > 0 ? props.getAiTimeoutMs() : 180_000L;
        return new AiConfig(apiKey.trim(), baseUrl, model, timeout);
    }

    /** Node 版用 web/server/.env 存密钥；Java 也读同一个文件，避免两套配置 */
    private Map<String, String> dotEnv() {
        if (dotEnvValues != null) {
            return dotEnvValues;
        }
        Map<String, String> values = new HashMap<>();
        String userDir = System.getProperty("user.dir");
        List<Path> candidates = List.of(
                Path.of(userDir, "..", "server", ".env"),
                Path.of(userDir, ".env"),
                Path.of(userDir, "..", ".env"));
        for (Path candidate : candidates) {
            if (!Files.isRegularFile(candidate)) {
                continue;
            }
            try {
                for (String line : Files.readAllLines(candidate, StandardCharsets.UTF_8)) {
                    String trimmed = line.trim();
                    if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                        continue;
                    }
                    int eq = trimmed.indexOf('=');
                    if (eq <= 0) {
                        continue;
                    }
                    String key = trimmed.substring(0, eq).trim();
                    String value = trimmed.substring(eq + 1).trim();
                    if (value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
                        value = value.substring(1, value.length() - 1);
                    }
                    values.putIfAbsent(key, value);
                }
                break;
            } catch (IOException ignored) {
                // 读不到就继续尝试下一个位置
            }
        }
        dotEnvValues = values;
        return values;
    }

    public List<String> actionsOf(Map<String, Object> body) {
        List<String> actions = new ArrayList<>();
        Object raw = body == null ? null : body.get("actions");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                String action = String.valueOf(item);
                if (ACTION_PROMPTS.containsKey(action) && !actions.contains(action)) {
                    actions.add(action);
                }
            }
        }
        return actions;
    }

    private int countOf(Map<String, Object> body) {
        Object raw = body == null ? null : body.get("count");
        int count = 3;
        if (raw instanceof Number number) {
            count = number.intValue();
        } else {
            try {
                count = Integer.parseInt(String.valueOf(raw));
            } catch (Exception ignored) {
                // 保持默认值
            }
        }
        return Math.min(Math.max(count, 1), 5);
    }

    private String describeHttpError(int status, String body) {
        String detail = "";
        try {
            detail = Json.MAPPER.readTree(body).path("error").path("message").asText("");
        } catch (Exception ignored) {
            detail = body == null ? "" : body.substring(0, Math.min(body.length(), 200));
        }
        if (status == 401) {
            return "AI 密钥无效，请检查服务端 DEEPSEEK_API_KEY";
        }
        if (status == 402) {
            return "AI 账户余额不足";
        }
        if (status == 429) {
            return "请求过于频繁，请稍后再试";
        }
        return detail.isEmpty() ? "AI 服务返回错误（HTTP " + status + "）" : "AI 服务返回错误：" + detail;
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    /** 本次请求的 AI 设置（与其它写作功能的 settings 结构一致） */
    private static Map<String, Object> settingsOf(Map<String, Object> body) {
        Object raw = body.get("settings");
        if (!(raw instanceof Map<?, ?> map)) {
            return Map.of();
        }
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            if (entry.getKey() != null) {
                out.put(String.valueOf(entry.getKey()), entry.getValue());
            }
        }
        return out;
    }

    /** 把用户填写的补充提示词追加到内置 system 提示后面 */
    private static List<Map<String, String>> withExtraSystem(List<Map<String, String>> messages, String extra) {
        String prompt = extra == null ? "" : extra.trim();
        if (prompt.isEmpty() || messages.isEmpty()) {
            return messages;
        }
        List<Map<String, String>> out = new ArrayList<>(messages);
        Map<String, String> first = out.get(0);
        if (!"system".equals(first.get("role"))) {
            return messages;
        }
        Map<String, String> replaced = new LinkedHashMap<>(first);
        replaced.put("content", first.getOrDefault("content", "") + "\n\n" + prompt);
        out.set(0, replaced);
        return out;
    }

    private static Double numOf(Object value, Double fallback) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        try {
            return Double.parseDouble(String.valueOf(value));
        } catch (Exception ignored) {
            return fallback;
        }
    }

    private static Integer intOf(Object value, Integer fallback) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(value));
        } catch (Exception ignored) {
            return fallback;
        }
    }

    private static boolean enableThinking(Map<String, Object> settings) {
        Object value = settings.get("enableThinking");
        if (value == null) {
            return true;
        }
        if (value instanceof Boolean bool) {
            return bool;
        }
        return !"0".equals(String.valueOf(value));
    }

    /** deepseek-pro 是 App 里的展示名，调用 API 时换成实际模型名 */
    private static String apiModel(String model) {
        return "deepseek-pro".equals(model) ? "deepseek-v4-pro" : model;
    }

    private static String orDefault(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value;
    }

    private static String firstNonBlank(String first, String second) {
        if (first != null && !first.isBlank()) {
            return first;
        }
        return second == null ? "" : second;
    }
}
