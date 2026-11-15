package com.deepseekapp.webserver.feature.data.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** 把手机 App 导出的 .db 文件导入某台设备的槽位 */
@Service
public class Importer {

    private static final String SQLITE_MAGIC = "SQLite format 3\u0000";

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final SyncStore syncStore;
    private final AppProperties props;

    public Importer(DatabaseManager databaseManager, SchemaCatalog schema, SyncStore syncStore,
                    AppProperties props) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.syncStore = syncStore;
        this.props = props;
    }

    public Map<String, Object> importAppDatabase(String dbKey, byte[] buffer, String mode,
                                                 String deviceId, String originDevice) {
        if (!schema.hasDatabase(dbKey)) {
            throw new ApiException(400, "未知的数据库：" + dbKey);
        }
        if (buffer == null || buffer.length < 100) {
            throw new ApiException(400, "文件不是有效的数据库（内容过小）");
        }
        String magic = new String(buffer, 0, 16, StandardCharsets.ISO_8859_1);
        if (!SQLITE_MAGIC.equals(magic)) {
            throw new ApiException(400, "文件不是 SQLite 数据库（文件头不匹配）");
        }
        if (buffer.length > props.maxUploadBytes()) {
            throw new ApiException(413,
                    "文件超过上限 " + Math.round(props.maxUploadBytes() / 1024.0 / 1024.0) + "MB");
        }

        String target = String.valueOf(deviceId);
        String origin = originDevice == null || originDevice.isEmpty() ? target : originDevice;
        databaseManager.scopeMeta(target, connection -> null);

        Path temp = props.dataDirPath().resolve("tmp-import-" + UUID.randomUUID() + ".db");
        Map<String, Object> report = new LinkedHashMap<>();
        report.put("db", dbKey);
        report.put("mode", mode);
        report.put("deviceId", target);
        report.put("originDevice", origin);
        report.put("importedAt", System.currentTimeMillis());
        report.put("uploadedBytes", (long) buffer.length);
        Map<String, Map<String, Object>> tableReports = new LinkedHashMap<>();
        report.put("tables", tableReports);
        report.put("unknownTables", new ArrayList<String>());
        report.put("unknownColumns", new LinkedHashMap<String, List<String>>());
        report.put("warnings", new ArrayList<String>());
        report.put("totalRows", 0L);
        report.put("totalWritten", 0L);
        report.put("totalUnchanged", 0L);

        try {
            Files.write(temp, buffer);
        } catch (Exception e) {
            throw new RuntimeException("写入临时导入文件失败", e);
        }

        Connection source = null;
        try {
            source = databaseManager.openExternal(temp, true);

            Map<String, Object> versionRow = Db.queryOne(source, "PRAGMA user_version");
            long version = versionRow == null ? 0 : SyncStore.longValue(versionRow.get("user_version"), 0);
            report.put("sourceVersion", version);
            int appVersion = schema.database(dbKey).appVersion();
            if (version > appVersion) {
                throw new ApiException(409,
                        "数据库版本 v" + version + " 高于 Web 端支持的 v" + appVersion + "，请先同步 Web 端结构定义");
            }
            List<String> warnings = castList(report.get("warnings"));
            if (version < appVersion) {
                warnings.add("来源库版本 v" + version + " 低于 App 当前版本 v" + appVersion + "，缺失的列将使用默认值填充");
            }

            Set<String> expected = schema.database(dbKey).tables().keySet();
            List<Map<String, Object>> presentRows = Db.query(source,
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
            List<String> present = new ArrayList<>();
            for (Map<String, Object> row : presentRows) {
                present.add(String.valueOf(row.get("name")));
            }
            List<String> unknownTables = castList(report.get("unknownTables"));
            for (String name : present) {
                if (!expected.contains(name) && !schema.localOnlyTables().contains(name)) {
                    unknownTables.add(name);
                }
            }

            Map<String, List<String>> unknownColumns = castMap(report.get("unknownColumns"));
            for (String table : expected) {
                if (!present.contains(table)) {
                    continue;
                }
                List<String> srcCols = Db.columnsOf(source, table);
                List<String> known = schema.columnNames(dbKey, table);
                List<String> extra = new ArrayList<>();
                for (String column : srcCols) {
                    if (!known.contains(column)) {
                        extra.add(column);
                    }
                }
                if (!extra.isEmpty()) {
                    unknownColumns.put(table, extra);
                }
            }
            if (!unknownColumns.isEmpty()) {
                warnings.add("来源库存在 Web 端未定义的列，这些列的内容不会被导入：" + Json.write(unknownColumns));
            }

            List<String> order = insertionOrder(dbKey);
            List<String> available = new ArrayList<>();
            List<String> skipped = new ArrayList<>();
            for (String table : order) {
                if (present.contains(table)) {
                    available.add(table);
                } else if (!schema.tableDef(dbKey, table).isSingleton()) {
                    skipped.add(table);
                }
            }
            if (!skipped.isEmpty()) {
                warnings.add("来源库缺少这些表，已跳过：" + String.join(", ", skipped));
            }

            if ("replace".equals(mode)) {
                List<String> reversed = new ArrayList<>(order);
                Collections.reverse(reversed);
                for (String table : reversed) {
                    String pkCol = schema.primaryKey(dbKey, table);
                    List<Map<String, Object>> pks = databaseManager.app(target, dbKey, connection ->
                            Db.query(connection,
                                    "SELECT `" + pkCol + "` AS pk FROM `" + table + "` WHERE device_id = ?", target));
                    for (Map<String, Object> row : pks) {
                        syncStore.removeRow(target, dbKey, table,
                                SyncStore.longValue(row.get("pk"), 0), origin);
                    }
                    tableReports.put(table, stat(0, 0, 0, pks.size()));
                }
            }

            long[] totalRows = {0};
            long[] totalWritten = {0};
            long[] totalUnchanged = {0};
            report.put("totalRows", 0L);
            report.put("totalWritten", 0L);
            report.put("totalUnchanged", 0L);

            for (String table : available) {
                String pkCol = schema.primaryKey(dbKey, table);
                Map<String, Object> stat = tableReports.get(table);
                if (stat == null) {
                    stat = stat(0, 0, 0, 0);
                }
                int batchSize = 500;
                long offset = 0;
                while (true) {
                    List<Map<String, Object>> rows = Db.query(source,
                            "SELECT * FROM \"" + table + "\" ORDER BY rowid LIMIT ? OFFSET ?",
                            batchSize, offset);
                    if (rows.isEmpty()) {
                        break;
                    }
                    offset += rows.size();
                    for (Map<String, Object> row : rows) {
                        stat.put("read", SyncStore.longValue(stat.get("read"), 0) + 1);
                        totalRows[0]++;
                        Long pk = exactLong(row.get(pkCol));
                        if (pk == null) {
                            warnings.add(table + "：跳过缺少主键的行（" + pkCol + "=" +
                                    Json.write(row.get(pkCol)) + "）");
                            continue;
                        }
                        row.put(pkCol, pk);
                        Map<String, Object> result = syncStore.writeRow(target, dbKey, table, row, origin);
                        if (Boolean.TRUE.equals(result.get("unchanged"))) {
                            stat.put("unchanged", SyncStore.longValue(stat.get("unchanged"), 0) + 1);
                            totalUnchanged[0]++;
                        } else {
                            stat.put("written", SyncStore.longValue(stat.get("written"), 0) + 1);
                            totalWritten[0]++;
                        }
                    }
                    if (rows.size() < batchSize) {
                        break;
                    }
                }
                tableReports.put(table, stat);
            }

            report.put("totalRows", totalRows[0]);
            report.put("totalWritten", totalWritten[0]);
            report.put("totalUnchanged", totalUnchanged[0]);
            return report;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException("导入数据库失败：" + e.getMessage(), e);
        } finally {
            Db.closeQuietly(source);
            Exporter.deleteQuietly(temp);
        }
    }

    /** 由外键关系推导拓扑序：父表在前，保证插入时不违反外键约束 */
    public List<String> insertionOrder(String dbKey) {
        Set<String> tables = schema.database(dbKey).tables().keySet();
        Map<String, Set<String>> deps = new LinkedHashMap<>();
        for (String table : tables) {
            deps.put(table, new LinkedHashSet<>());
        }
        for (SchemaCatalog.ForeignKey fk : schema.foreignKeys(dbKey)) {
            if (!fk.table().equals(fk.targetTable()) && deps.containsKey(fk.table())) {
                deps.get(fk.table()).add(fk.targetTable());
            }
        }
        LinkedHashSet<String> ordered = new LinkedHashSet<>();
        Set<String> visiting = new LinkedHashSet<>();
        for (String table : tables) {
            visit(table, deps, ordered, visiting);
        }
        return new ArrayList<>(ordered);
    }

    private void visit(String table, Map<String, Set<String>> deps,
                       Set<String> ordered, Set<String> visiting) {
        if (ordered.contains(table) || visiting.contains(table)) {
            return;
        }
        visiting.add(table);
        for (String dep : deps.getOrDefault(table, Set.of())) {
            visit(dep, deps, ordered, visiting);
        }
        visiting.remove(table);
        ordered.add(table);
    }

    private Map<String, Object> stat(long read, long written, long unchanged, long cleared) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("read", read);
        out.put("written", written);
        out.put("unchanged", unchanged);
        out.put("cleared", cleared);
        return out;
    }

    private static Long exactLong(Object value) {
        if (value instanceof Number n) {
            double d = n.doubleValue();
            if (Double.isFinite(d) && d == Math.rint(d) && Math.abs(d) <= 9.007199254740992E15) {
                return (long) d;
            }
            return null;
        }
        if (value instanceof String s) {
            try {
                return Long.parseLong(s.trim());
            } catch (NumberFormatException e) {
                return null;
            }
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private static List<String> castList(Object value) {
        return (List<String>) value;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, List<String>> castMap(Object value) {
        return (Map<String, List<String>>) value;
    }
}
