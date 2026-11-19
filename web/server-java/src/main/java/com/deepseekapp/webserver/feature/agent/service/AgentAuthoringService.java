package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Agent 生成结果的落库。
 *
 * <p>生成类工具（一键大纲 / 章节正文）产出的内容以前只回传给前端，SSE 一断就没了；
 * 这里按写作页保存的同一套字段与语义写进 {@code outline_records} / {@code outline_chapters}，
 * 并且必须走 {@link SyncStore#writeRow} —— 直连 SQL 不会写 change_log，手机端就同步不到。</p>
 */
@Service
public class AgentAuthoringService {

    private static final String DB = "deepseek";
    private static final String OUTLINE_TABLE = "outline_records";
    private static final String CHAPTER_TABLE = "outline_chapters";

    private final SyncStore syncStore;
    private final DatabaseManager databaseManager;
    private final AppProperties props;

    public AgentAuthoringService(SyncStore syncStore, DatabaseManager databaseManager, AppProperties props) {
        this.syncStore = syncStore;
        this.databaseManager = databaseManager;
        this.props = props;
    }

    /** 把一次大纲生成结果保存成「作品 + 章节」。返回作品 id 与章节数。 */
    public Map<String, Object> saveOutline(String deviceId, Map<String, Object> data) {
        if (deviceId == null || deviceId.isBlank()) {
            throw new ApiException(400, "缺少设备信息，无法保存");
        }
        if (data == null || data.isEmpty()) {
            throw new ApiException(400, "没有可保存的大纲内容");
        }
        String now = isoNow();
        long outlineId = syncStore.allocateWebId(deviceId, DB, OUTLINE_TABLE);
        syncStore.writeRow(deviceId, DB, OUTLINE_TABLE, outlineRow(outlineId, data, now), origin());

        int chapterCount = 0;
        for (Map<String, Object> chapter : chapterList(data.get("chapters"))) {
            long chapterId = syncStore.allocateWebId(deviceId, DB, CHAPTER_TABLE);
            syncStore.writeRow(deviceId, DB, CHAPTER_TABLE, chapterRow(chapterId, outlineId, chapter, now), origin());
            chapterCount++;
        }

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("outlineId", outlineId);
        out.put("title", text(data.get("title"), "未命名作品"));
        out.put("chapterCount", chapterCount);
        return out;
    }

    /** 把生成的正文写进指定章节（内容 + 已完成状态），与写作页「保存」同口径。 */
    public Map<String, Object> saveChapterContent(String deviceId, long chapterId, String content) {
        Map<String, Object> existing = syncStore.readRow(deviceId, DB, CHAPTER_TABLE, chapterId);
        if (existing == null) {
            throw new ApiException(404, "章节不存在或不属于当前设备：" + chapterId);
        }
        Map<String, Object> row = new LinkedHashMap<>(existing);
        row.put("content", content == null ? "" : content);
        row.put("status", "completed");
        row.put("updated_at", isoNow());
        syncStore.writeRow(deviceId, DB, CHAPTER_TABLE, row, origin());

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("chapterId", chapterId);
        out.put("outlineId", existing.get("outline_id"));
        out.put("chars", row.get("content") == null ? 0 : String.valueOf(row.get("content")).length());
        return out;
    }

    /** 作品详情；不存在或不属于当前设备时返回 null（由调用方给出友好错误）。 */
    public Map<String, Object> outline(String deviceId, long outlineId) {
        return databaseManager.app(deviceId, DB, connection -> Db.queryOne(connection,
                "SELECT * FROM outline_records WHERE device_id = ? AND id = ?", deviceId, outlineId));
    }

    /** 某部作品的章节清单（按 event_index 升序），供工具展示与定位。 */
    public List<Map<String, Object>> chapters(String deviceId, long outlineId) {
        return databaseManager.app(deviceId, DB, connection -> Db.query(connection,
                "SELECT id, outline_id, event_index, event_type, event_title, event_summary, status, "
                        + "LENGTH(content) AS content_chars FROM outline_chapters "
                        + "WHERE device_id = ? AND outline_id = ? ORDER BY event_index ASC",
                deviceId, outlineId));
    }

    /** 按 event_index 找章节；找不到返回 null。 */
    public Map<String, Object> chapterAt(String deviceId, long outlineId, int eventIndex) {
        return databaseManager.app(deviceId, DB, connection -> Db.queryOne(connection,
                "SELECT * FROM outline_chapters WHERE device_id = ? AND outline_id = ? AND event_index = ? LIMIT 1",
                deviceId, outlineId, eventIndex));
    }

    /** 上一个已写的小事件（用于承接前文）；没有则返回 null。 */
    public Map<String, Object> previousChapter(String deviceId, long outlineId, int eventIndex) {
        return databaseManager.app(deviceId, DB, connection -> Db.queryOne(connection,
                "SELECT * FROM outline_chapters WHERE device_id = ? AND outline_id = ? "
                        + "AND event_index < ? AND event_type = 'minor' ORDER BY event_index DESC LIMIT 1",
                deviceId, outlineId, eventIndex));
    }

    // ── 行映射（与 web/app/src/views/writing 里的保存逻辑保持一致）──

    static Map<String, Object> outlineRow(long outlineId, Map<String, Object> data, String now) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("id", outlineId);
        row.put("title", text(data.get("title"), "未命名作品"));
        row.put("genre", text(data.get("genre"), ""));
        row.put("theme", text(data.get("theme"), ""));
        row.put("protagonist", text(data.get("protagonist"), ""));
        row.put("worldview", text(data.get("worldview"), ""));
        row.put("content", text(data.get("outlineText"), ""));
        row.put("skeleton", text(data.get("skeletonJson"), ""));
        row.put("foreshadows", text(data.get("foreshadows"), ""));
        row.put("story_state", text(data.get("storyState"), ""));
        row.put("characters", text(data.get("charactersJson"), ""));
        row.put("created_at", now);
        return row;
    }

    static Map<String, Object> chapterRow(long chapterId, long outlineId,
                                          Map<String, Object> chapter, String now) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("id", chapterId);
        row.put("outline_id", outlineId);
        row.put("event_index", chapter.get("index") == null ? 0 : ((Number) chapter.get("index")).intValue());
        row.put("event_type", text(chapter.get("type"), "minor"));
        row.put("event_title", text(chapter.get("title"), ""));
        row.put("event_summary", text(chapter.get("summary"), ""));
        row.put("content", "");
        row.put("status", "pending");
        row.put("ai_summary", "");
        row.put("story_state", "");
        row.put("created_at", now);
        row.put("updated_at", now);
        return row;
    }

    private static List<Map<String, Object>> chapterList(Object raw) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (!(raw instanceof List<?> list)) {
            return out;
        }
        for (Object item : list) {
            if (item instanceof Map<?, ?> map) {
                Map<String, Object> row = new LinkedHashMap<>();
                map.forEach((key, value) -> row.put(String.valueOf(key), value));
                out.add(row);
            }
        }
        return out;
    }

    private String origin() {
        String web = props.getWebDeviceId();
        return web == null || web.isBlank() ? "agent" : web;
    }

    private static String isoNow() {
        return DateTimeFormatter.ISO_INSTANT.format(Instant.now().truncatedTo(ChronoUnit.MILLIS));
    }

    private static String text(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
    }
}
