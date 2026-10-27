package com.deepseekapp.webserver.sync;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.DatabaseManager.DeviceScope;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.util.Json;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * 同步核心：变更日志、行版本、冲突裁决。
 *
 * <p>与原 Node 版 syncStore.js 一一对应，所有操作都以 deviceId 为起点，
 * 只读写这台设备自己的槽位；全局 sync.db 只保留设备清单、同步请求与冲突留档。</p>
 */
@Component
public class SyncStore {

    private final DatabaseManager db;
    private final SchemaCatalog schema;
    private final AppProperties props;

    public SyncStore(DatabaseManager db, SchemaCatalog schema, AppProperties props) {
        this.db = db;
        this.schema = schema;
        this.props = props;
    }

    public static long now() {
        return System.currentTimeMillis();
    }

    // ───────────────────────────── 行指纹 ─────────────────────────────

    /** 稳定序列化：键名排序，保证同样的行内容得到同样的哈希（与 JS 版一致） */
    public static String stableStringify(Object value) {
        if (value == null) {
            return "null";
        }
        if (value instanceof String s) {
            return quote(s);
        }
        if (value instanceof Boolean b) {
            return b ? "true" : "false";
        }
        if (value instanceof Number n) {
            return numberJson(n);
        }
        if (value instanceof Map<?, ?> map) {
            TreeMap<String, Object> sorted = new TreeMap<>();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                sorted.put(String.valueOf(entry.getKey()), entry.getValue());
            }
            StringBuilder sb = new StringBuilder("{");
            boolean first = true;
            for (Map.Entry<String, Object> entry : sorted.entrySet()) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                sb.append(quote(entry.getKey())).append(':').append(stableStringify(entry.getValue()));
            }
            return sb.append('}').toString();
        }
        if (value instanceof Iterable<?> iterable) {
            StringBuilder sb = new StringBuilder("[");
            boolean first = true;
            for (Object item : iterable) {
                if (!first) {
                    sb.append(',');
                }
                first = false;
                sb.append(stableStringify(item));
            }
            return sb.append(']').toString();
        }
        return quote(String.valueOf(value));
    }

    public static String hashRow(Map<String, Object> row) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-1");
            byte[] bytes = digest.digest(stableStringify(row).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(bytes.length * 2);
            for (byte b : bytes) {
                hex.append(Character.forDigit((b >> 4) & 0xF, 16));
                hex.append(Character.forDigit(b & 0xF, 16));
            }
            return hex.toString();
        } catch (Exception e) {
            throw new RuntimeException("计算行指纹失败", e);
        }
    }

    private static String numberJson(Number number) {
        if (number instanceof Double || number instanceof Float) {
            double d = number.doubleValue();
            if (!Double.isFinite(d)) {
                return "null";
            }
            if (d == Math.rint(d) && Math.abs(d) <= 9.007199254740992E15) {
                return Long.toString((long) d);
            }
            return Double.toString(d);
        }
        if (number instanceof BigDecimal bd) {
            return bd.stripTrailingZeros().toPlainString();
        }
        return number.toString();
    }

    private static String quote(String value) {
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        return sb.append('"').toString();
    }

    // ───────────────────────────── 列处理 ─────────────────────────────

    private static Object normalizeValue(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Boolean b) {
            return b ? 1L : 0L;
        }
        if (value instanceof Byte || value instanceof Short || value instanceof Integer) {
            return ((Number) value).longValue();
        }
        if (value instanceof Long) {
            return value;
        }
        if (value instanceof Float || value instanceof Double) {
            double d = ((Number) value).doubleValue();
            if (!Double.isFinite(d)) {
                return null;
            }
            if (d == Math.rint(d) && Math.abs(d) <= 9.007199254740992E15) {
                return (long) d;
            }
            return d;
        }
        if (value instanceof BigDecimal bd) {
            return normalizeValue(bd.doubleValue());
        }
        return value;
    }

    public Map<String, Object> pickColumns(String dbKey, String tableName, Map<String, Object> row) {
        SchemaCatalog.TableDef def = schema.tableDef(dbKey, tableName);
        Map<String, Object> out = new LinkedHashMap<>();
        for (SchemaCatalog.ColumnDef column : def.columns()) {
            if (row.containsKey(column.name())) {
                out.put(column.name(), normalizeValue(row.get(column.name())));
            }
        }
        return out;
    }

    public List<String> missingRequiredColumns(String dbKey, String tableName, Map<String, Object> row) {
        SchemaCatalog.TableDef def = schema.tableDef(dbKey, tableName);
        List<String> missing = new ArrayList<>();
        for (SchemaCatalog.ColumnDef column : def.columns()) {
            if (column.isNotNull() && !column.hasDefault() && !column.isAutoincrement()
                    && !row.containsKey(column.name())) {
                missing.add(column.name());
            }
        }
        return missing;
    }

    // ───────────────────────────── 设备管理 ─────────────────────────────

    public Map<String, Object> registerDevice(String deviceId, String name, String platform, Long idBase) {
        String id = String.valueOf(deviceId);
        db.meta(meta -> {
            Map<String, Object> existing = Db.queryOne(meta,
                    "SELECT * FROM devices WHERE device_id = ?", id);
            long ts = now();
            if (existing != null) {
                String finalName = name == null || name.isEmpty() ? str(existing.get("name")) : name;
                String finalPlatform = platform == null || platform.isEmpty() ? str(existing.get("platform")) : platform;
                Db.update(meta,
                        "UPDATE devices SET name = ?, platform = ?, last_seen_at = ? WHERE device_id = ?",
                        finalName, finalPlatform, ts, id);
            } else {
                Db.update(meta,
                        "INSERT INTO devices (device_id, name, platform, id_base, scope_dir, last_seen_at, created_at) " +
                                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                        id, name == null ? "" : name, platform == null ? "" : platform,
                        idBase == null || idBase <= 0 ? 1L : idBase, "", ts, ts);
            }
            return null;
        });

        // 建槽位（并补写 scope_dir）
        db.scopeMeta(id, connection -> null);

        if (idBase != null && idBase > 0) {
            db.meta(meta -> {
                Map<String, Object> row = Db.queryOne(meta,
                        "SELECT id_base FROM devices WHERE device_id = ?", id);
                long current = row == null ? 0 : longValue(row.get("id_base"), 0);
                if (current != idBase) {
                    Db.update(meta, "UPDATE devices SET id_base = ? WHERE device_id = ?", idBase, id);
                }
                return null;
            });
        }
        return db.meta(meta -> Db.queryOne(meta, "SELECT * FROM devices WHERE device_id = ?", id));
    }

    public List<Map<String, Object>> listDevices(boolean includeStats) {
        return db.meta(meta -> {
            List<Map<String, Object>> devices = Db.query(meta,
                    "SELECT * FROM devices ORDER BY created_at ASC");
            Map<String, Map<String, Object>> cursors = new HashMap<>();
            for (Map<String, Object> cursor : Db.query(meta, "SELECT * FROM device_cursors")) {
                cursors.put(str(cursor.get("device_id")), cursor);
            }

            List<Map<String, Object>> out = new ArrayList<>();
            for (Map<String, Object> d : devices) {
                String deviceId = str(d.get("device_id"));
                Map<String, Object> cursor = cursors.get(deviceId);
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("deviceId", deviceId);
                item.put("name", d.get("name"));
                item.put("platform", d.get("platform"));
                item.put("idBase", d.get("id_base"));
                item.put("scopeDir", d.get("scope_dir"));
                item.put("createdAt", d.get("created_at"));
                item.put("lastSeenAt", d.get("last_seen_at"));
                item.put("cursor", cursor == null ? 0L : longValue(cursor.get("last_pull_seq"), 0));
                item.put("lastPushAt", cursor == null ? null : cursor.get("last_push_at"));
                item.put("lastPullAt", cursor == null ? null : cursor.get("last_pull_at"));
                if (!includeStats) {
                    out.add(item);
                } else {
                    Map<String, Object> rows = new LinkedHashMap<>();
                    long total = 0;
                    for (Map.Entry<String, SchemaCatalog.DatabaseDef> dbEntry : schema.databases().entrySet()) {
                        for (String table : dbEntry.getValue().tables().keySet()) {
                            long count = countRows(deviceId, dbEntry.getKey(), table);
                            if (count > 0) {
                                rows.put(dbEntry.getKey() + "." + table, count);
                                total += count;
                            }
                        }
                    }
                    Map<String, Object> conflictRow = Db.queryOne(meta,
                            "SELECT COUNT(*) AS n FROM conflicts WHERE device_id = ?", deviceId);
                    item.put("rowsOwned", total);
                    item.put("rowCounts", rows);
                    item.put("conflicts", conflictRow == null ? 0L : longValue(conflictRow.get("n"), 0));
                    out.add(item);
                }
            }
            return out;
        });
    }

    private long countRows(String deviceId, String dbKey, String table) {
        Map<String, Object> row = db.app(deviceId, dbKey, connection ->
                Db.queryOne(connection, "SELECT COUNT(*) AS c FROM " + table));
        return row == null ? 0 : longValue(row.get("c"), 0);
    }

    public boolean deviceExists(String deviceId) {
        return db.meta(meta -> Db.queryOne(meta,
                "SELECT 1 AS x FROM devices WHERE device_id = ?", String.valueOf(deviceId)) != null);
    }

    public List<String> knownDeviceIds() {
        return db.knownDeviceIds();
    }

    public Map<String, Object> removeDevice(String deviceId) {
        String id = String.valueOf(deviceId);
        return db.meta(meta -> {
            boolean existed = Db.queryOne(meta,
                    "SELECT 1 AS x FROM devices WHERE device_id = ?", id) != null;
            Db.update(meta, "DELETE FROM device_cursors WHERE device_id = ?", id);
            Db.update(meta, "DELETE FROM conflicts WHERE device_id = ?", id);
            Db.update(meta, "DELETE FROM devices WHERE device_id = ?", id);
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("deviceId", id);
            out.put("existed", existed);
            return out;
        });
    }

    public long syncRevision() {
        return db.meta(meta -> {
            Map<String, Object> row = Db.queryOne(meta,
                    "SELECT COUNT(*) AS n, COALESCE(MAX(created_at), 0) AS t FROM devices");
            long n = row == null ? 0 : longValue(row.get("n"), 0);
            long t = row == null ? 0 : longValue(row.get("t"), 0);
            return n * 10_000_000_000_000L + t;
        });
    }

    private void touchDevice(String deviceId, String field) {
        if (!field.equals("last_push_at") && !field.equals("last_pull_at")) {
            throw new IllegalArgumentException("非法字段：" + field);
        }
        long ts = now();
        db.meta(meta -> {
            Db.update(meta,
                    "INSERT INTO device_cursors (device_id, " + field + ") VALUES (?, ?) " +
                            "ON CONFLICT(device_id) DO UPDATE SET " + field + " = excluded." + field,
                    deviceId, ts);
            Db.update(meta, "UPDATE devices SET last_seen_at = ? WHERE device_id = ?", ts, deviceId);
            return null;
        });
    }

    // ───────────────────────────── 写入路径 ─────────────────────────────

    public Map<String, Object> writeRow(String deviceId, String dbKey, String tableName,
                                        Map<String, Object> row, String originDevice) {
        if (!schema.hasTable(dbKey, tableName)) {
            throw new IllegalArgumentException("未知的表：" + dbKey + "." + tableName);
        }
        return db.scope(deviceId, scope -> {
            Connection appDb = scope.db(dbKey);
            Connection meta = db.scopeMetaConnection(scope);
            String pkCol = schema.primaryKey(dbKey, tableName);
            Map<String, Object> cols = pickColumns(dbKey, tableName, row);
            Long pk = exactLong(cols.get(pkCol));
            if (pk == null) {
                throw new IllegalArgumentException("缺少合法主键 " + pkCol +
                        "（收到：" + Json.write(cols.get(pkCol)) + "）");
            }

            Map<String, Object> prev = Db.queryOne(meta,
                    "SELECT * FROM row_meta WHERE db = ? AND table_name = ? AND pk = ?",
                    dbKey, tableName, pk);
            String hash = hashRow(cols);
            long ts = now();

            if (prev != null && longValue(prev.get("deleted"), 0) == 0
                    && hash.equals(str(prev.get("content_hash")))) {
                Map<String, Object> out = new LinkedHashMap<>();
                out.put("seq", 0L);
                out.put("rev", prev.get("rev"));
                out.put("pk", pk);
                out.put("unchanged", true);
                return out;
            }

            long rev = (prev == null ? 0 : longValue(prev.get("rev"), 0)) + 1;
            List<String> colNames = new ArrayList<>(cols.keySet());
            String placeholders = String.join(", ", java.util.Collections.nCopies(colNames.size(), "?"));
            List<String> updates = new ArrayList<>();
            for (String c : colNames) {
                if (!c.equals(pkCol)) {
                    updates.add(c + " = excluded." + c);
                }
            }
            String sql = "INSERT INTO " + tableName + " (" + String.join(", ", colNames) + ") VALUES (" +
                    placeholders + ") ON CONFLICT(" + pkCol + ") DO " +
                    (updates.isEmpty() ? "NOTHING" : "UPDATE SET " + String.join(", ", updates));

            Object[] args = new Object[colNames.size()];
            for (int i = 0; i < colNames.size(); i++) {
                args[i] = cols.get(colNames.get(i));
            }
            Db.transaction(appDb, () -> Db.update(appDb, sql, args));

            long seq = appendLog(meta, dbKey, tableName, pk, "upsert", rev, originDevice, ts, cols);
            upsertRowMeta(meta, dbKey, tableName, pk, rev, originDevice, ts, 0, hash);

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("seq", seq);
            out.put("rev", rev);
            out.put("pk", pk);
            out.put("unchanged", false);
            return out;
        });
    }

    public Map<String, Object> removeRow(String deviceId, String dbKey, String tableName, long pk,
                                         String originDevice) {
        if (!schema.hasTable(dbKey, tableName)) {
            throw new IllegalArgumentException("未知的表：" + dbKey + "." + tableName);
        }
        return db.scope(deviceId, scope -> {
            Connection appDb = scope.db(dbKey);
            Connection meta = db.scopeMetaConnection(scope);
            String pkCol = schema.primaryKey(dbKey, tableName);
            Map<String, Object> prev = Db.queryOne(meta,
                    "SELECT * FROM row_meta WHERE db = ? AND table_name = ? AND pk = ?",
                    dbKey, tableName, pk);
            long ts = now();
            long rev = (prev == null ? 0 : longValue(prev.get("rev"), 0)) + 1;

            int[] changed = {0};
            Db.transaction(appDb, () -> {
                changed[0] = Db.update(appDb, "DELETE FROM " + tableName + " WHERE " + pkCol + " = ?", pk);
            });
            long seq = appendLog(meta, dbKey, tableName, pk, "delete", rev, originDevice, ts, null);
            upsertRowMeta(meta, dbKey, tableName, pk, rev, originDevice, ts, 1, "");

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("seq", seq);
            out.put("rev", rev);
            out.put("pk", pk);
            out.put("existed", changed[0] > 0);
            return out;
        });
    }

    /**
     * 级联删除：App 库中父子表是 ON DELETE CASCADE 关系，直接删父行会让子行在
     * SQLite 层被静默删掉、却不产生变更日志。这里手动按外键递归删除并逐条记日志。
     */
    public Map<String, Object> removeRowCascade(String deviceId, String dbKey, String tableName,
                                                long pk, String originDevice) {
        Map<String, List<SchemaCatalog.ForeignKey>> dependentTables = new HashMap<>();
        for (SchemaCatalog.ForeignKey fk : schema.foreignKeys(dbKey)) {
            if (fk.table().equals(fk.targetTable())) {
                continue;
            }
            dependentTables.computeIfAbsent(fk.targetTable(), k -> new ArrayList<>()).add(fk);
        }

        List<Map<String, Object>> deleted = new ArrayList<>();
        visitForCascade(deviceId, dbKey, tableName, pk, originDevice, dependentTables, deleted);

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("deleted", deleted);
        out.put("count", deleted.size());
        out.put("rootPk", pk);
        return out;
    }

    private void visitForCascade(String deviceId, String dbKey, String table, long pk, String originDevice,
                                 Map<String, List<SchemaCatalog.ForeignKey>> dependentTables,
                                 List<Map<String, Object>> deleted) {
        String pkCol = schema.primaryKey(dbKey, table);
        Boolean exists = db.app(deviceId, dbKey, connection ->
                Db.queryOne(connection, "SELECT 1 AS x FROM " + table + " WHERE " + pkCol + " = ?", pk) != null);
        if (!Boolean.TRUE.equals(exists)) {
            return;
        }
        for (SchemaCatalog.ForeignKey fk : dependentTables.getOrDefault(table, List.of())) {
            List<Map<String, Object>> children = db.app(deviceId, dbKey, connection ->
                    Db.query(connection,
                            "SELECT " + schema.primaryKey(dbKey, fk.table()) + " AS ck FROM " + fk.table() +
                                    " WHERE " + fk.column() + " = ?", pk));
            for (Map<String, Object> child : children) {
                long childPk = longValue(child.get("ck"), 0);
                visitForCascade(deviceId, dbKey, fk.table(), childPk, originDevice, dependentTables, deleted);
            }
        }
        Map<String, Object> result = removeRow(deviceId, dbKey, table, pk, originDevice);
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("table", table);
        item.put("pk", pk);
        item.put("rev", result.get("rev"));
        item.put("seq", result.get("seq"));
        deleted.add(item);
    }

    private long appendLog(Connection meta, String dbKey, String tableName, long pk, String op,
                           long rev, String originDevice, long ts, Map<String, Object> payload) {
        return Db.insertReturningId(meta,
                "INSERT INTO change_log (db, table_name, pk, op, rev, origin_device, server_time, payload) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                dbKey, tableName, pk, op, rev, originDevice, ts,
                payload == null ? null : Json.write(payload));
    }

    private void upsertRowMeta(Connection meta, String dbKey, String tableName, long pk, long rev,
                               String originDevice, long ts, int deleted, String hash) {
        Db.update(meta,
                "INSERT INTO row_meta (db, table_name, pk, rev, origin_device, updated_at, deleted, content_hash) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?) " +
                        "ON CONFLICT(db, table_name, pk) DO UPDATE SET " +
                        "rev = excluded.rev, origin_device = excluded.origin_device, updated_at = excluded.updated_at, " +
                        "deleted = excluded.deleted, content_hash = excluded.content_hash",
                dbKey, tableName, pk, rev, originDevice, ts, deleted, hash);
    }

    public long currentSeq(String deviceId) {
        return db.scopeMeta(deviceId, meta -> {
            Map<String, Object> row = Db.queryOne(meta,
                    "SELECT COALESCE(MAX(seq), 0) AS seq FROM change_log");
            return row == null ? 0 : longValue(row.get("seq"), 0);
        });
    }

    public long rowRevOf(String deviceId, String dbKey, String tableName, long pk) {
        return db.scopeMeta(deviceId, meta -> {
            Map<String, Object> row = Db.queryOne(meta,
                    "SELECT rev FROM row_meta WHERE db = ? AND table_name = ? AND pk = ?",
                    dbKey, tableName, pk);
            return row == null ? 0 : longValue(row.get("rev"), 0);
        });
    }

    // ───────────────────────────── 拉取 / 推送 ─────────────────────────────

    public Map<String, Object> pullChanges(String deviceId, long since, int limit, String dbKey) {
        if (deviceId == null || deviceId.isEmpty()) {
            throw new IllegalArgumentException("pullChanges 需要 deviceId");
        }
        return db.scope(deviceId, scope -> {
            Connection meta = db.scopeMetaConnection(scope);
            List<String> where = new ArrayList<>();
            List<Object> args = new ArrayList<>();
            where.add("seq > ?");
            args.add(since);
            if (dbKey != null) {
                where.add("db = ?");
                args.add(dbKey);
            }
            args.add(limit);
            List<Map<String, Object>> rows = Db.query(meta,
                    "SELECT seq, db, table_name, pk, op, rev, origin_device, server_time, payload FROM change_log " +
                            "WHERE " + String.join(" AND ", where) + " ORDER BY seq ASC LIMIT ?",
                    args.toArray());

            List<Map<String, Object>> changes = new ArrayList<>();
            long lastSeq = since;
            for (Map<String, Object> r : rows) {
                Map<String, Object> change = new LinkedHashMap<>();
                change.put("seq", r.get("seq"));
                change.put("db", r.get("db"));
                change.put("table", r.get("table_name"));
                change.put("pk", r.get("pk"));
                change.put("op", r.get("op"));
                change.put("rev", r.get("rev"));
                change.put("originDevice", r.get("origin_device"));
                change.put("serverTime", r.get("server_time"));
                Object payload = r.get("payload");
                change.put("row", payload == null ? null : Json.parse(String.valueOf(payload)));
                changes.add(change);
                lastSeq = longValue(r.get("seq"), lastSeq);
            }
            long maxSeq = currentSeq(deviceId);

            touchDevice(deviceId, "last_pull_at");

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("changes", changes);
            out.put("lastSeq", lastSeq);
            out.put("serverSeq", maxSeq);
            out.put("hasMore", lastSeq < maxSeq);
            out.put("skippedOwn", 0);
            return out;
        });
    }

    public Map<String, Object> pushChanges(String deviceId, List<Map<String, Object>> changes, String strategy) {
        return db.scope(deviceId, scope -> {
            Connection meta = db.scopeMetaConnection(scope);
            registerDevice(deviceId, deviceId, "", null);
            touchDevice(deviceId, "last_push_at");

            List<Map<String, Object>> results = new ArrayList<>();
            long accepted = 0;
            long conflicts = 0;
            long skipped = 0;

            for (Map<String, Object> change : changes) {
                String dbKey = str(change.get("db"));
                String table = str(change.get("table"));
                Object pkRaw = change.get("pk");
                String op = str(change.get("op"));
                long pkNum = longValue(pkRaw, 0);

                if (!schema.hasTable(dbKey, table)) {
                    Map<String, Object> result = new LinkedHashMap<>(change);
                    result.put("status", "error");
                    result.put("message", "未知的表 " + dbKey + "." + table);
                    results.add(result);
                    continue;
                }

                if ("delete".equals(op)) {
                    Map<String, Object> prev = Db.queryOne(meta,
                            "SELECT * FROM row_meta WHERE db = ? AND table_name = ? AND pk = ?",
                            dbKey, table, pkNum);
                    long incomingRev = longValue(change.get("rev"), 0);
                    if (prev != null && longValue(prev.get("rev"), 0) > incomingRev) {
                        conflicts++;
                        recordConflict(deviceId, dbKey, table, pkNum, incomingRev,
                                longValue(prev.get("rev"), 0), deviceId, "server-wins", "");
                        results.add(result(change, "conflict", null, null, longValue(prev.get("rev"), 0), null));
                        continue;
                    }
                    Map<String, Object> r = removeRow(deviceId, dbKey, table, pkNum, deviceId);
                    accepted++;
                    results.add(result(change, "applied", r.get("rev"), r.get("seq"), null, null));
                    continue;
                }

                Object rowRaw = change.get("row");
                Map<String, Object> row = Json.asMap(rowRaw);
                if (row == null) {
                    results.add(result(change, "error", null, null, null, "upsert 缺少 row 快照"));
                    continue;
                }
                List<String> missing = missingRequiredColumns(dbKey, table, row);
                if (!missing.isEmpty()) {
                    results.add(result(change, "error", null, null, null,
                            "缺少必填列：" + String.join(", ", missing)));
                    continue;
                }

                Map<String, Object> prev = Db.queryOne(meta,
                        "SELECT * FROM row_meta WHERE db = ? AND table_name = ? AND pk = ?",
                        dbKey, table, pkNum);
                long incomingRev = longValue(change.get("rev"), 0);
                Map<String, Object> cols = pickColumns(dbKey, table, row);
                String incomingHash = hashRow(cols);

                if (prev != null && longValue(prev.get("deleted"), 0) == 0) {
                    if (incomingHash.equals(str(prev.get("content_hash")))) {
                        skipped++;
                        results.add(result(change, "unchanged", prev.get("rev"), null, null, null));
                        continue;
                    }
                    String winner = "client";
                    long serverRev = longValue(prev.get("rev"), 0);
                    if (incomingRev < serverRev) {
                        winner = "server";
                    } else if (incomingRev == serverRev) {
                        if ("client-wins".equals(strategy)) {
                            winner = "client";
                        } else if ("last-write-wins".equals(strategy)) {
                            long incomingTime = longValue(change.get("updatedAt"), 0);
                            winner = incomingTime >= longValue(prev.get("updated_at"), 0) ? "client" : "server";
                        } else {
                            winner = "server";
                        }
                    }
                    if ("server".equals(winner)) {
                        conflicts++;
                        String detail = Json.write(Map.of(
                                "incomingHash", incomingHash,
                                "serverHash", str(prev.get("content_hash")),
                                "strategy", strategy == null ? "server-wins" : strategy));
                        recordConflict(deviceId, dbKey, table, pkNum, incomingRev, serverRev,
                                deviceId, "server-wins", detail);
                        Map<String, Object> serverRow = readRow(deviceId, dbKey, table, pkNum);
                        results.add(result(change, "conflict", null, null, serverRev, null, serverRow));
                        continue;
                    }
                }

                Map<String, Object> seeded = new LinkedHashMap<>(row);
                seeded.put(schema.primaryKey(dbKey, table), pkNum);
                Map<String, Object> r = writeRow(deviceId, dbKey, table, seeded, deviceId);
                accepted++;
                results.add(result(change, "applied", r.get("rev"), r.get("seq"), null, null));
            }

            Map<String, Object> out = new LinkedHashMap<>();
            out.put("accepted", accepted);
            out.put("skipped", skipped);
            out.put("conflicts", conflicts);
            out.put("serverSeq", currentSeq(deviceId));
            out.put("results", results);
            return out;
        });
    }

    private Map<String, Object> result(Map<String, Object> change, String status, Object rev, Object seq,
                                       Object serverRev, String message) {
        return result(change, status, rev, seq, serverRev, message, null);
    }

    private Map<String, Object> result(Map<String, Object> change, String status, Object rev, Object seq,
                                       Object serverRev, String message, Map<String, Object> serverRow) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("db", change.get("db"));
        out.put("table", change.get("table"));
        out.put("pk", change.get("pk"));
        out.put("op", change.get("op"));
        out.put("status", status);
        if (rev != null) {
            out.put("rev", rev);
        }
        if (seq != null) {
            out.put("seq", seq);
        }
        if (serverRev != null) {
            out.put("serverRev", serverRev);
        }
        if (message != null) {
            out.put("message", message);
        }
        if (serverRow != null) {
            out.put("serverRow", serverRow);
        }
        return out;
    }

    private void recordConflict(String deviceId, String dbKey, String table, long pk,
                                long incomingRev, long serverRev, String incomingDevice,
                                String resolution, String detail) {
        db.meta(meta -> {
            Db.update(meta,
                    "INSERT INTO conflicts (device_id, db, table_name, pk, incoming_rev, server_rev, " +
                            "incoming_device, detected_at, resolution, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    deviceId, dbKey, table, pk, incomingRev, serverRev, incomingDevice, now(),
                    resolution, detail == null ? "" : detail);
            return null;
        });
    }

    public List<Map<String, Object>> listConflicts(long limit, boolean unresolvedOnly, String deviceId) {
        return db.meta(meta -> {
            List<String> where = new ArrayList<>();
            List<Object> args = new ArrayList<>();
            if (unresolvedOnly) {
                where.add("resolution = 'server-wins'");
            }
            if (deviceId != null) {
                where.add("device_id = ?");
                args.add(deviceId);
            }
            args.add(limit);
            List<Map<String, Object>> rows = Db.query(meta,
                    "SELECT * FROM conflicts" +
                            (where.isEmpty() ? "" : " WHERE " + String.join(" AND ", where)) +
                            " ORDER BY id DESC LIMIT ?",
                    args.toArray());
            List<Map<String, Object>> out = new ArrayList<>();
            for (Map<String, Object> r : rows) {
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("id", r.get("id"));
                item.put("deviceId", r.get("device_id"));
                item.put("db", r.get("db"));
                item.put("table", r.get("table_name"));
                item.put("pk", r.get("pk"));
                item.put("incomingRev", r.get("incoming_rev"));
                item.put("serverRev", r.get("server_rev"));
                item.put("incomingDevice", r.get("incoming_device"));
                item.put("detectedAt", r.get("detected_at"));
                item.put("resolution", r.get("resolution"));
                item.put("detail", r.get("detail"));
                out.add(item);
            }
            return out;
        });
    }

    // ───────────────────────────── 同步请求 ─────────────────────────────

    private Map<String, Object> mapSyncRequest(Map<String, Object> r) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", r.get("id"));
        out.put("targetDevice", r.get("target_device"));
        out.put("requestedBy", r.get("requested_by"));
        out.put("requestedAt", r.get("requested_at"));
        out.put("status", r.get("status"));
        out.put("claimedAt", r.get("claimed_at"));
        out.put("finishedAt", r.get("finished_at"));
        out.put("result", r.get("result"));
        return out;
    }

    public Map<String, Object> getSyncRequest(long id) {
        return db.meta(meta -> {
            Map<String, Object> r = Db.queryOne(meta, "SELECT * FROM sync_requests WHERE id = ?", id);
            if (r == null) {
                return null;
            }
            Map<String, Object> out = mapSyncRequest(r);
            Map<String, Object> p = Db.queryOne(meta, "SELECT * FROM sync_progress WHERE request_id = ?", id);
            if (p == null) {
                out.put("progress", null);
            } else {
                Map<String, Object> progress = new LinkedHashMap<>();
                progress.put("message", p.get("message"));
                progress.put("current", p.get("current"));
                progress.put("total", p.get("total"));
                progress.put("updatedAt", p.get("updated_at"));
                out.put("progress", progress);
            }
            return out;
        });
    }

    public Map<String, Object> updateSyncProgress(long id, String message, Long current, Long total) {
        String text = message == null ? "" : (message.length() > 200 ? message.substring(0, 200) : message);
        db.meta(meta -> {
            Db.update(meta,
                    "INSERT INTO sync_progress (request_id, message, current, total, updated_at) VALUES (?, ?, ?, ?, ?) " +
                            "ON CONFLICT(request_id) DO UPDATE SET message = excluded.message, " +
                            "current = excluded.current, total = excluded.total, updated_at = excluded.updated_at",
                    id, text, current, total, now());
            return null;
        });
        return getSyncRequest(id);
    }

    public Map<String, Object> createSyncRequest(String targetDevice, String requestedBy) {
        return db.meta(meta -> {
            Db.update(meta, "DELETE FROM sync_requests WHERE requested_at < ?", now() - 86_400_000L);
            long id = Db.insertReturningId(meta,
                    "INSERT INTO sync_requests (target_device, requested_by, requested_at, status) VALUES (?, ?, ?, ?)",
                    targetDevice == null ? "" : targetDevice, requestedBy == null ? "" : requestedBy, now(), "pending");
            return getSyncRequest(id);
        });
    }

    public Map<String, Object> claimPendingRequest(String deviceId) {
        return db.meta(meta -> {
            Map<String, Object> row = Db.queryOne(meta,
                    "SELECT * FROM sync_requests WHERE status = 'pending' AND (target_device = '' OR target_device = ?) " +
                            "ORDER BY id ASC LIMIT 1", deviceId == null ? "" : deviceId);
            if (row == null) {
                return null;
            }
            long id = longValue(row.get("id"), 0);
            Db.update(meta, "UPDATE sync_requests SET status = ?, claimed_at = ? WHERE id = ?", "claimed", now(), id);
            return getSyncRequest(id);
        });
    }

    public Map<String, Object> completeSyncRequest(long id, String status, String result) {
        String finalStatus = "failed".equals(status) ? "failed" : "done";
        db.meta(meta -> {
            Db.update(meta, "UPDATE sync_requests SET status = ?, finished_at = ?, result = ? WHERE id = ?",
                    finalStatus, now(), result == null ? "" : (result.length() > 500 ? result.substring(0, 500) : result), id);
            Db.update(meta, "DELETE FROM sync_progress WHERE request_id = ?", id);
            return null;
        });
        return getSyncRequest(id);
    }

    public List<Map<String, Object>> listSyncRequests(long limit) {
        return db.meta(meta -> {
            List<Map<String, Object>> rows = Db.query(meta,
                    "SELECT * FROM sync_requests ORDER BY id DESC LIMIT ?", limit);
            List<Map<String, Object>> out = new ArrayList<>();
            for (Map<String, Object> row : rows) {
                out.add(mapSyncRequest(row));
            }
            return out;
        });
    }

    // ───────────────────────────── 读取与统计 ─────────────────────────────

    public Map<String, Object> readRow(String deviceId, String dbKey, String tableName, long pk) {
        String pkCol = schema.primaryKey(dbKey, tableName);
        return db.app(deviceId, dbKey, connection ->
                Db.queryOne(connection, "SELECT * FROM " + tableName + " WHERE " + pkCol + " = ?", pk));
    }

    public Map<String, Object> readRow(String deviceId, String dbKey, String tableName, Object pk) {
        Long value = exactLong(pk);
        if (value == null) {
            return null;
        }
        return readRow(deviceId, dbKey, tableName, value.longValue());
    }

    public Map<String, Object> statistics(String deviceId) {
        return db.scope(deviceId, scope -> {
            Connection meta = db.scopeMetaConnection(scope);
            Map<String, Object> out = new LinkedHashMap<>();
            for (Map.Entry<String, SchemaCatalog.DatabaseDef> dbEntry : schema.databases().entrySet()) {
                String dbKey = dbEntry.getKey();
                SchemaCatalog.DatabaseDef def = dbEntry.getValue();
                Connection appDb = scope.db(dbKey);
                Map<String, Object> tables = new LinkedHashMap<>();
                long total = 0;
                for (String tableName : def.tables().keySet()) {
                    Map<String, Object> countRow = Db.queryOne(appDb,
                            "SELECT COUNT(*) AS c FROM " + tableName);
                    long count = countRow == null ? 0 : longValue(countRow.get("c"), 0);
                    Map<String, Object> latest = Db.queryOne(meta,
                            "SELECT MAX(updated_at) AS t FROM row_meta WHERE db = ? AND table_name = ? AND deleted = 0",
                            dbKey, tableName);
                    Map<String, Object> item = new LinkedHashMap<>();
                    item.put("count", count);
                    item.put("updatedAt", latest == null ? null : latest.get("t"));
                    tables.put(tableName, item);
                    total += count;
                }
                Map<String, Object> dbStats = new LinkedHashMap<>();
                dbStats.put("label", def.label());
                dbStats.put("file", def.file());
                dbStats.put("appVersion", def.appVersion());
                dbStats.put("total", total);
                dbStats.put("tables", tables);
                out.put(dbKey, dbStats);
            }
            return out;
        });
    }

    public Map<String, Object> pruneChangeLog(String deviceId) {
        return db.scope(deviceId, scope -> {
            Connection meta = db.scopeMetaConnection(scope);
            Map<String, Object> cursor = db.meta(global ->
                    Db.queryOne(global, "SELECT last_pull_seq AS seq FROM device_cursors WHERE device_id = ?", deviceId));
            long seq = cursor == null ? 0 : longValue(cursor.get("seq"), 0);
            Map<String, Object> out = new LinkedHashMap<>();
            if (seq <= 0) {
                out.put("pruned", 0L);
                out.put("upTo", 0L);
                return out;
            }
            int pruned = Db.update(meta, "DELETE FROM change_log WHERE seq <= ?", seq);
            out.put("pruned", (long) pruned);
            out.put("upTo", seq);
            return out;
        });
    }

    /** Web 端在某台设备槽位里新建行时分配主键：从 10 亿起，避开手机端 ID 空间 */
    public long allocateWebId(String deviceId, String dbKey, String tableName) {
        String pkCol = schema.primaryKey(dbKey, tableName);
        long base = schema.webIdBase();
        return db.scope(deviceId, scope -> {
            Map<String, Object> appMax = Db.queryOne(scope.db(dbKey),
                    "SELECT COALESCE(MAX(" + pkCol + "), 0) AS m FROM " + tableName);
            Map<String, Object> metaMax = Db.queryOne(db.scopeMetaConnection(scope),
                    "SELECT COALESCE(MAX(pk), 0) AS m FROM row_meta WHERE db = ? AND table_name = ?",
                    dbKey, tableName);
            long maxSeen = Math.max(
                    appMax == null ? 0 : longValue(appMax.get("m"), 0),
                    metaMax == null ? 0 : longValue(metaMax.get("m"), 0));
            return maxSeen >= base ? maxSeen + 1 : base;
        });
    }

    // ───────────────────────────── 工具 ─────────────────────────────

    public static long longValue(Object value, long fallback) {
        if (value instanceof Number n) {
            return n.longValue();
        }
        if (value instanceof String s) {
            try {
                return Long.parseLong(s.trim());
            } catch (NumberFormatException e) {
                return fallback;
            }
        }
        return fallback;
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

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }
}
