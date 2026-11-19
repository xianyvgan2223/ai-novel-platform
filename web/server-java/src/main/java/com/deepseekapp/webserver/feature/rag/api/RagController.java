package com.deepseekapp.webserver.feature.rag.api;

import com.deepseekapp.webserver.feature.rag.service.RagService;
import com.deepseekapp.webserver.feature.rag.service.RagSettingsService;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * RAG 情节素材库接口：
 *
 * <pre>
 * GET    /api/rag/status                  配置、索引、统计
 * GET    /api/rag/settings                导入设置（手动开始提炼/窗口/重叠/并行）
 * PUT    /api/rag/settings                保存导入设置
 * POST   /api/rag/analyze                 上传 txt → 只解析与分块（返回窗口，可暂停预览）
 * POST   /api/rag/jobs/{id}/resplit       重新分块（未开始提炼时）
 * POST   /api/rag/jobs/{id}/start         开始提炼（并行 + 合并 + embedding + 入库）
 * GET    /api/rag/jobs                    最近任务列表（切页后恢复进度）
 * GET    /api/rag/jobs/{id}               任务详情（含窗口状态）
 * GET    /api/rag/jobs/{id}/windows/{i}   单个窗口原文 + DeepSeek 原始输出 + 解析出的情节
 * POST   /api/rag/import                  兼容旧接口：上传并立即开始提炼
 * GET    /api/rag/scenes                  已入库情节列表 / 关键字搜索
 * POST   /api/rag/search                  语义检索（百炼 embedding + ES kNN）
 * POST   /api/rag/imitate                 检索参考情节 + DeepSeek 仿写
 * DELETE /api/rag/books?book=...          删除一部作品的素材
 * </pre>
 */
@RestController
@RequestMapping("/api/rag")
public class RagController {

    private final RagService ragService;
    private final RagSettingsService settingsService;

    public RagController(RagService ragService, RagSettingsService settingsService) {
        this.ragService = ragService;
        this.settingsService = settingsService;
    }

    @GetMapping("/status")
    public Map<String, Object> status() {
        return Api.ok(ragService.status());
    }

    @GetMapping("/settings")
    public Map<String, Object> settings() {
        return Api.ok(settingsService.view());
    }

    @PutMapping("/settings")
    public Map<String, Object> saveSettings(@RequestBody(required = false) Map<String, Object> body) {
        return Api.ok(settingsService.save(body));
    }

    /** 只解析/分块：manualExtract=true 时返回 waiting 状态，等用户确认后 start。 */
    @PostMapping(value = "/analyze", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> analyze(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "book", required = false, defaultValue = "") String book
    ) throws IOException {
        Uploaded uploaded = readUpload(file, book);
        return Api.ok(ragService.analyze(uploaded.title(), uploaded.text()));
    }

    @PostMapping("/jobs/{id}/resplit")
    public Map<String, Object> resplit(@PathVariable("id") String id,
                                       @RequestBody(required = false) Map<String, Object> body) {
        return Api.ok(ragService.resplit(id, body));
    }

    @PostMapping("/jobs/{id}/start")
    public Map<String, Object> start(@PathVariable("id") String id,
                                     @RequestBody(required = false) Map<String, Object> body) {
        return Api.ok(ragService.start(id, body));
    }

    @GetMapping("/jobs")
    public Map<String, Object> jobs() {
        return Api.ok(ragService.jobs());
    }

    @GetMapping("/jobs/{id}")
    public Map<String, Object> job(@PathVariable("id") String id) {
        return Api.ok(ragService.job(id));
    }

    @GetMapping("/jobs/{id}/windows/{index}")
    public Map<String, Object> window(@PathVariable("id") String id,
                                      @PathVariable("index") int index) {
        return Api.ok(ragService.window(id, index));
    }

    /** 兼容旧接口：上传并立即开始提炼（忽略 manualExtract 设置）。 */
    @PostMapping(value = "/import", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String, Object> importNovel(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "book", required = false, defaultValue = "") String book,
            @RequestParam(value = "replace", required = false, defaultValue = "true") boolean replace
    ) throws IOException {
        Uploaded uploaded = readUpload(file, book);
        Map<String, Object> data = new LinkedHashMap<>(ragService.startImport(uploaded.title(), uploaded.text()));
        data.put("replace", replace);
        return Api.ok(data);
    }

    @GetMapping("/scenes")
    public Map<String, Object> scenes(
            @RequestParam(value = "page", defaultValue = "1") int page,
            @RequestParam(value = "pageSize", defaultValue = "20") int pageSize,
            @RequestParam(value = "q", required = false, defaultValue = "") String q,
            @RequestParam(value = "tag", required = false, defaultValue = "") String tag,
            @RequestParam(value = "book", required = false, defaultValue = "") String book
    ) {
        RagService.ScenePage result = ragService.listScenes(page, pageSize, q, tag, book);
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("total", result.total());
        meta.put("page", result.page());
        meta.put("pageSize", result.pageSize());
        meta.put("pages", result.pageSize() <= 0 ? 0 : (int) Math.ceil((double) result.total() / result.pageSize()));
        return Api.ok(result.items(), meta);
    }

    @PostMapping("/search")
    public Map<String, Object> search(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String query = String.valueOf(payload.getOrDefault("query", ""));
        int size = intValue(payload.get("size"), 6);
        List<String> tags = stringList(payload.get("tags"));
        List<RagService.Scene> hits = ragService.search(query, size, tags);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("query", query);
        data.put("hits", hits);
        return Api.ok(data);
    }

    @PostMapping("/imitate")
    public Map<String, Object> imitate(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> payload = body == null ? Map.of() : body;
        String query = String.valueOf(payload.getOrDefault("query", ""));
        int size = intValue(payload.get("size"), 4);
        List<String> tags = stringList(payload.get("tags"));
        String style = String.valueOf(payload.getOrDefault("style", ""));
        String extra = String.valueOf(payload.getOrDefault("extra", ""));
        return Api.ok(ragService.imitate(query, size, tags, style, extra));
    }

    @DeleteMapping("/books")
    public Map<String, Object> deleteBook(@RequestParam("book") String book) {
        ragService.deleteBook(book);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("book", book);
        data.put("deleted", true);
        return Api.ok(data);
    }

    private record Uploaded(String title, String text) {
    }

    private static Uploaded readUpload(MultipartFile file, String book) throws IOException {
        if (file == null || file.isEmpty()) {
            throw new ApiException(400, "请先选择 txt 文件");
        }
        String filename = file.getOriginalFilename() == null ? "" : file.getOriginalFilename();
        if (!filename.toLowerCase().endsWith(".txt")) {
            throw new ApiException(400, "目前只支持导入 .txt 文本文件");
        }
        String text = decodeText(file.getBytes());
        String title = book == null ? "" : book.trim();
        if (title.isEmpty()) {
            title = filename.replaceFirst("(?i)\\.txt$", "").trim();
        }
        if (title.isEmpty()) {
            title = "未命名作品";
        }
        return new Uploaded(title, text);
    }

    private static String decodeText(byte[] bytes) {
        String utf8 = new String(bytes, StandardCharsets.UTF_8);
        if (!utf8.contains("\uFFFD")) return utf8;
        try {
            return new String(bytes, "GB18030");
        } catch (Exception ignored) {
            return utf8;
        }
    }

    private static int intValue(Object value, int fallback) {
        if (value instanceof Number number) return Math.max(1, number.intValue());
        try {
            return Math.max(1, Integer.parseInt(String.valueOf(value)));
        } catch (Exception ignored) {
            return fallback;
        }
    }

    private static List<String> stringList(Object value) {
        List<String> out = new ArrayList<>();
        if (value instanceof List<?> list) {
            for (Object item : list) {
                if (item != null && !String.valueOf(item).isBlank()) {
                    out.add(String.valueOf(item).trim());
                }
            }
        } else if (value != null) {
            for (String item : String.valueOf(value).split("[,，、/]")) {
                if (!item.isBlank()) out.add(item.trim());
            }
        }
        return out;
    }
}
