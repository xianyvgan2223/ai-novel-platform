package com.deepseekapp.webserver.feature.rag.service;

import com.deepseekapp.webserver.ai.AiSettings;
import com.deepseekapp.webserver.ai.NovelAiService;
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
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * RAG 情节素材库：
 * 小说 txt → 格式检测/章节结构化 → 按情节弧组窗口（带重叠）→ DeepSeek 并行提炼（带续接状态）
 * → 跨窗口合并去重 → 阿里百炼 embedding → Elasticsearch kNN。
 *
 * <p>导入分两阶段：analyze 只做解析和分块（可暂停给用户预览/调整），start 才真正调用 LLM 提炼。
 * 窗口与每个窗口的模型原始输出都保存在任务里，切换页面后可通过 /api/rag/jobs 恢复进度。</p>
 */
@Service
public class RagService {

    private static final ObjectMapper MAPPER = Json.MAPPER;
    private static final int MAX_TEXT_CHARS = 2_000_000;
    private static final int EMBEDDING_BATCH = 8;
    private static final int MAX_SCENES = 3000;

    /** AI 辅助章节识别时读取的开头字数：覆盖若干章，用来推断标题格式。 */
    private static final int AI_CHAPTER_SAMPLE_CHARS = 20_000;

    private static final String AI_CHAPTER_SYSTEM = """
            你是小说排版分析助手。用户会给你一部小说的开头片段，你要判断它是否存在章节标题行，
            并给出一条能匹配全书所有章节标题的 Java 正则表达式。
            只输出 JSON，不要输出解释或 Markdown：
            {"hasChapters": true, "pattern": "^第[0-9一二三四五六七八九十百千两]+章.*$"}
            要求：
            1. pattern 用整行匹配（Java matches），只匹配标题行，不能匹配正文；
            2. 标题后面通常带标题文字，允许可选的空格、冒号、顿号等分隔；
            3. 没有章节标题时输出 {"hasChapters": false, "pattern": ""}。
            """;

    private static final String AI_CHAPTER_INSTRUCTION =
            "判断下面这段小说开头是否存在章节标题行，并按系统要求输出 JSON。";

    /** 章节判断只需要一小段 JSON：低温、限长，避免拖慢导入。 */
    private static final AiSettings AI_CHAPTER_OPTIONS = new AiSettings("", 0.1, 500, null, true);

    private static final int WINDOW_MIN = 4000;
    private static final int WINDOW_MAX = 30000;
    private static final int OVERLAP_MAX = 5000;
    private static final int CONCURRENCY_MIN = 1;
    private static final int CONCURRENCY_MAX = 8;

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

    /** 单个情节弧窗口的实时状态（前端进度/原始输出用）。 */
    public static final class WindowState {
        public final int index;
        public final String title;
        public final String chapterRange;
        public final int chars;
        public final String text;
        public volatile String status = "pending";
        public volatile int sceneCount;
        public volatile String error = "";
        public volatile String rawOutput = "";
        public volatile long startedAt;
        public volatile long finishedAt;
        private volatile List<SceneDraft> scenes = List.of();

        WindowState(int index, String title, String chapterRange, int chars, String text) {
            this.index = index;
            this.title = title;
            this.chapterRange = chapterRange;
            this.chars = chars;
            this.text = text;
        }

        long elapsedMs() {
            if (startedAt <= 0) {
                return 0;
            }
            long end = finishedAt > 0 ? finishedAt : System.currentTimeMillis();
            return Math.max(0, end - startedAt);
        }
    }

    /** 一次导入任务：解析结果、窗口状态、进度与统计都在这里。 */
    public static final class ImportJob {
        public final String id = UUID.randomUUID().toString().replace("-", "");
        public final String book;
        public volatile String text;
        public volatile RagDocumentParser.ParsedDocument parsed;
        public volatile int windowChars;
        public volatile int overlapChars;
        public volatile int concurrency;
        public volatile String status = "parsing";
        public volatile String phase = "解析文本";
        public volatile int progress;
        public volatile String message = "";
        public volatile String error = "";
        /** 非致命问题（AI 章节识别失败、回退到段落分窗等），供前端提示。 */
        public final List<String> warnings = Collections.synchronizedList(new ArrayList<>());
        /** AI 判断出的章节标题正则；空串表示未识别到。 */
        public volatile String chapterGuess = "";
        /** AI 章节识别是否已经跑过：同一任务重新分块时复用结果，避免重复调用。 */
        public volatile boolean chapterGuessDone;
        public volatile String chapterGuessWarning = "";
        public volatile int sceneCount;
        public volatile int mergedCount;
        public final long createdAt = System.currentTimeMillis();
        public volatile long startedAt;
        public volatile long finishedAt;
        public final List<WindowState> windows = Collections.synchronizedList(new ArrayList<>());

        ImportJob(String book, String text, int windowChars, int overlapChars, int concurrency) {
            this.book = book;
            this.text = text;
            this.windowChars = windowChars;
            this.overlapChars = overlapChars;
            this.concurrency = concurrency;
        }

        int chunksDone() {
            int done = 0;
            synchronized (windows) {
                for (WindowState window : windows) {
                    if ("done".equals(window.status) || "failed".equals(window.status)) {
                        done++;
                    }
                }
            }
            return done;
        }
    }

    static final String SCENE_EXTRACT_RULES = """
            请把用户消息里的这段小说文本按情节拆解成若干条可复用素材。文本可能是一个章节的一部分或整章。

            要求：
            1. 每条素材必须是一个相对完整的情节桥段，单条 plot 约 200~450 字，写清人物关系、目标、冲突推进、转折/爆点和收束。
            2. 不要把同一场景切得太碎；宁少勿滥，通常每段拆 1~5 条。
            3. excerpt 从原文中「原样摘录」120~300 字最有代表性的片段，不要改写；如果原文确实过短可少于 120 字。
            4. tags 3~6 个，用短词，例如：身份暴露、绝境逆转、强制对峙、误会、牺牲、打脸、悬疑反转、情感拉扯、追捕、背叛、觉醒。
            5. characters 写本情节中真正有行动/影响的人物名；sceneType 如 战斗/对峙/追逐/日常/情感/悬疑；emotion 写主要情绪。
            6. reusable 用 1~2 句说明这条情节「可复用的戏剧结构」，例如：先让读者以为 A 占上风，再用一个细节反转，让 B 获得道德高地。
            7. 不要虚构原文没有的关键事实；如果片段开头承接前文，可在 plot 中自然交代必要关系。
            8. 如果这段文本开头/结尾是一个尚未完结的情节（承接上一窗口或延续到下一窗口），不要硬造结局，也不要把半截情节当成完整素材；只输出本窗口内相对完整的部分。
            9. 只输出严格的 JSON 数组，不要 markdown 代码块、解释或前后缀。

            输出格式：
            [{"title":"情节标题","plot":"情节概要","excerpt":"原文摘录","tags":["标签"],"characters":["人物"],"sceneType":"场景类型","emotion":"情绪","reusable":"可复用结构"}]
            """;

    private static final String SCENE_EXTRACT_SYSTEM = """
            你是资深中文小说编辑，负责把小说拆解成可复用的「情节素材」。
            你的任务不是续写，也不是概括全书，而是识别出一个个完整、自洽、可被后来者借鉴的情节桥段。

            """ + SCENE_EXTRACT_RULES;

    private final AppProperties props;
    private final NovelAiService ai;
    private final RagSettingsService ragSettings;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();
    private final ExecutorService runExecutor = Executors.newFixedThreadPool(2,
            daemonFactory("rag-import"));
    private final Map<String, ImportJob> jobs = new ConcurrentHashMap<>();
    private volatile boolean indexReady;

    public RagService(AppProperties props, NovelAiService ai, RagSettingsService ragSettings) {
        this.props = props;
        this.ai = ai;
        this.ragSettings = ragSettings;
    }

    // ============================================================
    //  导入：解析 → 预览/等待 → 提炼（并行）→ 合并 → embedding → 入库
    // ============================================================

    /** 只做解析与分块：状态为 waiting（手动模式）或直接开始提炼（自动模式）。 */
    public Map<String, Object> analyze(String book, String rawText) {
        cleanupJobs();
        String safeBook = (book == null || book.isBlank()) ? "未命名作品" : book.trim();
        String text = rawText == null ? "" : rawText;
        if (RagDocumentParser.normalize(text).isBlank()) {
            throw new ApiException(400, "txt 内容为空");
        }
        if (text.length() > MAX_TEXT_CHARS) {
            throw new ApiException(400, "文本过长（" + text.length() + " 字），单次最多 " + MAX_TEXT_CHARS + " 字");
        }
        requireEmbedding();
        ensureIndexQuietly();

        boolean manual = ragSettings.manualExtract();
        ImportJob job = new ImportJob(safeBook, text, ragSettings.windowChars(),
                ragSettings.overlapChars(), ragSettings.concurrency());
        parseJob(job);
        job.status = manual ? "waiting" : "extracting";
        job.phase = manual ? "等待开始提炼" : "准备提炼";
        job.progress = manual ? 4 : 5;
        job.message = buildParseMessage(job, manual);
        jobs.put(job.id, job);
        if (!manual) {
            submitRun(job);
        }
        return jobDetail(job);
    }

    /** 手动开始提炼（可带新的分块参数，参数变化时先重新分块）。 */
    public Map<String, Object> start(String jobId, Map<String, Object> body) {
        ImportJob job = requireJob(jobId);
        if (!"waiting".equals(job.status) && !"failed".equals(job.status)) {
            throw new ApiException(400, "当前任务状态为「" + job.status + "」，不能重复开始提炼");
        }
        if (applyOverrides(job, body)) {
            parseJob(job);
        }
        resetWindowStates(job);
        job.status = "extracting";
        job.phase = "准备提炼";
        job.progress = 5;
        job.error = "";
        job.startedAt = 0;
        job.finishedAt = 0;
        job.sceneCount = 0;
        job.mergedCount = 0;
        job.message = "开始提炼 " + job.windows.size() + " 个窗口（并行 " + job.concurrency + "）";
        submitRun(job);
        return jobDetail(job);
    }

    /** 重新分块（只在未开始提炼时可用）。 */
    public Map<String, Object> resplit(String jobId, Map<String, Object> body) {
        ImportJob job = requireJob(jobId);
        if (!"waiting".equals(job.status) && !"failed".equals(job.status)) {
            throw new ApiException(400, "提炼已开始，不能再调整分块");
        }
        applyOverrides(job, body);
        parseJob(job);
        job.status = "waiting";
        job.phase = "等待开始提炼";
        job.progress = 4;
        job.error = "";
        job.sceneCount = 0;
        job.mergedCount = 0;
        job.message = buildParseMessage(job, true);
        return jobDetail(job);
    }

    /** 最近任务列表（运行中的排前面），供切页后恢复进度。 */
    public List<Map<String, Object>> jobs() {
        cleanupJobs();
        List<ImportJob> list = new ArrayList<>(jobs.values());
        list.sort((a, b) -> {
            boolean ar = isRunning(a.status);
            boolean br = isRunning(b.status);
            if (ar != br) {
                return ar ? -1 : 1;
            }
            return Long.compare(b.createdAt, a.createdAt);
        });
        List<Map<String, Object>> out = new ArrayList<>();
        for (ImportJob job : list) {
            out.add(jobSummary(job));
        }
        return out;
    }

    public Map<String, Object> job(String jobId) {
        return jobDetail(requireJob(jobId));
    }

    /** 单窗口详情：含窗口原文、该窗口 DeepSeek 原始输出、解析出的情节。 */
    public Map<String, Object> window(String jobId, int index) {
        ImportJob job = requireJob(jobId);
        WindowState window;
        synchronized (job.windows) {
            if (index < 0 || index >= job.windows.size()) {
                throw new ApiException(404, "窗口不存在：" + index);
            }
            window = job.windows.get(index);
        }
        Map<String, Object> out = windowSummary(window);
        out.put("text", window.text);
        out.put("rawOutput", window.rawOutput);
        List<Map<String, Object>> scenes = new ArrayList<>();
        for (SceneDraft draft : window.scenes) {
            scenes.add(sceneMap(draft));
        }
        out.put("scenes", scenes);
        return out;
    }

    /** 兼容旧接口：导入后立即提炼（不受 manualExtract 设置影响）。 */
    public Map<String, Object> startImport(String book, String text) {
        String safeBook = (book == null || book.isBlank()) ? "未命名作品" : book.trim();
        ImportJob job = new ImportJob(safeBook, text == null ? "" : text, ragSettings.windowChars(),
                ragSettings.overlapChars(), ragSettings.concurrency());
        if (text == null || RagDocumentParser.normalize(text).isBlank()) {
            throw new ApiException(400, "txt 内容为空");
        }
        if (text.length() > MAX_TEXT_CHARS) {
            throw new ApiException(400, "文本过长（" + text.length() + " 字），单次最多 " + MAX_TEXT_CHARS + " 字");
        }
        requireEmbedding();
        ensureIndexQuietly();
        parseJob(job);
        job.status = "waiting";
        job.phase = "等待开始提炼";
        job.progress = 4;
        jobs.put(job.id, job);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("windowChars", job.windowChars);
        body.put("overlapChars", job.overlapChars);
        body.put("concurrency", job.concurrency);
        start(job.id, body);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("jobId", job.id);
        out.put("book", job.book);
        out.put("chars", job.text.length());
        return out;
    }

    private void parseJob(ImportJob job) {
        RagDocumentParser.ParsedDocument parsed = RagDocumentParser.parse(job.text,
                job.windowChars, job.overlapChars, job.chapterGuess);
        job.warnings.clear();
        if (parsed.chapters().isEmpty()) {
            if (!job.chapterGuessDone) {
                parsed = aiChapterFallback(job, parsed);
            } else if (!job.chapterGuessWarning.isEmpty()) {
                job.warnings.add(job.chapterGuessWarning);
            }
        }
        if (parsed.windows().isEmpty()) {
            throw new ApiException(400, "没有解析出可提炼的文本窗口");
        }
        if (parsed.windows().size() > RagDocumentParser.maxWindows()) {
            throw new ApiException(400, "文本将分成 " + parsed.windows().size()
                    + " 个窗口，超过上限 " + RagDocumentParser.maxWindows() + "，请增大窗口字数或分卷导入");
        }
        job.parsed = parsed;
        job.text = parsed.text();
        synchronized (job.windows) {
            job.windows.clear();
            for (RagDocumentParser.Window window : parsed.windows()) {
                job.windows.add(new WindowState(window.index(), window.title(), window.chapterRange(),
                        window.chars(), window.text()));
            }
        }
    }

    /**
     * 内置规则识别不到章节时的 AI 兜底：只让模型判断“标题长什么样”，
     * 规则仍由本地应用到全文。任何一步失败都只记警告并保留按段落分窗，不打断导入。
     */
    private RagDocumentParser.ParsedDocument aiChapterFallback(ImportJob job,
                                                               RagDocumentParser.ParsedDocument parsed) {
        job.chapterGuessDone = true;
        String sample = head(parsed.text(), AI_CHAPTER_SAMPLE_CHARS);
        String raw;
        try {
            raw = ai.complete(AI_CHAPTER_SYSTEM,
                    AI_CHAPTER_INSTRUCTION + "\n\n<novel>\n" + sample + "\n</novel>",
                    AI_CHAPTER_OPTIONS);
        } catch (RuntimeException e) {
            return aiChapterGiveUp(job, parsed, "AI 章节识别失败：" + readableError(e));
        }
        Map<String, Object> guess = parseChapterGuess(raw);
        if (guess == null) {
            return aiChapterGiveUp(job, parsed, "AI 章节识别返回格式异常");
        }
        Object flag = guess.get("hasChapters");
        boolean hasChapters = Boolean.TRUE.equals(flag) || "true".equalsIgnoreCase(String.valueOf(flag));
        String pattern = guess.get("pattern") == null ? "" : String.valueOf(guess.get("pattern")).trim();
        if (!hasChapters || pattern.isEmpty()) {
            return aiChapterGiveUp(job, parsed, "AI 判断本文没有章节标题");
        }
        RagDocumentParser.ParsedDocument retried = RagDocumentParser.parse(parsed.text(),
                job.windowChars, job.overlapChars, pattern);
        if (retried.chapters().isEmpty()) {
            return aiChapterGiveUp(job, parsed, "AI 给出的章节规则没有匹配到标题");
        }
        job.chapterGuess = pattern;
        job.chapterGuessWarning = "";
        return retried;
    }

    private RagDocumentParser.ParsedDocument aiChapterGiveUp(ImportJob job,
                                                             RagDocumentParser.ParsedDocument parsed,
                                                             String reason) {
        job.chapterGuess = "";
        job.chapterGuessWarning = reason + "；已按段落分窗";
        job.warnings.add(job.chapterGuessWarning);
        return parsed;
    }

    /** 模型偶尔会包 Markdown 代码块或加解释，这里只截取第一个 JSON 对象。 */
    private static Map<String, Object> parseChapterGuess(String raw) {
        if (raw == null) {
            return null;
        }
        int start = raw.indexOf('{');
        int end = raw.lastIndexOf('}');
        if (start < 0 || end <= start) {
            return null;
        }
        try {
            return Json.asMap(Json.parse(raw.substring(start, end + 1)));
        } catch (RuntimeException e) {
            return null;
        }
    }

    /** 截取开头若干字符，尽量落在段落边界；不加省略号，避免干扰模型判断。 */
    private static String head(String text, int maxChars) {
        if (text == null) {
            return "";
        }
        if (text.length() <= maxChars) {
            return text;
        }
        int cut = text.lastIndexOf('\n', maxChars);
        return text.substring(0, cut > maxChars / 2 ? cut : maxChars);
    }

    private String buildParseMessage(ImportJob job, boolean manual) {
        RagDocumentParser.ParsedDocument parsed = job.parsed;
        String format = parsed == null ? "" : parsed.format().label();
        int chapters = parsed == null ? 0 : parsed.chapters().size();
        int paragraphs = parsed == null ? 0 : parsed.paragraphs().size();
        int windows = parsed == null ? 0 : parsed.windows().size();
        String base = "解析完成：" + format + "，" + paragraphs + " 段，"
                + (chapters > 0 ? chapters + " 章，" : "") + windows + " 个窗口";
        return manual ? base + "；确认分块后点「开始提炼」" : base + "；已自动开始提炼";
    }

    private void resetWindowStates(ImportJob job) {
        synchronized (job.windows) {
            for (WindowState window : job.windows) {
                window.status = "pending";
                window.sceneCount = 0;
                window.error = "";
                window.rawOutput = "";
                window.startedAt = 0;
                window.finishedAt = 0;
                window.scenes = List.of();
            }
        }
    }

    private boolean applyOverrides(ImportJob job, Map<String, Object> body) {
        if (body == null || body.isEmpty()) {
            return false;
        }
        boolean changed = false;
        if (body.containsKey("windowChars")) {
            int value = clamp(intValue(body.get("windowChars"), job.windowChars), WINDOW_MIN, WINDOW_MAX);
            if (value != job.windowChars) {
                job.windowChars = value;
                changed = true;
            }
        }
        if (body.containsKey("overlapChars")) {
            int max = Math.min(OVERLAP_MAX, job.windowChars / 2);
            int value = clamp(intValue(body.get("overlapChars"), job.overlapChars), 0, Math.max(0, max));
            if (value != job.overlapChars) {
                job.overlapChars = value;
                changed = true;
            }
        }
        if (body.containsKey("concurrency")) {
            int value = clamp(intValue(body.get("concurrency"), job.concurrency), CONCURRENCY_MIN, CONCURRENCY_MAX);
            if (value != job.concurrency) {
                job.concurrency = value;
                changed = true;
            }
        }
        if (job.overlapChars > job.windowChars / 2) {
            job.overlapChars = job.windowChars / 2;
        }
        return changed;
    }

    private void submitRun(ImportJob job) {
        runExecutor.submit(() -> executeJob(job));
    }

    private void executeJob(ImportJob job) {
        try {
            job.status = "extracting";
            job.phase = "DeepSeek 提炼情节";
            job.progress = 6;
            job.startedAt = System.currentTimeMillis();
            job.message = "开始提炼 " + job.windows.size() + " 个窗口（并行 " + job.concurrency + "）";

            List<SceneDraft> raw = extractAll(job);

            job.status = "merging";
            job.phase = "合并跨窗口情节";
            job.progress = 72;
            job.message = "正在合并重叠窗口里的重复情节";
            List<SceneDraft> merged = dedupeScenes(job.windows);
            job.mergedCount = Math.max(0, raw.size() - merged.size());
            job.sceneCount = merged.size();
            if (merged.isEmpty()) {
                throw new IllegalStateException("没有从文本中提炼出可用情节");
            }
            if (merged.size() > MAX_SCENES) {
                throw new IllegalStateException("提炼出的情节过多（" + merged.size()
                        + " 条），请增大窗口字数或分卷导入");
            }

            job.status = "embedding";
            job.phase = "生成向量";
            job.progress = 74;
            job.message = "正在调用百炼 embedding（共 " + merged.size() + " 条）";
            List<List<Double>> vectors = embedAll(job, merged);

            job.status = "indexing";
            job.phase = "写入 Elasticsearch";
            job.progress = 95;
            job.message = "正在替换并写入索引";
            replaceBook(job.book, merged, vectors);

            job.progress = 100;
            job.status = "done";
            job.phase = "已完成";
            job.message = "已入库 " + merged.size() + " 个可复用情节"
                    + (job.mergedCount > 0 ? "（合并重复 " + job.mergedCount + " 条）" : "");
        } catch (Exception e) {
            job.status = "failed";
            job.error = readableError(e);
            job.phase = "失败";
            job.message = job.error;
            job.progress = Math.max(1, job.progress);
        } finally {
            job.finishedAt = System.currentTimeMillis();
        }
    }

    /**
     * 并行提炼各窗口。
     *
     * <p>按窗口顺序分批提交（每批 = 并发数），同一批内并行；每批结束后把最后一条情节摘要作为
     * 下一批的「续接状态」塞进 prompt，既保证并行速度，又让模型知道上一个窗口结束在什么位置。
     * 窗口本身带重叠文本，跨窗口的完整情节至少有一个窗口能完整看到。</p>
     */
    private List<SceneDraft> extractAll(ImportJob job) throws Exception {
        List<WindowState> windows = job.windows;
        int total = windows.size();
        int concurrency = clamp(job.concurrency, CONCURRENCY_MIN, CONCURRENCY_MAX);
        ExecutorService pool = Executors.newFixedThreadPool(concurrency, daemonFactory("rag-extract"));
        List<SceneDraft> all = Collections.synchronizedList(new ArrayList<>());
        AtomicInteger done = new AtomicInteger();
        String continuation = "";
        try {
            for (int batchStart = 0; batchStart < total; batchStart += concurrency) {
                int batchEnd = Math.min(total, batchStart + concurrency);
                Map<Integer, Future<List<SceneDraft>>> futures = new LinkedHashMap<>();
                for (int i = batchStart; i < batchEnd; i++) {
                    WindowState window;
                    synchronized (windows) {
                        window = windows.get(i);
                    }
                    window.status = "running";
                    window.startedAt = System.currentTimeMillis();
                    window.finishedAt = 0;
                    window.error = "";
                    window.rawOutput = "";
                    final String state = continuation;
                    futures.put(i, pool.submit(() -> extractWindow(job, window, state)));
                }

                Exception failure = null;
                int failedIndex = -1;
                for (Map.Entry<Integer, Future<List<SceneDraft>>> entry : futures.entrySet()) {
                    int index = entry.getKey();
                    WindowState window;
                    synchronized (windows) {
                        window = windows.get(index);
                    }
                    try {
                        List<SceneDraft> scenes = entry.getValue().get();
                        window.scenes = scenes;
                        window.sceneCount = scenes.size();
                        window.status = "done";
                        window.finishedAt = System.currentTimeMillis();
                        all.addAll(scenes);
                        done.incrementAndGet();
                    } catch (ExecutionException e) {
                        Throwable cause = e.getCause() == null ? e : e.getCause();
                        window.status = "failed";
                        window.error = readableError(cause instanceof Exception ex ? ex : new Exception(cause));
                        window.finishedAt = System.currentTimeMillis();
                        if (failure == null) {
                            failure = cause instanceof Exception ex ? ex : new Exception(cause);
                            failedIndex = index;
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("提炼被中断");
                    }
                }

                // 续接状态：优先取本批最后一个成功窗口的最后一条情节
                for (int i = batchEnd - 1; i >= batchStart; i--) {
                    WindowState window;
                    synchronized (windows) {
                        window = windows.get(i);
                    }
                    if (window.scenes != null && !window.scenes.isEmpty()) {
                        SceneDraft last = window.scenes.get(window.scenes.size() - 1);
                        continuation = clipText(last.plot(), 240);
                        break;
                    }
                }

                job.progress = 8 + (int) Math.round(62.0 * done.get() / total);
                job.message = "已提炼 " + done.get() + "/" + total + " 个窗口，得到 "
                        + all.size() + " 条情节";
                if (failure != null) {
                    throw new IllegalStateException("窗口 " + (failedIndex + 1) + " 提炼失败："
                            + readableError(failure), failure);
                }
            }
        } finally {
            pool.shutdownNow();
        }
        return new ArrayList<>(all);
    }

    private List<SceneDraft> extractWindow(ImportJob job, WindowState window, String continuation) {
        String user = buildExtractPrompt(job, window, continuation);
        Exception last = null;
        for (int attempt = 0; attempt < 3; attempt++) {
            try {
                String answer = ai.complete(SCENE_EXTRACT_SYSTEM, user, new AiSettings("", 0.25, 8192, ""));
                window.rawOutput = answer == null ? "" : answer;
                List<SceneDraft> scenes = parseScenes(answer);
                if (scenes.isEmpty()) {
                    throw new IllegalStateException("模型没有返回有效 JSON 情节");
                }
                return scenes;
            } catch (Exception e) {
                last = e;
                window.error = readableError(e);
                if (attempt < 2) {
                    try {
                        Thread.sleep(800L * (attempt + 1));
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        }
        throw new IllegalStateException("窗口 " + (window.index + 1) + " 提炼失败：" + readableError(last), last);
    }

    private String buildExtractPrompt(ImportJob job, WindowState window, String continuation) {
        int total = job.windows.size();
        StringBuilder user = new StringBuilder();
        user.append("作品：《").append(job.book).append("》\n");
        user.append("全书共 ").append(total).append(" 个窗口，当前是第 ").append(window.index + 1).append(" 个。\n");
        if (window.chapterRange != null && !window.chapterRange.isBlank()) {
            user.append("章节范围：").append(window.chapterRange).append('\n');
        }
        if (job.overlapChars > 0) {
            user.append("本窗口开头可能包含与上一个窗口重叠的过渡文字；如果某条情节在上一批已经抽取过，不要重复输出。\n");
        }
        if (continuation != null && !continuation.isBlank()) {
            user.append("上一批窗口结尾的最近情节（仅用于衔接上下文，不要重复抽取）：\n")
                    .append(continuation).append('\n');
        }
        user.append("\n当前窗口文本：\n<TEXT>\n").append(window.text).append("\n</TEXT>\n\n");
        user.append("请按系统规则输出 JSON 数组。只抽取本窗口内相对完整的情节；")
                .append("开头/结尾明显不完整的情节不要凭空补全，也不要重复输出上一批已抽取的内容。\n");
        return user.toString();
    }

    /** 只在相邻窗口之间做去重：重叠设计下，重复主要出现在相邻窗口。 */
    private List<SceneDraft> dedupeScenes(List<WindowState> windows) {
        List<SceneDraft> merged = new ArrayList<>();
        List<SceneDraft> previousKept = new ArrayList<>();
        List<WindowState> snapshot;
        synchronized (windows) {
            snapshot = new ArrayList<>(windows);
        }
        for (WindowState window : snapshot) {
            List<SceneDraft> kept = new ArrayList<>();
            for (SceneDraft draft : window.scenes) {
                if (isDuplicate(draft, kept) || isDuplicate(draft, previousKept)) {
                    continue;
                }
                kept.add(draft);
            }
            merged.addAll(kept);
            previousKept = kept;
        }
        return merged;
    }

    private boolean isDuplicate(SceneDraft draft, List<SceneDraft> candidates) {
        for (SceneDraft kept : candidates) {
            Set<String> titleA = bigrams(kept.title());
            Set<String> titleB = bigrams(draft.title());
            double titleSim = jaccard(titleA, titleB);
            Set<String> plotA = bigrams(clipText(kept.plot(), 600));
            Set<String> plotB = bigrams(clipText(draft.plot(), 600));
            double plotSim = jaccard(plotA, plotB);
            if ((titleSim >= 0.80 && plotSim >= 0.45) || plotSim >= 0.82) {
                return true;
            }
        }
        return false;
    }

    private static Set<String> bigrams(String text) {
        Set<String> grams = new LinkedHashSet<>();
        if (text == null) {
            return grams;
        }
        String normalized = text.replaceAll("[\\s，。！？、；：,.!?;:“”\"'（）()《》<>\\[\\]【】…—-]", "");
        for (int i = 0; i + 1 < normalized.length(); i++) {
            grams.add(normalized.substring(i, i + 2));
        }
        return grams;
    }

    private static double jaccard(Set<String> a, Set<String> b) {
        if (a.isEmpty() || b.isEmpty()) {
            return 0;
        }
        int intersection = 0;
        for (String item : a) {
            if (b.contains(item)) {
                intersection++;
            }
        }
        int union = a.size() + b.size() - intersection;
        return union <= 0 ? 0 : (double) intersection / union;
    }

    // ── 并行 embedding ──

    private List<List<Double>> embedAll(ImportJob job, List<SceneDraft> drafts) throws Exception {
        List<List<Double>> vectors = new ArrayList<>(drafts.size());
        if (drafts.isEmpty()) {
            return vectors;
        }
        List<List<String>> batches = new ArrayList<>();
        for (int i = 0; i < drafts.size(); i += EMBEDDING_BATCH) {
            int to = Math.min(drafts.size(), i + EMBEDDING_BATCH);
            List<String> inputs = new ArrayList<>();
            for (int j = i; j < to; j++) {
                inputs.add(embeddingText(drafts.get(j)));
            }
            batches.add(inputs);
        }
        int concurrency = clamp(job.concurrency, 1, 4);
        ExecutorService pool = Executors.newFixedThreadPool(concurrency, daemonFactory("rag-embed"));
        try {
            List<Future<List<List<Double>>>> futures = new ArrayList<>();
            for (List<String> batch : batches) {
                futures.add(pool.submit(() -> embed(batch)));
            }
            int completed = 0;
            for (Future<List<List<Double>>> future : futures) {
                List<List<Double>> batchVectors;
                try {
                    batchVectors = future.get();
                } catch (ExecutionException e) {
                    Throwable cause = e.getCause() == null ? e : e.getCause();
                    throw new IllegalStateException("embedding 失败：" + readableError(
                            cause instanceof Exception ex ? ex : new Exception(cause)), cause);
                }
                vectors.addAll(batchVectors);
                completed++;
                job.progress = 74 + (int) Math.round(20.0 * completed / batches.size());
                job.message = "已生成向量 " + vectors.size() + "/" + drafts.size() + " 条";
            }
        } finally {
            pool.shutdownNow();
        }
        if (vectors.size() != drafts.size()) {
            throw new IllegalStateException("embedding 返回数量与情节数量不一致");
        }
        return vectors;
    }

    // ============================================================
    //  任务快照与工具
    // ============================================================

    private Map<String, Object> jobSummary(ImportJob job) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", job.id);
        out.put("book", job.book);
        out.put("status", job.status);
        out.put("phase", job.phase);
        out.put("progress", job.progress);
        out.put("message", job.message);
        out.put("error", job.error);
        out.put("warnings", new ArrayList<>(job.warnings));
        out.put("chunksTotal", job.windows.size());
        out.put("chunksDone", job.chunksDone());
        out.put("sceneCount", job.sceneCount);
        out.put("mergedCount", job.mergedCount);
        out.put("createdAt", job.createdAt);
        out.put("startedAt", job.startedAt);
        out.put("finishedAt", job.finishedAt);
        return out;
    }

    private Map<String, Object> jobDetail(ImportJob job) {
        Map<String, Object> out = jobSummary(job);
        RagDocumentParser.ParsedDocument parsed = job.parsed;
        out.put("format", parsed == null ? "" : parsed.format().label());
        out.put("chapterPattern", parsed == null ? "" : parsed.chapterPattern());
        out.put("paragraphs", parsed == null ? 0 : parsed.paragraphs().size());
        out.put("chapters", parsed == null ? 0 : parsed.chapters().size());
        out.put("totalChars", parsed == null ? 0 : parsed.totalChars());
        out.put("windowChars", job.windowChars);
        out.put("overlapChars", job.overlapChars);
        out.put("concurrency", job.concurrency);
        List<Map<String, Object>> windows = new ArrayList<>();
        synchronized (job.windows) {
            for (WindowState window : job.windows) {
                windows.add(windowSummary(window));
            }
        }
        out.put("windows", windows);
        return out;
    }

    private Map<String, Object> windowSummary(WindowState window) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("index", window.index);
        out.put("title", window.title);
        out.put("chapterRange", window.chapterRange);
        out.put("chars", window.chars);
        out.put("status", window.status);
        out.put("sceneCount", window.sceneCount);
        out.put("error", window.error);
        out.put("elapsedMs", window.elapsedMs());
        String preview = window.text == null ? "" : window.text.replace('\n', ' ').trim();
        out.put("textPreview", preview.length() > 100 ? preview.substring(0, 100) + "…" : preview);
        return out;
    }

    private static Map<String, Object> sceneMap(SceneDraft draft) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("title", draft.title());
        out.put("plot", draft.plot());
        out.put("excerpt", draft.excerpt());
        out.put("tags", draft.tags());
        out.put("characters", draft.characters());
        out.put("sceneType", draft.sceneType());
        out.put("emotion", draft.emotion());
        out.put("reusable", draft.reusable());
        return out;
    }

    private ImportJob requireJob(String jobId) {
        ImportJob job = jobId == null ? null : jobs.get(jobId);
        if (job == null) {
            throw new ApiException(404, "导入任务不存在（可能服务已重启），请重新导入");
        }
        return job;
    }

    private void cleanupJobs() {
        long now = System.currentTimeMillis();
        List<ImportJob> finished = new ArrayList<>();
        for (ImportJob job : jobs.values()) {
            if (!isRunning(job.status)) {
                finished.add(job);
            }
        }
        finished.sort((a, b) -> Long.compare(a.createdAt, b.createdAt));
        for (ImportJob job : finished) {
            boolean expired = job.finishedAt > 0 && now - job.finishedAt > 2 * 60 * 60 * 1000L;
            boolean tooMany = jobs.size() > 20;
            if (expired || tooMany) {
                jobs.remove(job.id);
            }
        }
    }

    private static boolean isRunning(String status) {
        return "parsing".equals(status) || "waiting".equals(status) || "extracting".equals(status)
                || "merging".equals(status) || "embedding".equals(status) || "indexing".equals(status);
    }

    private static ThreadFactory daemonFactory(String name) {
        AtomicInteger counter = new AtomicInteger();
        return runnable -> {
            Thread thread = new Thread(runnable, name + "-" + counter.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
    }

    private static int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }

    private static int intValue(Object value, int fallback) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(value).trim());
        } catch (Exception e) {
            return fallback;
        }
    }

    // ============================================================
    //  素材库状态 / 检索 / 仿写 / 删除
    // ============================================================

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
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("size", 0);
        body.put("track_total_hits", true);
        body.put("aggs", Map.of(
                "books", Map.of("terms", Map.of("field", "book", "size", 50)),
                "tags", Map.of("terms", Map.of("field", "tags", "size", 80))
        ));
        HttpResult result = request("POST", indexUrl() + "/_search", Json.write(body), "application/json");
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

    public ScenePage listScenes(int page, int pageSize, String q, String tag, String book) {
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
            // 作品 / 标签都是精确过滤：先选作品再翻情节时用 book，标签检索时用 tag，可同时生效
            List<Map<String, Object>> filters = new ArrayList<>();
            if (tag != null && !tag.isBlank()) {
                filters.add(Map.of("term", Map.of("tags", tag.trim())));
            }
            if (book != null && !book.isBlank()) {
                filters.add(Map.of("term", Map.of("book", book.trim())));
            }
            if (!filters.isEmpty()) {
                query = Map.of("bool", Map.of(
                        "must", List.of(query),
                        "filter", filters
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
            refs.append("情节：").append(clipText(scene.plot(), 900)).append('\n');
            refs.append("可复用结构：").append(clipText(scene.reusable(), 500)).append('\n');
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
        String draft;
        try {
            draft = ai.complete(system, user, new AiSettings("", 0.9, 8192, ""));
        } catch (Exception e) {
            throw new ApiException(502, "仿写失败：" + readableError(e));
        }
        if (draft == null || draft.isBlank()) {
            throw new ApiException(502, "AI 没有生成有效正文，请重试");
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("draft", draft.trim());
        out.put("references", references);
        out.put("query", query);
        return out;
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

    // ============================================================
    //  Embedding / Elasticsearch
    // ============================================================

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
            for (JsonNode value : embedding) {
                vector.add(value.asDouble());
            }
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

    private String embeddingText(SceneDraft draft) {
        return "标题：" + draft.title()
                + "\n情节：" + draft.plot()
                + "\n标签：" + String.join("、", draft.tags())
                + "\n人物：" + String.join("、", draft.characters())
                + "\n场景：" + draft.sceneType()
                + "\n情绪：" + draft.emotion()
                + "\n可复用结构：" + draft.reusable();
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

    private List<Scene> parseHits(JsonNode root) {
        List<Scene> scenes = new ArrayList<>();
        JsonNode hits = root.path("hits").path("hits");
        if (!hits.isArray()) {
            return scenes;
        }
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
        if (indexReady) {
            return;
        }
        synchronized (this) {
            if (indexReady) {
                return;
            }
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
        } catch (ApiException e) {
            throw e;
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
        HttpResponse<String> response = http.send(builder.build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
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
        if (base.endsWith("/embeddings")) {
            return base;
        }
        return base + "/embeddings";
    }

    // ============================================================
    //  文本解析工具
    // ============================================================

    private List<SceneDraft> parseScenes(String raw) {
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
            if (!node.isObject()) {
                continue;
            }
            String title = text(node, "title");
            String plot = text(node, "plot");
            if (plot.isBlank()) {
                plot = text(node, "summary");
            }
            String excerpt = text(node, "excerpt");
            if (excerpt.isBlank()) {
                excerpt = text(node, "source_excerpt");
            }
            if (plot.isBlank() && excerpt.isBlank()) {
                continue;
            }
            if (plot.isBlank()) {
                plot = excerpt.length() > 500 ? excerpt.substring(0, 500) : excerpt;
            }
            if (title.isBlank()) {
                title = plot.length() > 24 ? plot.substring(0, 24) : plot;
            }
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
                if (!text.isEmpty()) {
                    out.add(text);
                }
            }
        } else if (value != null && value.isTextual()) {
            for (String part : value.asText("").split("[,，、/]")) {
                if (!part.isBlank()) {
                    out.add(part.trim());
                }
            }
        }
        return new ArrayList<>(out);
    }

    private static List<String> buckets(JsonNode buckets) {
        List<String> out = new ArrayList<>();
        if (!buckets.isArray()) {
            return out;
        }
        for (JsonNode bucket : buckets) {
            String key = bucket.path("key").asText("");
            if (!key.isBlank()) {
                out.add(key);
            }
        }
        return out;
    }

    private static List<Map<String, Object>> bucketObjects(JsonNode buckets) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (!buckets.isArray()) {
            return out;
        }
        for (JsonNode bucket : buckets) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("book", bucket.path("key").asText(""));
            item.put("count", bucket.path("doc_count").asLong(0));
            out.add(item);
        }
        return out;
    }

    private static String clipText(String value, int max) {
        if (value == null) {
            return "";
        }
        return value.length() <= max ? value : value.substring(0, max) + "…";
    }

    private static String readableError(Throwable e) {
        if (e == null) {
            return "未知错误";
        }
        String message = e.getMessage();
        if (message == null || message.isBlank()) {
            message = e.getClass().getSimpleName();
        }
        return message.replaceFirst("^Exception:\\s*", "");
    }

    private static String abbreviate(String value) {
        if (value == null) {
            return "";
        }
        return value.length() > 600 ? value.substring(0, 600) + "…" : value;
    }
}
