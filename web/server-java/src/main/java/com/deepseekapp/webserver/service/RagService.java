package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * RAG 情节素材库：
 * 小说 txt → DeepSeek 按情节拆段 → 阿里百炼 embedding → Elasticsearch kNN。
 *
 * <p>索引文档只保存可检索的情节摘要与标签，原文放 excerpt 供展示；
 * embedding 只在向量里参与检索，不返回给前端。</p>
 */
@Service
public class RagService {

    private static final ObjectMapper MAPPER = Json.MAPPER;
    private static final int MAX_TEXT_CHARS = 2_000_000;
    private static final int EMBEDDING_BATCH = 8;

    public record Scene(
            String id,
            double score,
            String title,
            String book,
            String plot,
            String excerpt,
            List<String> tags,
            List<String> characters,
            String sceneType,
            String emotion,
            String reusable,
            String createdAt
    ) {
    }

    public record ScenePage(List<Scene> items, long total, int page, int pageSize) {
    }

    private record HttpResult(int status, String body) {
    }

    private record SceneDraft(
            String title,
            String plot,
            String excerpt,
            List<String> tags,
            List<String> characters,
            String sceneType,
            String emotion,
            String reusable
    ) {
    }

    public static final class ImportJob {
        private final String id = UUID.randomUUID().toString().replace("-", "");
        private final String book;
        private volatile String status = "running";
        private volatile int progress;
        private volatile String phase = "排队中";
        private volatile String message = "";
        private volatile int chunksDone;
        private volatile int chunksTotal;
        private volatile int sceneCount;
        private volatile String error = "";

        ImportJob(String book) {
            this.book = book;
        }

        public String id() {
            return id;
        }

        public Map<String, Object> snapshot() {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("id", id);
            out.put("book", book);
            out.put("status", status);
            out.put("progress", progress);
            out.put("phase", phase);
            out.put("message", message);
            out.put("chunksDone", chunksDone);
            out.put("chunksTotal", chunksTotal);
            out.put("sceneCount", sceneCount);
            out.put("error", error);
            return out;
        }
    }

    private final AppProperties props;
    private final NovelAiService ai;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();
    private final ExecutorService importExecutor = Executors.newFixedThreadPool(2, runnable -> {
        Thread thread = new Thread(runnable, "rag-import");
        thread.setDaemon(true);
        return thread;
    });
    private final Map<String, ImportJob> jobs = new ConcurrentHashMap<>();
    private volatile boolean indexReady;

    public RagService(AppProperties props, NovelAiService ai) {
        this.props = props;
        this.ai = ai;
    }

    public Map<String, Object> status() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("esUrl", props.getRagEsUrl());
        out.put("index", props.getRagEsIndex());
        out.put("embeddingConfigured", !props.getDashscopeApiKey().isBlank());
        out.put("embeddingModel", props.getEmbeddingModel());
        try {
            Map<String, Object> stats = indexStats();
            out.putAll(stats);
            out.put("esOnline", true);
            out.put("error", "");
        } catch (Exception e) {
            out.put("esOnline", false);
            out.put("totalScenes", 0L);
            out.put("totalBooks", 0);
            out.put("tags", List.of());
            out.put("error", readableError(e));
        }
        return out;
    }

    private Map<String, Object> indexStats() throws IOException, InterruptedException {
        ensureIndex();
        String body = Json.write(Map.of(
                "size", 0,
                "track_total_hits", true,
                "aggs", Map.of(
                        "books", Map.of("terms", Map.of("field", "book", "size", 50)),
                        "tags", Map.of("terms", Map.of("field", "tags", "size", 80))
                )
        ));
        HttpResult result = request("POST", indexUrl() + "/_search", body, "application/json");
        if (result.status() >= 400) {
            throw new ApiException(503, "Elasticsearch 查询失败：" + abbreviate(result.body()));
        }
        JsonNode root = MAPPER.readTree(result.body());
        long total = root.path("hits").path("total").path("value").asLong(0);
        List<String> tags = buckets(root.path("aggregations").path("tags").path("buckets"));
        List<Map<String, Object>> books = bucketObjects(root.path("aggregations").path("books").path("buckets"));
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("totalScenes", total);
        out.put("totalBooks", books.size());
        out.put("books", books);
        out.put("tags", tags);
        return out;
    }

    public ImportJob startImport(String book, String text) {
        String clean = cleanText(text);
        if (clean.isBlank()) {
            throw new ApiException(400, "txt 内容为空");
        }
        if (clean.length() > MAX_TEXT_CHARS) {
            throw new ApiException(400, "文本过长（" + clean.length() + " 字），单次最多 " + MAX_TEXT_CHARS + " 字");
        }
        requireEmbedding();
        ensureIndexQuietly();
        String normalizedBook = (book == null || book.isBlank() ? "未命名作品" : book.trim());
        ImportJob job = new ImportJob(normalizedBook);
        jobs.put(job.id(), job);
        importExecutor.submit(() -> runImport(job, clean));
        return job;
    }

    public Map<String, Object> job(String id) {
        ImportJob job = jobs.get(id);
        if (job == null) {
            throw new ApiException(404, "导入任务不存在或服务已重启");
        }
        return job.snapshot();
    }

    private void runImport(ImportJob job, String text) {
        try {
            List<String> chunks = splitChunks(text, Math.max(2000, props.getRagChunkChars()));
            job.chunksTotal = chunks.size();
            job.phase = "DeepSeek 拆解情节";
            job.message = "共 " + chunks.size() + " 个文本片段";
            job.progress = 4;

            List<SceneDraft> drafts = new ArrayList<>();
            for (int i = 0; i < chunks.size(); i++) {
                if (Thread.currentThread().isInterrupted()) {
                    throw new IllegalStateException("导入被中断");
                }
                String previousTail = i == 0 ? "" : tail(chunks.get(i - 1), 300);
                List<SceneDraft> part = extractWithRetry(chunks.get(i), i, chunks.size(), previousTail, job.book);
                drafts.addAll(part);
                job.chunksDone = i + 1;
                job.progress = 5 + (int) Math.round(55.0 * (i + 1) / chunks.size());
                job.message = "已解析 " + (i + 1) + "/" + chunks.size() + " 段，得到 " + drafts.size() + " 个情节";
                if (drafts.size() > 3000) {
                    throw new IllegalStateException("拆解出的情节过多，请缩小文本或分批导入");
                }
            }

            if (drafts.isEmpty()) {
                throw new IllegalStateException("没有从文本中拆出可用情节");
            }
            job.sceneCount = drafts.size();
            job.phase = "生成向量";
            job.message = "正在调用百炼 embedding（共 " + drafts.size() + " 个情节）";
            job.progress = 62;

            List<List<Double>> vectors = embedAll(drafts, job);
            job.phase = "写入 Elasticsearch";
            job.message = "正在替换并写入索引";
            job.progress = 92;
            replaceBook(job.book, drafts, vectors);
            job.progress = 100;
            job.phase = "已完成";
            job.message = "已入库 " + drafts.size() + " 个可复用情节";
            job.status = "done";
        } catch (Exception e) {
            job.status = "failed";
            job.error = readableError(e);
            job.phase = "失败";
            job.message = job.error;
            job.progress = Math.max(job.progress, 1);
        }
    }

    private List<SceneDraft> extractWithRetry(String chunk, int index, int total,
                                             String previousTail, String book) {
        Exception last = null;
        for (int attempt = 0; attempt < 3; attempt++) {
            try {
                return extractScenes(chunk, index, total, previousTail, book);
            } catch (Exception e) {
                last = e;
                try {
                    Thread.sleep(800L * (attempt + 1));
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        throw new IllegalStateException("第 " + (index + 1) + " 段拆解失败：" + readableError(last));
    }

    private List<SceneDraft> extractScenes(String chunk, int index, int total,
                                           String previousTail, String book) throws Exception {
        String system = """
                你是资深中文小说编辑，负责把小说拆解成可复用的「情节素材」。
                你的任务不是续写，也不是概括全书，而是识别出一个个完整、自洽、可被后来者借鉴的情节桥段。
                """;
        String user = """
                请把下面这段小说文本按情节拆解成若干条可复用素材。文本可能是一个章节的一部分或整章。

                作品：《%s》
                片段位置：第 %d / %d 段
                %s
                当前片段：
                <TEXT>
                %s
                </TEXT>

                要求：
                1. 每条素材必须是一个相对完整的情节桥段，单条 plot 约 200~450 字，写清人物关系、目标、冲突推进、转折/爆点和收束。
                2. 不要把同一场景切得太碎；宁少勿滥，通常每段拆 1~5 条。
                3. excerpt 从原文中「原样摘录」120~300 字最有代表性的片段，不要改写；如果原文确实过短可少于 120 字。
                4. tags 3~6 个，用短词，例如：身份暴露、绝境逆转、强制对峙、误会、牺牲、打脸、悬疑反转、情感拉扯、追捕、背叛、觉醒。
                5. characters 写本情节中真正有行动/影响的人物名；sceneType 如 战斗/对峙/追逐/日常/情感/悬疑；emotion 写主要情绪。
                6. reusable 用 1~2 句说明这条情节「可复用的戏剧结构」，例如：先让读者以为 A 占上风，再用一个细节反转，让 B 获得道德高地。
                7. 不要虚构原文没有的关键事实；如果片段开头承接前文，可在 plot 中自然交代必要关系。
                8. 只输出严格的 JSON 数组，不要 markdown 代码块、解释或前后缀。

                输出格式：
                [{"title":"情节标题","plot":"情节概要","excerpt":"原文摘录","tags":["标签"],"characters":["人物"],"sceneType":"场景类型","emotion":"情绪","reusable":"可复用结构"}]
                """.formatted(book, index + 1, total,
                previousTail.isBlank() ? "" : "前一段结尾（仅供衔接，勿重复拆分为素材）：\n" + previousTail + "\n",
                chunk);
        String answer = ai.complete(system, user, new AiSettings("", 0.25, 8192, ""));
        List<SceneDraft> scenes = parseScenes(answer);
        if (scenes.isEmpty()) {
            throw new IllegalStateException("模型没有返回有效 JSON 情节");
        }
        return scenes;
    }

    private List<SceneDraft> parseScenes(String raw) throws IOException {
        String text = raw == null ? "" : raw.trim();
        if (text.startsWith("```")) {
            text = text.replaceFirst("^```[a-zA-Z]*\\s*", "").replaceFirst("\\s*```\\s*$", "").trim();
        }
        JsonNode array = null;
        int start = text.indexOf('[');
        int end = text.lastIndexOf(']');
        if (start >= 0 && end > start) {
            try {
                array = MAPPER.readTree(text.substring(start, end + 1));
            } catch (Exception ignored) {
                array = null;
            }
        }
        if (array == null) {
            int objStart = text.indexOf('{');
            int objEnd = text.lastIndexOf('}');
            if (objStart >= 0 && objEnd > objStart) {
                try {
                    JsonNode obj = MAPPER.readTree(text.substring(objStart, objEnd + 1));
                    if (obj.path("scenes").isArray()) {
                        array = obj.path("scenes");
                    }
                } catch (Exception ignored) {
                    array = null;
                }
            }
        }
        if (array == null || !array.isArray()) {
            return List.of();
        }
        List<SceneDraft> out = new ArrayList<>();
        for (JsonNode node : array) {
            if (!node.isObject()) continue;
            String title = text(node, "title");
            String plot = text(node, "plot");
            if (plot.isBlank()) plot = text(node, "summary");
            String excerpt = text(node, "excerpt");
            if (excerpt.isBlank()) excerpt = text(node, "source_excerpt");
            if (plot.isBlank() && excerpt.isBlank()) continue;
            if (plot.isBlank()) plot = excerpt.length() > 500 ? excerpt.substring(0, 500) : excerpt;
            if (title.isBlank()) title = plot.length() > 24 ? plot.substring(0, 24) : plot;
            out.add(new SceneDraft(
                    title,
                    plot,
                    excerpt,
                    stringList(node, "tags"),
                    stringList(node, "characters"),
                    text(node, "sceneType"),
                    text(node, "emotion"),
                    text(node, "reusable")
            ));
        }
        return out;
    }

    private List<List<Double>> embedAll(List<SceneDraft> drafts, ImportJob job) throws Exception {
        List<List<Double>> vectors = new ArrayList<>();
        for (int i = 0; i < drafts.size(); i += EMBEDDING_BATCH) {
            int to = Math.min(drafts.size(), i + EMBEDDING_BATCH);
            List<String> inputs = new ArrayList<>();
            for (int j = i; j < to; j++) {
                inputs.add(embeddingText(drafts.get(j)));
            }
            vectors.addAll(embed(inputs));
            job.progress = 62 + (int) Math.round(28.0 * to / drafts.size());
            job.message = "已生成 " + to + "/" + drafts.size() + " 个向量";
        }
        return vectors;
    }

    private List<List<Double>> embed(List<String> inputs) throws Exception {
        requireEmbedding();
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("model", props.getEmbeddingModel());
        body.put("input", inputs);
        body.put("dimensions", props.getEmbeddingDim());
        HttpResult result = request("POST", embeddingUrl(), Json.write(body), "application/json",
                Map.of("Authorization", "Bearer " + props.getDashscopeApiKey()));
        if (result.status() >= 400) {
            throw new IllegalStateException("百炼 embedding 调用失败：" + abbreviate(result.body()));
        }
        JsonNode root = MAPPER.readTree(result.body());
        JsonNode data = root.path("data");
        if (!data.isArray() || data.isEmpty()) {
            throw new IllegalStateException("百炼 embedding 返回为空");
        }
        List<List<Double>> vectors = new ArrayList<>();
        for (JsonNode item : data) {
            JsonNode embedding = item.path("embedding");
            List<Double> vector = new ArrayList<>(embedding.size());
            for (JsonNode value : embedding) vector.add(value.asDouble());
            if (vector.size() != props.getEmbeddingDim()) {
                throw new IllegalStateException("embedding 维度不一致：期望 " + props.getEmbeddingDim()
                        + "，实际 " + vector.size() + "（请检查 DASHSCOPE_EMBEDDING_MODEL / DIM）");
            }
            vectors.add(vector);
        }
        if (vectors.size() != inputs.size()) {
            throw new IllegalStateException("embedding 返回数量与输入不一致");
        }
        return vectors;
    }

    public ScenePage listScenes(int page, int pageSize, String q, String tag) {
        int safePage = Math.max(1, page);
        int safeSize = Math.max(1, Math.min(100, pageSize));
        try {
            ensureIndex();
            Map<String, Object> query;
            if (q != null && !q.isBlank()) {
                query = Map.of("multi_match", Map.of(
                        "query", q.trim(),
                        "fields", List.of("title^2", "plot", "tags^1.5", "characters", "reusable", "excerpt")
                ));
            } else {
                query = Map.of("match_all", Map.of());
            }
            if (tag != null && !tag.isBlank()) {
                query = Map.of("bool", Map.of(
                        "must", List.of(query),
                        "filter", List.of(Map.of("term", Map.of("tags", tag.trim())))
                ));
            }
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("from", (safePage - 1) * safeSize);
            body.put("size", safeSize);
            body.put("track_total_hits", true);
            body.put("query", query);
            body.put("sort", List.of(Map.of("createdAt", Map.of("order", "desc"))));
            body.put("_source", Map.of("excludes", List.of("embedding")));
            HttpResult result = request("POST", indexUrl() + "/_search", Json.write(body), "application/json");
            if (result.status() >= 400) {
                throw new ApiException(503, "Elasticsearch 查询失败：" + abbreviate(result.body()));
            }
            JsonNode root = MAPPER.readTree(result.body());
            long total = root.path("hits").path("total").path("value").asLong(0);
            List<Scene> scenes = parseHits(root);
            return new ScenePage(scenes, total, safePage, safeSize);
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(503, "读取情节素材失败：" + readableError(e));
        }
    }

    public List<Scene> search(String query, int size, List<String> tags) {
        if (query == null || query.isBlank()) {
            throw new ApiException(400, "请输入想找的情节描述");
        }
        int safeSize = Math.max(1, Math.min(30, size));
        try {
            ensureIndex();
            List<Double> vector = embed(List.of(query.trim())).get(0);
            Map<String, Object> knn = new LinkedHashMap<>();
            knn.put("field", "embedding");
            knn.put("query_vector", vector);
            knn.put("k", safeSize);
            knn.put("num_candidates", Math.max(50, safeSize * 10));
            List<String> cleanTags = tags == null ? List.of()
                    : tags.stream().filter(t -> t != null && !t.isBlank()).map(String::trim).distinct().toList();
            if (!cleanTags.isEmpty()) {
                knn.put("filter", Map.of("terms", Map.of("tags", cleanTags)));
            }
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("size", safeSize);
            body.put("track_total_hits", true);
            body.put("knn", knn);
            body.put("_source", Map.of("excludes", List.of("embedding")));
            HttpResult result = request("POST", indexUrl() + "/_search", Json.write(body), "application/json");
            if (result.status() >= 400) {
                throw new ApiException(503, "Elasticsearch 检索失败：" + abbreviate(result.body()));
            }
            return parseHits(MAPPER.readTree(result.body()));
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(503, "情节检索失败：" + readableError(e));
        }
    }

    public Map<String, Object> imitate(String query, int size, List<String> tags, String style, String extra) {
        List<Scene> references = search(query, size, tags);
        if (references.isEmpty()) {
            throw new ApiException(404, "素材库还没有可参考的情节，请先导入小说 txt");
        }
        StringBuilder refs = new StringBuilder();
        for (int i = 0; i < references.size(); i++) {
            Scene scene = references.get(i);
            refs.append("\n--- 参考 ").append(i + 1).append(" ---\n");
            refs.append("标题：").append(scene.title()).append('\n');
            refs.append("作品：").append(scene.book()).append('\n');
            refs.append("标签：").append(String.join("、", scene.tags())).append('\n');
            refs.append("情节：").append(clip(scene.plot(), 900)).append('\n');
            refs.append("可复用结构：").append(clip(scene.reusable(), 500)).append('\n');
        }
        String system = """
                你是中文小说作家。你的任务是根据作者的写作需求，并借鉴检索到的参考情节的「结构、冲突节奏与情绪曲线」，
                写出全新的小说正文。

                硬性要求：
                - 只借鉴参考情节的技法与结构，不照抄句子，不复用参考中的人物姓名、专有名词与具体事件；
                - 人物、背景、事件按作者需求重新设计，但冲突推进、转折点和情绪曲线要有可读性；
                - 只输出正文，不要标题、编号、解释、分析或 Markdown 标记；
                - 结尾要自然收束本段，不要写“下一章”之类的说明。
                """;
        String user = """
                作者想写的情节方向：
                %s
                %s%s
                参考情节（只作为结构参考，不要照抄）：
                %s
                """.formatted(
                query.trim(),
                style == null || style.isBlank() ? "" : "\n风格要求：" + style.trim() + "\n",
                extra == null || extra.isBlank() ? "" : "\n额外要求：" + extra.trim() + "\n",
                refs
        );
        String draft = ai.complete(system, user, new AiSettings("", 0.9, 8192, ""));
        if (draft == null || draft.isBlank()) {
            throw new ApiException(502, "AI 没有生成有效正文，请重试");
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("draft", draft.trim());
        out.put("references", references);
        out.put("query", query);
        return out;
    }

    private void replaceBook(String book, List<SceneDraft> drafts, List<List<Double>> vectors) throws Exception {
        ensureIndex();
        String deleteBody = Json.write(Map.of("query", Map.of("term", Map.of("book", book))));
        request("POST", indexUrl() + "/_delete_by_query?refresh=true", deleteBody, "application/json");

        String now = Instant.now().toString();
        StringBuilder bulk = new StringBuilder();
        for (int i = 0; i < drafts.size(); i++) {
            SceneDraft draft = drafts.get(i);
            Map<String, Object> doc = new LinkedHashMap<>();
            doc.put("title", draft.title());
            doc.put("book", book);
            doc.put("plot", draft.plot());
            doc.put("excerpt", draft.excerpt());
            doc.put("tags", draft.tags());
            doc.put("characters", draft.characters());
            doc.put("sceneType", draft.sceneType());
            doc.put("emotion", draft.emotion());
            doc.put("reusable", draft.reusable());
            doc.put("embedding", vectors.get(i));
            doc.put("createdAt", now);
            bulk.append("{\"index\":{\"_index\":\"").append(props.getRagEsIndex()).append("\"}}\n");
            bulk.append(Json.write(doc)).append('\n');
        }
        HttpResult result = request("POST", esUrl() + "/_bulk?refresh=true", bulk.toString(), "application/x-ndjson");
        if (result.status() >= 400) {
            throw new IllegalStateException("写入 Elasticsearch 失败：" + abbreviate(result.body()));
        }
        JsonNode root = MAPPER.readTree(result.body());
        if (root.path("errors").asBoolean(false)) {
            throw new IllegalStateException("Elasticsearch 批量写入存在失败项：" + abbreviate(result.body()));
        }
    }

    public void deleteBook(String book) {
        if (book == null || book.isBlank()) {
            throw new ApiException(400, "缺少作品名");
        }
        try {
            ensureIndex();
            String body = Json.write(Map.of("query", Map.of("term", Map.of("book", book.trim()))));
            HttpResult result = request("POST", indexUrl() + "/_delete_by_query?refresh=true", body, "application/json");
            if (result.status() >= 400) {
                throw new ApiException(503, "删除失败：" + abbreviate(result.body()));
            }
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(503, "删除失败：" + readableError(e));
        }
    }

    private List<Scene> parseHits(JsonNode root) {
        List<Scene> scenes = new ArrayList<>();
        JsonNode hits = root.path("hits").path("hits");
        if (!hits.isArray()) return scenes;
        for (JsonNode hit : hits) {
            JsonNode source = hit.path("_source");
            scenes.add(new Scene(
                    hit.path("_id").asText(""),
                    hit.path("_score").asDouble(0),
                    text(source, "title"),
                    text(source, "book"),
                    text(source, "plot"),
                    text(source, "excerpt"),
                    stringList(source, "tags"),
                    stringList(source, "characters"),
                    text(source, "sceneType"),
                    text(source, "emotion"),
                    text(source, "reusable"),
                    text(source, "createdAt")
            ));
        }
        return scenes;
    }

    private void ensureIndex() throws IOException, InterruptedException {
        if (indexReady) return;
        synchronized (this) {
            if (indexReady) return;
            HttpResult exists = request("HEAD", indexUrl(), null, null);
            if (exists.status() == 200) {
                indexReady = true;
                return;
            }
            Map<String, Object> mapping = new LinkedHashMap<>();
            mapping.put("settings", Map.of("number_of_shards", 1, "number_of_replicas", 0));
            Map<String, Object> properties = new LinkedHashMap<>();
            properties.put("title", Map.of("type", "text", "analyzer", "ik_max_word",
                    "fields", Map.of("keyword", Map.of("type", "keyword", "ignore_above", 256))));
            properties.put("book", Map.of("type", "keyword"));
            properties.put("plot", Map.of("type", "text", "analyzer", "ik_max_word"));
            properties.put("excerpt", Map.of("type", "text", "analyzer", "ik_max_word"));
            properties.put("tags", Map.of("type", "keyword"));
            properties.put("characters", Map.of("type", "keyword"));
            properties.put("sceneType", Map.of("type", "keyword"));
            properties.put("emotion", Map.of("type", "keyword"));
            properties.put("reusable", Map.of("type", "text", "analyzer", "ik_max_word"));
            properties.put("embedding", Map.of("type", "dense_vector",
                    "dims", props.getEmbeddingDim(), "index", true, "similarity", "cosine"));
            properties.put("createdAt", Map.of("type", "date"));
            mapping.put("mappings", Map.of("properties", properties));
            HttpResult created = request("PUT", indexUrl(), Json.write(mapping), "application/json");
            if (created.status() >= 400) {
                // ik 插件不可用时退回 standard，至少保证索引可用
                String fallback = Json.write(mapping).replace("ik_max_word", "standard");
                HttpResult retry = request("PUT", indexUrl(), fallback, "application/json");
                if (retry.status() >= 400) {
                    throw new ApiException(503, "创建 Elasticsearch 索引失败：" + abbreviate(retry.body()));
                }
            }
            indexReady = true;
        }
    }

    private void ensureIndexQuietly() {
        try {
            ensureIndex();
        } catch (Exception e) {
            throw new ApiException(503, "Elasticsearch 不可用：" + readableError(e));
        }
    }

    private void requireEmbedding() {
        if (props.getDashscopeApiKey().isBlank()) {
            throw new ApiException(503, "未配置百炼 embedding 密钥：请在 web/server/.env 设置 DASHSCOPE_API_KEY");
        }
    }

    private HttpResult request(String method, String url, String body, String contentType)
            throws IOException, InterruptedException {
        return request(method, url, body, contentType, Map.of());
    }

    private HttpResult request(String method, String url, String body, String contentType,
                               Map<String, String> extraHeaders)
            throws IOException, InterruptedException {
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(120));
        for (Map.Entry<String, String> header : extraHeaders.entrySet()) {
            builder.header(header.getKey(), header.getValue());
        }
        if (body == null) {
            builder.method(method, HttpRequest.BodyPublishers.noBody());
        } else {
            builder.header("Content-Type", contentType == null ? "application/json" : contentType);
            builder.method(method, HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
        }
        HttpResponse<String> response = http.send(builder.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        return new HttpResult(response.statusCode(), response.body() == null ? "" : response.body());
    }

    private String esUrl() {
        return props.getRagEsUrl().replaceAll("/+$", "");
    }

    private String indexUrl() {
        return esUrl() + "/" + props.getRagEsIndex();
    }

    private String embeddingUrl() {
        String base = props.getDashscopeBaseUrl().replaceAll("/+$", "");
        if (base.endsWith("/embeddings")) return base;
        return base + "/embeddings";
    }

    private String embeddingText(SceneDraft draft) {
        return "标题：" + draft.title()
                + "\n情节：" + draft.plot()
                + "\n标签：" + String.join("、", draft.tags())
                + "\n人物：" + String.join("、", draft.characters())
                + "\n场景：" + draft.sceneType()
                + "\n情绪：" + draft.emotion()
                + "\n可复用结构：" + draft.reusable();
    }

    private List<String> splitChunks(String text, int maxChars) {
        List<String> chunks = new ArrayList<>();
        String[] paragraphs = text.split("\\n\\s*\\n");
        StringBuilder current = new StringBuilder();
        for (String paragraph : paragraphs) {
            String clean = paragraph.trim();
            if (clean.isEmpty()) continue;
            if (current.length() > 0 && current.length() + clean.length() + 2 > maxChars) {
                chunks.add(current.toString().trim());
                current.setLength(0);
            }
            if (clean.length() > maxChars) {
                if (current.length() > 0) {
                    chunks.add(current.toString().trim());
                    current.setLength(0);
                }
                for (int start = 0; start < clean.length(); start += maxChars) {
                    chunks.add(clean.substring(start, Math.min(clean.length(), start + maxChars)));
                }
                continue;
            }
            if (current.length() > 0) current.append("\n\n");
            current.append(clean);
        }
        if (current.length() > 0) chunks.add(current.toString().trim());
        return chunks;
    }

    private static String cleanText(String input) {
        if (input == null) return "";
        String text = input.replace("\r\n", "\n").replace('\r', '\n').replace("\u0000", "");
        return text.replaceAll("[\\t ]+", " ").replaceAll("\\n{3,}", "\n\n").trim();
    }

    private static String tail(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(value.length() - max);
    }

    private static String clip(String value, int max) {
        if (value == null) return "";
        return value.length() <= max ? value : value.substring(0, max) + "…";
    }

    private static String text(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() ? "" : value.asText("").trim();
    }

    private static List<String> stringList(JsonNode node, String field) {
        JsonNode value = node.get(field);
        Set<String> out = new LinkedHashSet<>();
        if (value != null && value.isArray()) {
            for (JsonNode item : value) {
                String text = item.asText("").trim();
                if (!text.isEmpty()) out.add(text);
            }
        } else if (value != null && value.isTextual()) {
            for (String part : value.asText("").split("[,，、/]")) {
                if (!part.isBlank()) out.add(part.trim());
            }
        }
        return new ArrayList<>(out);
    }

    private static List<String> buckets(JsonNode buckets) {
        List<String> out = new ArrayList<>();
        if (!buckets.isArray()) return out;
        for (JsonNode bucket : buckets) {
            String key = bucket.path("key").asText("");
            if (!key.isBlank()) out.add(key);
        }
        return out;
    }

    private static List<Map<String, Object>> bucketObjects(JsonNode buckets) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (!buckets.isArray()) return out;
        for (JsonNode bucket : buckets) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("book", bucket.path("key").asText(""));
            item.put("count", bucket.path("doc_count").asLong(0));
            out.add(item);
        }
        return out;
    }

    private static String readableError(Exception e) {
        if (e == null) return "未知错误";
        String message = e.getMessage();
        if (message == null || message.isBlank()) message = e.getClass().getSimpleName();
        return message.replaceFirst("^Exception:\\s*", "");
    }

    private static String abbreviate(String value) {
        if (value == null) return "";
        return value.length() > 600 ? value.substring(0, 600) + "…" : value;
    }
}
