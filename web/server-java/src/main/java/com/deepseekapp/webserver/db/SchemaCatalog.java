package com.deepseekapp.webserver.db;

import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;

import java.io.InputStream;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * App 数据库结构定义（由 resources/schema.json 驱动）。
 *
 * <p>schema.json 是从原 Node 版 schema.js 一次性导出的，字段含义与 App 侧
 * database_helper.dart / novel_db_helper.dart 保持一致。以后改表结构时只需要
 * 改这份 JSON 并递增 appVersion。</p>
 */
@Component
public class SchemaCatalog {

    public record ColumnDef(
            String name,
            String type,
            Boolean pk,
            Boolean autoincrement,
            Boolean notNull,
            @JsonProperty("default") String defaultSql,
            Boolean unique,
            String ref,
            String onDelete,
            Boolean appMissingOnCreate) {

        public boolean isPk() {
            return Boolean.TRUE.equals(pk);
        }

        public boolean isAutoincrement() {
            return Boolean.TRUE.equals(autoincrement);
        }

        public boolean isNotNull() {
            return Boolean.TRUE.equals(notNull);
        }

        public boolean isUnique() {
            return Boolean.TRUE.equals(unique);
        }

        public boolean hasDefault() {
            return defaultSql != null;
        }

        public boolean isAppMissingOnCreate() {
            return Boolean.TRUE.equals(appMissingOnCreate);
        }
    }

    public record TableDef(
            String label,
            String module,
            Boolean singleton,
            List<String> sensitive,
            List<ColumnDef> columns,
            List<String> searchColumns,
            String orderBy,
            List<String> timeColumns,
            List<String> indexes) {

        public boolean isSingleton() {
            return Boolean.TRUE.equals(singleton);
        }

        public List<String> searchColumns() {
            return searchColumns == null ? List.of() : searchColumns;
        }

        public List<String> indexes() {
            return indexes == null ? List.of() : indexes;
        }

        public List<String> sensitive() {
            return sensitive == null ? List.of() : sensitive;
        }
    }

    public record DatabaseDef(
            String key,
            String file,
            int appVersion,
            String label,
            Map<String, TableDef> tables) {
    }

    public record ForeignKey(String table, String column, String targetTable, String targetColumn) {
    }

    private record Root(
            int appDbVersion,
            int novelDbVersion,
            long webIdBase,
            List<String> localOnlyTables,
            Map<String, DatabaseDef> databases) {
    }

    private final Root root;

    public SchemaCatalog(ObjectMapper mapper) {
        try (InputStream in = getClass().getResourceAsStream("/schema.json")) {
            if (in == null) {
                throw new IllegalStateException("找不到 resources/schema.json");
            }
            this.root = mapper.readValue(in, Root.class);
        } catch (Exception e) {
            throw new IllegalStateException("加载 schema.json 失败", e);
        }
    }

    public int appDbVersion() {
        return root.appDbVersion();
    }

    public int novelDbVersion() {
        return root.novelDbVersion();
    }

    public long webIdBase() {
        return root.webIdBase();
    }

    public List<String> localOnlyTables() {
        return root.localOnlyTables() == null ? List.of() : root.localOnlyTables();
    }

    public Map<String, DatabaseDef> databases() {
        return Collections.unmodifiableMap(root.databases());
    }

    public DatabaseDef database(String dbKey) {
        return root.databases().get(dbKey);
    }

    public boolean hasDatabase(String dbKey) {
        return dbKey != null && root.databases().containsKey(dbKey);
    }

    public boolean hasTable(String dbKey, String tableName) {
        DatabaseDef db = database(dbKey);
        return db != null && tableName != null && db.tables().containsKey(tableName);
    }

    public TableDef tableDef(String dbKey, String tableName) {
        DatabaseDef db = database(dbKey);
        if (db == null) {
            throw new IllegalArgumentException("未知的数据库：" + dbKey);
        }
        TableDef def = db.tables().get(tableName);
        if (def == null) {
            throw new IllegalArgumentException("未知的表：" + dbKey + "." + tableName);
        }
        return def;
    }

    public List<String> columnNames(String dbKey, String tableName) {
        return tableDef(dbKey, tableName).columns().stream().map(ColumnDef::name).toList();
    }

    public String primaryKey(String dbKey, String tableName) {
        return tableDef(dbKey, tableName).columns().stream()
                .filter(ColumnDef::isPk)
                .map(ColumnDef::name)
                .findFirst()
                .orElseThrow(() -> new IllegalStateException("表 " + dbKey + "." + tableName + " 未定义主键"));
    }

    /** 由列定义生成 CREATE TABLE 语句，结果与 App 侧 DDL 等价 */
    public String toDDL(String dbKey, String tableName) {
        TableDef def = tableDef(dbKey, tableName);
        List<String> lines = new ArrayList<>();
        for (ColumnDef c : def.columns()) {
            StringBuilder s = new StringBuilder("  " + c.name() + " " + c.type());
            if (c.isPk()) {
                s.append(" PRIMARY KEY");
            }
            if (c.isAutoincrement()) {
                s.append(" AUTOINCREMENT");
            }
            if (c.isNotNull()) {
                s.append(" NOT NULL");
            }
            if (c.hasDefault()) {
                s.append(" DEFAULT ").append(c.defaultSql());
            }
            if (c.isUnique()) {
                s.append(" UNIQUE");
            }
            lines.add(s.toString());
        }
        for (ColumnDef c : def.columns()) {
            if (c.ref() == null) {
                continue;
            }
            String target = c.ref().split("\\.")[0];
            String onDelete = c.onDelete() == null ? "" : " ON DELETE " + c.onDelete();
            lines.add("  FOREIGN KEY (" + c.name() + ") REFERENCES " + target + "(id)" + onDelete);
        }
        return "CREATE TABLE IF NOT EXISTS " + tableName + " (\n" + String.join(",\n", lines) + "\n)";
    }

    public void createAllTables(Connection connection, String dbKey) {
        DatabaseDef db = database(dbKey);
        if (db == null) {
            throw new IllegalArgumentException("未知的数据库：" + dbKey);
        }
        try (Statement st = connection.createStatement()) {
            for (Map.Entry<String, TableDef> entry : db.tables().entrySet()) {
                st.execute(toDDL(dbKey, entry.getKey()));
                for (String index : entry.getValue().indexes()) {
                    st.execute(index);
                }
            }
            st.execute("PRAGMA user_version = " + db.appVersion());
        } catch (SQLException e) {
            throw new RuntimeException("创建 " + dbKey + " 表结构失败", e);
        }
    }

    /** 表目录：前端据此自动渲染通用表浏览器 */
    public List<Map<String, Object>> tableCatalog(String dbKey) {
        DatabaseDef db = database(dbKey);
        if (db == null) {
            throw new ApiException(404, "未知的数据库：" + dbKey);
        }
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map.Entry<String, TableDef> entry : db.tables().entrySet()) {
            String name = entry.getKey();
            TableDef def = entry.getValue();
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("db", dbKey);
            item.put("name", name);
            item.put("label", def.label());
            item.put("module", def.module());
            item.put("singleton", def.isSingleton());
            List<Map<String, Object>> columns = new ArrayList<>();
            for (ColumnDef c : def.columns()) {
                Map<String, Object> col = new LinkedHashMap<>();
                col.put("name", c.name());
                col.put("type", c.type());
                col.put("pk", c.isPk());
                col.put("notNull", c.isNotNull());
                col.put("hasDefault", c.hasDefault());
                col.put("autoIncrement", c.isAutoincrement());
                col.put("ref", c.ref());
                col.put("appMissingOnCreate", c.isAppMissingOnCreate());
                columns.add(col);
            }
            item.put("columns", columns);
            item.put("searchColumns", def.searchColumns());
            out.add(item);
        }
        return out;
    }

    /** 一个库中所有外键关系，导入时用于按依赖顺序处理 */
    public List<ForeignKey> foreignKeys(String dbKey) {
        DatabaseDef db = database(dbKey);
        if (db == null) {
            throw new ApiException(404, "未知的数据库：" + dbKey);
        }
        List<ForeignKey> out = new ArrayList<>();
        for (Map.Entry<String, TableDef> entry : db.tables().entrySet()) {
            for (ColumnDef c : entry.getValue().columns()) {
                if (c.ref() != null) {
                    String[] parts = c.ref().split("\\.");
                    out.add(new ForeignKey(entry.getKey(), c.name(), parts[0], parts.length > 1 ? parts[1] : "id"));
                }
            }
        }
        return out;
    }
}
