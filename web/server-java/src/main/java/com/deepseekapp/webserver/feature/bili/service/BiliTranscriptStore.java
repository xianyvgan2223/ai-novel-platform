package com.deepseekapp.webserver.feature.bili.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.core.type.TypeReference;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * B站提取记录：每次完整提取完成后的文字稿按条保存到
 * {@code <data-dir>/bili/transcripts/}，支持列表 / 详情 / 删除。
 *
 * <p>正文单独放在 {@code <id>.json}，轻量索引放在 {@code index.json}，
 * 列表不必把每条几万字的正文都读进内存。写入用临时文件替换，避免写一半损坏。</p>
 */
@Service
public class BiliTranscriptStore {

    /** 最多保留多少条记录（超出后删最旧的正文文件） */
    private static final int MAX_RECORDS = 200;

    private final AppProperties props;
    private final Object lock = new Object();

    public BiliTranscriptStore(AppProperties props) {
        this.props = props;
    }

    /**
     * 保存一条提取记录。
     *
     * @param meta 视频信息（title / owner / bvid / aid / cid / page / part / duration / source / chars）
     * @param text 完整文字稿
     * @return 记录元信息（不含正文）
     */
    public Map<String, Object> save(Map<String, Object> meta, String text) throws IOException {
        synchronized (lock) {
            Files.createDirectories(root());
            String id = newId();
            Map<String, Object> record = new LinkedHashMap<>();
            if (meta != null) {
                record.putAll(meta);
            }
            String body = text == null ? "" : text;
            record.put("id", id);
            record.put("chars", body.length());
            record.put("text", body);
            record.put("createdAt", System.currentTimeMillis());
            writeAtomic(file(id), Json.write(record));

            List<Map<String, Object>> index = readIndex();
            // 索引不存在时 readIndex 会扫描目录重建，刚写入的这条已经在里面了；先按 id 去重再加
            index.removeIf((item) -> id.equals(String.valueOf(item.get("id"))));
            index.add(metadata(record));
            index.sort(Comparator.comparingLong((Map<String, Object> item) -> longOf(item.get("createdAt"))).reversed());
            while (index.size() > MAX_RECORDS) {
                Map<String, Object> removed = index.remove(index.size() - 1);
                String removedId = String.valueOf(removed.getOrDefault("id", ""));
                if (!removedId.isBlank()) {
                    Files.deleteIfExists(file(removedId));
                }
            }
            writeIndex(index);
            return metadata(record);
        }
    }

    /** 记录列表（新→旧），不含正文 */
    public List<Map<String, Object>> list() {
        synchronized (lock) {
            return readIndex();
        }
    }

    /** 单条记录的完整内容（含正文） */
    public Map<String, Object> get(String id) {
        String safe = safeId(id);
        if (!Files.isRegularFile(file(safe))) {
            throw new ApiException(404, "这条提取记录不存在或已被删除");
        }
        try {
            return Json.MAPPER.readValue(
                    Files.readString(file(safe), StandardCharsets.UTF_8),
                    new TypeReference<Map<String, Object>>() {
                    });
        } catch (Exception e) {
            throw new ApiException(500, "读取提取记录失败：" + e.getMessage());
        }
    }

    /** 删除一条记录；不存在时返回 false */
    public boolean delete(String id) {
        synchronized (lock) {
            String safe = safeId(id);
            try {
                boolean removed = Files.deleteIfExists(file(safe));
                List<Map<String, Object>> index = readIndex();
                boolean changed = index.removeIf((item) -> safe.equals(String.valueOf(item.get("id"))));
                if (changed) {
                    writeIndex(index);
                }
                return removed || changed;
            } catch (ApiException e) {
                throw e;
            } catch (Exception e) {
                throw new ApiException(500, "删除提取记录失败：" + e.getMessage());
            }
        }
    }

    /* ── 存取 ── */

    private Path root() {
        return props.dataDirPath().resolve("bili").resolve("transcripts");
    }

    private Path file(String id) {
        return root().resolve(safeId(id) + ".json");
    }

    private Path indexFile() {
        return root().resolve("index.json");
    }

    private List<Map<String, Object>> readIndex() {
        Path path = indexFile();
        if (!Files.isRegularFile(path)) {
            return scanRecords();
        }
        try {
            List<Map<String, Object>> list = Json.MAPPER.readValue(
                    Files.readString(path, StandardCharsets.UTF_8),
                    new TypeReference<List<Map<String, Object>>>() {
                    });
            return list == null ? new ArrayList<>() : new ArrayList<>(list);
        } catch (Exception e) {
            // 索引损坏时按正文文件重建，避免记录在页面上全部消失
            return scanRecords();
        }
    }

    private void writeIndex(List<Map<String, Object>> index) throws IOException {
        writeAtomic(indexFile(), Json.write(index));
    }

    /** 没有索引（或索引损坏）时扫描正文文件重建元信息 */
    private List<Map<String, Object>> scanRecords() {
        List<Map<String, Object>> list = new ArrayList<>();
        if (!Files.isDirectory(root())) {
            return list;
        }
        try (var files = Files.list(root())) {
            files.filter((path) -> path.getFileName().toString().endsWith(".json"))
                    .filter((path) -> !"index.json".equals(path.getFileName().toString()))
                    .forEach((path) -> {
                        try {
                            Map<String, Object> record = Json.MAPPER.readValue(
                                    Files.readString(path, StandardCharsets.UTF_8),
                                    new TypeReference<Map<String, Object>>() {
                                    });
                            if (record != null) {
                                list.add(metadata(record));
                            }
                        } catch (Exception ignored) {
                            // 单个坏文件不影响其它记录
                        }
                    });
        } catch (Exception ignored) {
            // 目录读不了时返回空列表
        }
        list.sort(Comparator.comparingLong((Map<String, Object> item) -> longOf(item.get("createdAt"))).reversed());
        return list;
    }

    private Map<String, Object> metadata(Map<String, Object> record) {
        Map<String, Object> meta = new LinkedHashMap<>(record);
        meta.remove("text");
        return meta;
    }

    private void writeAtomic(Path target, String content) throws IOException {
        Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
        Files.writeString(tmp, content, StandardCharsets.UTF_8);
        try {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            // 个别文件系统不支持原子移动，退回普通替换
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static String newId() {
        return Long.toHexString(System.currentTimeMillis()) + "-"
                + UUID.randomUUID().toString().substring(0, 8);
    }

    private static String safeId(String id) {
        String value = id == null ? "" : id.trim();
        if (!value.matches("[A-Za-z0-9_-]{1,80}")) {
            throw new ApiException(400, "提取记录 id 不合法");
        }
        return value;
    }

    private static long longOf(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        try {
            return Long.parseLong(String.valueOf(value).trim());
        } catch (Exception e) {
            return 0;
        }
    }
}