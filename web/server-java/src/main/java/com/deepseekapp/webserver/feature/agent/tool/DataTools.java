package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.feature.agent.service.AgentRun;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 数据类工具：概览、分页查表、单条详情。全部只读。 */
@Component
public class DataTools {

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final AgentToolSupport support;

    public DataTools(DatabaseManager databaseManager, SchemaCatalog schema, AgentToolSupport support) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.support = support;
    }

    @Tool(name = "get_overview",
            description = "查看当前设备的数据概览：每个数据库里各表的行数。用户问「有哪些数据」「库里有什么」时先调用。")
    public Map<String, Object> getOverview(ToolContext context) {
        AgentRun run = support.runOf(context);
        return support.traced(run, "get_overview", Map.of(), () -> {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("deviceId", run == null ? "" : run.deviceId());
            if (run != null && !databaseManager.deviceScopeExists(run.deviceId())) {
                out.put("databases", List.of());
                out.put("note", "该设备还没有向服务端同步过数据");
                return out;
            }
            List<Map<String, Object>> databases = new ArrayList<>();
            for (String dbKey : schema.databases().keySet()) {
                databases.add(overviewOf(run, dbKey));
            }
            out.put("databases", databases);
            return out;
        });
    }

    private Map<String, Object> overviewOf(AgentRun run, String dbKey) {
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("db", dbKey);
        info.put("tables", List.of());
        if (run == null) {
            return info;
        }
        try {
            return databaseManager.app(run.deviceId(), dbKey, connection -> {
                List<Map<String, Object>> tables = new ArrayList<>();
                SchemaCatalog.DatabaseDef database = schema.database(dbKey);
                for (String table : database == null ? java.util.Set.<String>of() : database.tables().keySet()) {
                    run.checkCancelled();
                    try {
                        Map<String, Object> countRow = Db.queryOne(connection,
                                "SELECT COUNT(*) AS c FROM `" + table + "` WHERE device_id = ?", run.deviceId());
                        long count = AgentToolSupport.number(countRow == null ? null : countRow.get("c"));
                        Map<String, Object> item = new LinkedHashMap<>();
                        item.put("table", table);
                        item.put("rows", count);
                        tables.add(item);
                    } catch (RuntimeException e) {
                        // 表还没建（新建库或结构升级中）时跳过，不让整个概览失败
                    }
                }
                info.put("tables", tables);
                return info;
            });
        } catch (RuntimeException e) {
            info.put("error", AgentToolSupport.message(e));
            return info;
        }
    }

    @Tool(name = "list_data",
            description = "分页查看某张表的数据。db 取 deepseek 或 novel，table 为表名；可传 keyword 做模糊搜索。每页最多 50 行。")
    public Map<String, Object> listData(
            @ToolParam(description = "数据库键：deepseek 或 novel") String db,
            @ToolParam(description = "表名，例如 chat_sessions、outline_settings、outline_chapters") String table,
            @ToolParam(description = "页码，从 1 开始，默认 1", required = false) Integer page,
            @ToolParam(description = "每页行数，默认 20，最大 50", required = false) Integer pageSize,
            @ToolParam(description = "可选关键字，按该表的可搜索列做 LIKE 匹配", required = false) String keyword,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("db", db);
        args.put("table", table);
        args.put("page", page);
        args.put("pageSize", pageSize);
        args.put("keyword", keyword);
        return support.traced(run, "list_data", args, () -> {
            support.requireRun(run);
            support.requireTable(db, table);
            int current = Math.max(1, page == null ? 1 : page);
            int size = AgentToolSupport.clamp(pageSize == null ? 20 : pageSize, 1, AgentToolSupport.MAX_PAGE_SIZE);
            String pk = schema.primaryKey(db, table);
            List<String> searchColumns = schema.tableDef(db, table).searchColumns();

            StringBuilder where = new StringBuilder(" WHERE device_id = ?");
            List<Object> whereArgs = new ArrayList<>();
            whereArgs.add(run.deviceId());
            if (keyword != null && !keyword.isBlank() && !searchColumns.isEmpty()) {
                List<String> parts = new ArrayList<>();
                for (String column : searchColumns) {
                    parts.add("`" + column + "` LIKE ?");
                    whereArgs.add("%" + keyword.trim() + "%");
                }
                where.append(" AND (").append(String.join(" OR ", parts)).append(')');
            }
            String order = pk == null || pk.isBlank() ? "" : " ORDER BY `" + pk + "` DESC";

            List<Object> rowArgs = new ArrayList<>(whereArgs);
            rowArgs.add(size);
            rowArgs.add((long) (current - 1) * size);

            List<String> quotedColumns = new ArrayList<>();
            for (String column : schema.columnNames(db, table)) {
                quotedColumns.add("`" + column + "`");
            }
            String columnList = String.join(", ", quotedColumns);

            return databaseManager.app(run.deviceId(), db, connection -> {
                Map<String, Object> countRow = Db.queryOne(connection,
                        "SELECT COUNT(*) AS c FROM `" + table + "`" + where, whereArgs.toArray());
                long total = AgentToolSupport.number(countRow == null ? null : countRow.get("c"));
                List<Map<String, Object>> rows = Db.query(connection,
                        "SELECT " + columnList + " FROM `" + table + "`" + where + order + " LIMIT ? OFFSET ?",
                        rowArgs.toArray());

                Map<String, Object> out = new LinkedHashMap<>();
                out.put("db", db);
                out.put("table", table);
                out.put("page", current);
                out.put("pageSize", size);
                out.put("total", total);
                out.put("columns", schema.columnNames(db, table));
                out.put("rows", AgentToolSupport.trimRows(rows));
                return out;
            });
        });
    }

    @Tool(name = "get_row",
            description = "按主键查看某张表的一条完整记录。适合在 list_data 之后展开细节。")
    public Map<String, Object> getRow(
            @ToolParam(description = "数据库键：deepseek 或 novel") String db,
            @ToolParam(description = "表名") String table,
            @ToolParam(description = "主键 id") Long id,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("db", db);
        args.put("table", table);
        args.put("id", id);
        return support.traced(run, "get_row", args, () -> {
            support.requireRun(run);
            support.requireTable(db, table);
            String pk = schema.primaryKey(db, table);
            if (pk == null || pk.isBlank()) {
                throw new ApiException(400, "该表没有主键，请用 list_data 查看");
            }
            return databaseManager.app(run.deviceId(), db, connection -> {
                Map<String, Object> row = Db.queryOne(connection,
                        "SELECT * FROM `" + table + "` WHERE device_id = ? AND `" + pk + "` = ? LIMIT 1",
                        run.deviceId(), id);
                if (row == null) {
                    throw new ApiException(404, "没有找到 id=" + id + " 的记录");
                }
                row.remove("_row_id");
                row.remove("device_id");
                return AgentToolSupport.trimRows(List.of(row)).getFirst();
            });
        });
    }
}
