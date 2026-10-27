package com.deepseekapp.webserver.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** 通用数据接口：/api/data/{db}/{table}[/{pk}]，按 schema 自动适配所有表 */
@RestController
@RequestMapping("/api/data")
public class DataController {

    private static final Set<String> RESERVED = Set.of(
            "page", "pageSize", "q", "orderBy", "dir", "full", "maxTextLength");
    private static final Pattern TIME_COLUMN = Pattern.compile(
            "(^|_)(created?_at|create_time|timestamp|updated_at|update_time)$");
    private static final DateTimeFormatter ISO_MILLIS = DateTimeFormatter
            .ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
            .withZone(ZoneOffset.UTC);

    private final AppProperties props;
    private final SchemaCatalog schema;
    private final SyncStore syncStore;
    private final DatabaseManager databaseManager;

    public DataController(AppProperties props, SchemaCatalog schema, SyncStore syncStore,
                          DatabaseManager databaseManager) {
        this.props = props;
        this.schema = schema;
        this.syncStore = syncStore;
        this.databaseManager = databaseManager;
    }

    @GetMapping("/{db}/{table}")
    public Map<String, Object> list(@PathVariable String db, @PathVariable String table,
                                    HttpServletRequest request) {
        requireTable(db, table);
        String deviceId = RequestDevice.deviceId(request, props);
        SchemaCatalog.TableDef def = schema.tableDef(db, table);
        String pkCol = schema.primaryKey(db, table);

        int page = Math.max(1, parseInt(request.getParameter("page"), 1));
        int rawSize = parseInt(request.getParameter("pageSize"), props.getDefaultPageSize());
        int pageSize = Math.min(Math.max(1, rawSize), props.getMaxPageSize());
        long offset = (long) (page - 1) * pageSize;

        List<String> where = new ArrayList<>();
        List<Object> args = new ArrayList<>();
        Map<String, Object> filters = new LinkedHashMap<>();

        for (Map.Entry<String, String[]> entry : request.getParameterMap().entrySet()) {
            String key = entry.getKey();
            if (RESERVED.contains(key)) {
                continue;
            }
            if (!schema.columnNames(db, table).contains(key)) {
                continue;
            }
            where.add(key + " = ?");
            args.add(entry.getValue().length == 0 ? "" : entry.getValue()[0]);
            filters.put(key, entry.getValue().length == 0 ? "" : entry.getValue()[0]);
        }

        String q = request.getParameter("q");
        q = q == null ? "" : q.trim();
        if (!q.isEmpty()) {
            List<String> searchColumns = def.searchColumns();
            if (searchColumns.isEmpty()) {
                throw new ApiException(400, "该表不支持关键字搜索");
            }
            List<String> parts = new ArrayList<>();
            for (String column : searchColumns) {
                parts.add(column + " LIKE ?");
                args.add("%" + q + "%");
            }
            where.add("(" + String.join(" OR ", parts) + ")");
        }

        String orderBy = request.getParameter("orderBy");
        if (orderBy == null || !schema.columnNames(db, table).contains(orderBy)) {
            orderBy = null;
        }
        String dir = "asc".equalsIgnoreCase(request.getParameter("dir")) ? "ASC" : "DESC";
        String orderClause;
        if (orderBy != null) {
            orderClause = " ORDER BY " + orderBy + " " + dir;
        } else if (def.orderBy() != null) {
            orderClause = " ORDER BY " + def.orderBy();
        } else {
            orderClause = " ORDER BY " + pkCol + " DESC";
        }
        String whereSql = where.isEmpty() ? "" : " WHERE " + String.join(" AND ", where);

        boolean full = "1".equals(request.getParameter("full")) || "true".equals(request.getParameter("full"));
        int maxText = parseInt(request.getParameter("maxTextLength"), 300);

        List<Object> rowArgs = new ArrayList<>(args);
        rowArgs.add(pageSize);
        rowArgs.add(offset);

        String finalOrderClause = orderClause;
        String finalWhereSql = whereSql;
        Map<String, Object> result = databaseManager.app(deviceId, db, connection -> {
            Map<String, Object> countRow = Db.queryOne(connection,
                    "SELECT COUNT(*) AS c FROM " + table + finalWhereSql, args.toArray());
            long total = countRow == null ? 0 : SyncStore.longValue(countRow.get("c"), 0);
            List<Map<String, Object>> rows = Db.query(connection,
                    "SELECT * FROM " + table + finalWhereSql + finalOrderClause + " LIMIT ? OFFSET ?",
                    rowArgs.toArray());
            List<Map<String, Object>> shaped = new ArrayList<>();
            for (Map<String, Object> row : rows) {
                shaped.add(full ? row : truncateRow(row, maxText));
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("rows", shaped);
            out.put("total", total);
            return out;
        });

        @SuppressWarnings("unchecked")
        List<Map<String, Object>> shaped = (List<Map<String, Object>>) result.get("rows");
        long total = (long) result.get("total");

        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("page", page);
        meta.put("pageSize", pageSize);
        meta.put("total", total);
        meta.put("pages", total == 0 ? 1 : (long) Math.ceil((double) total / pageSize));
        meta.put("truncated", !full);
        meta.put("db", db);
        meta.put("table", table);
        meta.put("label", def.label());
        meta.put("filters", filters);
        meta.put("deviceId", deviceId);
        return Api.ok(shaped, meta);
    }

    @GetMapping("/{db}/{table}/{pk}")
    public Map<String, Object> detail(@PathVariable String db, @PathVariable String table,
                                      @PathVariable String pk, HttpServletRequest request) {
        requireTable(db, table);
        String deviceId = RequestDevice.deviceId(request, props);
        Long key = parseLong(pk);
        Map<String, Object> row = key == null ? null : syncStore.readRow(deviceId, db, table, key);
        if (row == null) {
            throw new ApiException(404, "记录不存在");
        }
        return Api.ok(row);
    }

    @PostMapping("/{db}/{table}")
    public Map<String, Object> create(@PathVariable String db, @PathVariable String table,
                                      @RequestBody(required = false) Map<String, Object> body,
                                      HttpServletRequest request) {
        requireTable(db, table);
        String deviceId = RequestDevice.deviceId(request, props);
        String pkCol = schema.primaryKey(db, table);
        Coerced coerced = coerce(db, table, body);
        Map<String, Object> row = coerced.row();

        if (!row.containsKey(pkCol) || row.get(pkCol) == null) {
            row.put(pkCol, syncStore.allocateWebId(deviceId, db, table));
        }
        for (SchemaCatalog.ColumnDef column : schema.tableDef(db, table).columns()) {
            if (column.hasDefault() || !column.isNotNull()) {
                continue;
            }
            if (row.containsKey(column.name())) {
                continue;
            }
            if (TIME_COLUMN.matcher(column.name()).find()) {
                row.put(column.name(), "INTEGER".equals(column.type())
                        ? SyncStore.now()
                        : ISO_MILLIS.format(Instant.now()));
            }
        }

        List<String> missing = syncStore.missingRequiredColumns(db, table, row);
        if (!missing.isEmpty()) {
            throw new ApiException(400,
                    "缺少必填列：" + String.join(", ", missing) + "（这些列没有默认值，必须提供）",
                    Map.of("missingColumns", missing));
        }

        Map<String, Object> result = syncStore.writeRow(deviceId, db, table, row, props.getWebDeviceId());
        Map<String, Object> out = new LinkedHashMap<>(result);
        out.put("row", syncStore.readRow(deviceId, db, table, result.get("pk")));
        out.put("unknownColumns", coerced.unknown());
        return Api.ok(out);
    }

    @PutMapping("/{db}/{table}/{pk}")
    public Map<String, Object> update(@PathVariable String db, @PathVariable String table,
                                      @PathVariable String pk,
                                      @RequestBody(required = false) Map<String, Object> body,
                                      HttpServletRequest request) {
        requireTable(db, table);
        String deviceId = RequestDevice.deviceId(request, props);
        String pkCol = schema.primaryKey(db, table);
        Long key = parseLong(pk);
        Map<String, Object> existing = key == null ? null : syncStore.readRow(deviceId, db, table, key);
        if (existing == null) {
            throw new ApiException(404, "记录不存在（如需新增请用 POST）");
        }

        Coerced coerced = coerce(db, table, body);
        Map<String, Object> row = coerced.row();
        row.remove(pkCol);
        Map<String, Object> merged = new LinkedHashMap<>(existing);
        merged.putAll(row);
        merged.put(pkCol, key);

        Map<String, Object> result = syncStore.writeRow(deviceId, db, table, merged, props.getWebDeviceId());
        Map<String, Object> out = new LinkedHashMap<>(result);
        out.put("row", syncStore.readRow(deviceId, db, table, result.get("pk")));
        out.put("unknownColumns", coerced.unknown());
        return Api.ok(out);
    }

    @DeleteMapping("/{db}/{table}/{pk}")
    public Map<String, Object> delete(@PathVariable String db, @PathVariable String table,
                                      @PathVariable String pk, HttpServletRequest request) {
        requireTable(db, table);
        String deviceId = RequestDevice.deviceId(request, props);
        Long key = parseLong(pk);
        if (key == null) {
            throw new ApiException(400, "主键不合法：" + pk);
        }
        return Api.ok(syncStore.removeRowCascade(deviceId, db, table, key, props.getWebDeviceId()));
    }

    // ───────────────────────────── 内部工具 ─────────────────────────────

    private void requireTable(String db, String table) {
        if (!schema.hasDatabase(db)) {
            throw new ApiException(404, "未知的数据库：" + db);
        }
        if (!schema.hasTable(db, table)) {
            throw new ApiException(404, "未知的表：" + db + "." + table);
        }
    }

    private record Coerced(Map<String, Object> row, List<String> unknown) {
    }

    /** 按列类型把请求体里的值转成合适类型，并拒绝未知列 */
    private Coerced coerce(String db, String table, Map<String, Object> body) {
        SchemaCatalog.TableDef def = schema.tableDef(db, table);
        Map<String, Object> out = new LinkedHashMap<>();
        List<String> unknown = new ArrayList<>();
        Map<String, Object> source = body == null ? Map.of() : body;

        for (Map.Entry<String, Object> entry : source.entrySet()) {
            String key = entry.getKey();
            SchemaCatalog.ColumnDef column = def.columns().stream()
                    .filter(c -> c.name().equals(key))
                    .findFirst().orElse(null);
            if (column == null) {
                unknown.add(key);
                continue;
            }
            Object raw = entry.getValue();
            if (raw == null) {
                out.put(key, null);
            } else if ("INTEGER".equals(column.type()) || "REAL".equals(column.type())) {
                Double number = toNumber(raw);
                if (number == null || !Double.isFinite(number)) {
                    out.put(key, null);
                } else if ("INTEGER".equals(column.type()) && number == Math.rint(number)) {
                    out.put(key, number.longValue());
                } else {
                    out.put(key, number);
                }
            } else {
                out.put(key, raw instanceof String ? raw : Json.write(raw));
            }
        }
        return new Coerced(out, unknown);
    }

    private Double toNumber(Object raw) {
        if (raw instanceof Number n) {
            return n.doubleValue();
        }
        if (raw instanceof Boolean b) {
            return b ? 1.0 : 0.0;
        }
        String text = String.valueOf(raw).trim();
        if (text.isEmpty()) {
            return 0.0;
        }
        try {
            return Double.parseDouble(text);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private Map<String, Object> truncateRow(Map<String, Object> row, int maxText) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<String, Object> entry : row.entrySet()) {
            Object value = entry.getValue();
            if (value instanceof String text && maxText >= 0 && text.length() > maxText) {
                out.put(entry.getKey(), text.substring(0, maxText)
                        + "…（共 " + text.length() + " 字，打开详情查看全文）");
            } else {
                out.put(entry.getKey(), value);
            }
        }
        return out;
    }

    private int parseInt(String value, int fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private Long parseLong(String value) {
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
