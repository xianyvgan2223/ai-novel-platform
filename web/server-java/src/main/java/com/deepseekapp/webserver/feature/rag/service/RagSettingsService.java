package com.deepseekapp.webserver.feature.rag.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 情节素材库导入设置：是否在分块后手动开始提炼、窗口字数、重叠字数、并行数。
 *
 * <p>存储在数据目录 rag/settings.json（原子落盘），未保存过时使用 application.yml 的默认值。</p>
 */
@Service
public class RagSettingsService {

    private static final int WINDOW_MIN = 4000;
    private static final int WINDOW_MAX = 30000;
    private static final int OVERLAP_MAX = 5000;
    private static final int CONCURRENCY_MIN = 1;
    private static final int CONCURRENCY_MAX = 8;

    private final AppProperties props;

    public RagSettingsService(AppProperties props) {
        this.props = props;
    }

    /** 分块完成后是否等待用户手动开始提炼（默认开启）。 */
    public boolean manualExtract() {
        return readBoolean("manualExtract", true);
    }

    public int windowChars() {
        return clamp(readInt("windowChars", props.getRagWindowChars()), WINDOW_MIN, WINDOW_MAX);
    }

    public int overlapChars() {
        int window = windowChars();
        int max = Math.min(OVERLAP_MAX, window / 2);
        return clamp(readInt("overlapChars", props.getRagOverlapChars()), 0, Math.max(0, max));
    }

    public int concurrency() {
        return clamp(readInt("concurrency", props.getRagExtractConcurrency()), CONCURRENCY_MIN, CONCURRENCY_MAX);
    }

    /** 当前设置 + 默认值（前端展示用）。 */
    public Map<String, Object> view() {
        Map<String, Object> defaults = new LinkedHashMap<>();
        defaults.put("manualExtract", true);
        defaults.put("windowChars", props.getRagWindowChars());
        defaults.put("overlapChars", props.getRagOverlapChars());
        defaults.put("concurrency", props.getRagExtractConcurrency());

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("manualExtract", manualExtract());
        out.put("windowChars", windowChars());
        out.put("overlapChars", overlapChars());
        out.put("concurrency", concurrency());
        out.put("defaults", defaults);
        return out;
    }

    /** 保存部分字段；未传的字段保持当前值。 */
    public Map<String, Object> save(Map<String, Object> body) {
        Map<String, Object> data = body == null ? Map.of() : body;
        boolean manual = data.containsKey("manualExtract") ? boolValue(data.get("manualExtract"), manualExtract())
                : manualExtract();
        int window = data.containsKey("windowChars") ? intValue(data.get("windowChars"), windowChars()) : windowChars();
        window = clamp(window, WINDOW_MIN, WINDOW_MAX);
        int overlap = data.containsKey("overlapChars") ? intValue(data.get("overlapChars"), overlapChars()) : overlapChars();
        overlap = clamp(overlap, 0, Math.max(0, Math.min(OVERLAP_MAX, window / 2)));
        int concurrency = data.containsKey("concurrency") ? intValue(data.get("concurrency"), concurrency()) : concurrency();
        concurrency = clamp(concurrency, CONCURRENCY_MIN, CONCURRENCY_MAX);

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("manualExtract", manual);
        out.put("windowChars", window);
        out.put("overlapChars", overlap);
        out.put("concurrency", concurrency);
        out.put("savedAt", OffsetDateTime.now().toString());
        write(out);
        return view();
    }

    /* ── 文件读写 ── */

    private Path settingsPath() {
        return props.dataDirPath().resolve("rag").resolve("settings.json");
    }

    private JsonNode readRoot() {
        Path path = settingsPath();
        if (!Files.isRegularFile(path)) {
            return null;
        }
        try {
            return Json.MAPPER.readTree(Files.readString(path, StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }

    private boolean readBoolean(String field, boolean fallback) {
        JsonNode root = readRoot();
        if (root == null || !root.has(field)) {
            return fallback;
        }
        JsonNode node = root.get(field);
        return node.isBoolean() ? node.asBoolean() : fallback;
    }

    private int readInt(String field, int fallback) {
        JsonNode root = readRoot();
        if (root == null || !root.has(field)) {
            return fallback;
        }
        JsonNode node = root.get(field);
        return node.isNumber() ? node.asInt() : fallback;
    }

    private void write(Map<String, Object> data) {
        Path path = settingsPath();
        try {
            Files.createDirectories(path.getParent());
            Path tmp = path.resolveSibling("settings.json.tmp");
            Files.writeString(tmp, Json.write(data), StandardCharsets.UTF_8);
            try {
                Files.move(tmp, path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (IOException e) {
                Files.move(tmp, path, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException e) {
            throw new IllegalStateException("保存 RAG 设置失败：" + e.getMessage(), e);
        }
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

    private static boolean boolValue(Object value, boolean fallback) {
        if (value instanceof Boolean b) {
            return b;
        }
        String text = String.valueOf(value).trim();
        if ("true".equalsIgnoreCase(text) || "1".equals(text)) {
            return true;
        }
        if ("false".equalsIgnoreCase(text) || "0".equals(text)) {
            return false;
        }
        return fallback;
    }

    private static int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }
}
