package com.deepseekapp.webserver.db;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 启动时按 schema.json 在 MySQL 中建表。
 *
 * <p>与原 SQLite 版的差异：</p>
 * <ul>
 *   <li>单库多设备：每张业务表额外增加 {@code device_id}，主键改为自增代理键 {@code _row_id}，
 *       原来的业务主键降级为 {@code (device_id, pk)} 唯一索引，保证不同设备可以有相同 id。</li>
 *   <li>MySQL 不支持 TEXT 列默认值，文本列统一可空；整数/浮点保留 NOT NULL + 默认 0。</li>
 *   <li>不建外键约束：同步层已经有级联删除与父记录校验，避免跨设备误伤。</li>
 * </ul>
 */
@Component
@Order(1)
public class MySqlSchemaInitializer implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(MySqlSchemaInitializer.class);

    /** schema.json 里的 indexes 是 SQLite 的 CREATE INDEX 语句，需要提取索引名与列。 */
    private static final java.util.regex.Pattern INDEX_PATTERN = java.util.regex.Pattern.compile(
            "(?i)CREATE\\s+(UNIQUE\\s+)?INDEX\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?[`\"]?([A-Za-z0-9_]+)[`\"]?\\s+" +
                    "ON\\s+[`\"]?[A-Za-z0-9_]+[`\"]?\\s*\\(([^)]*)\\)");

    private final DataSource dataSource;
    private final SchemaCatalog schema;

    public MySqlSchemaInitializer(DataSource dataSource, SchemaCatalog schema) {
        this.dataSource = dataSource;
        this.schema = schema;
    }

    @Override
    public void run(ApplicationArguments args) {
        init();
    }

    public void init() {
        try (Connection connection = dataSource.getConnection()) {
            ensureSyncTables(connection);
            for (Map.Entry<String, SchemaCatalog.DatabaseDef> db : schema.databases().entrySet()) {
                for (Map.Entry<String, SchemaCatalog.TableDef> table : db.getValue().tables().entrySet()) {
                    ensureBusinessTable(connection, table.getKey(), table.getValue());
                    ensureDeviceColumn(connection, table.getKey());
                }
            }
            log.info("MySQL 表结构检查完成：{} 个库，{} 张业务表",
                    schema.databases().size(),
                    schema.databases().values().stream().mapToInt(d -> d.tables().size()).sum());
        } catch (SQLException e) {
            throw new IllegalStateException("初始化 MySQL 表结构失败：" + e.getMessage(), e);
        }
    }

    // ───────────────────────────── 业务表 ─────────────────────────────

    private void ensureBusinessTable(Connection connection, String table, SchemaCatalog.TableDef def)
            throws SQLException {
        List<String> parts = new ArrayList<>();
        parts.add("`_row_id` BIGINT NOT NULL AUTO_INCREMENT");
        parts.add("`device_id` VARCHAR(64) NOT NULL DEFAULT ''");

        Set<String> pkColumns = new LinkedHashSet<>();
        for (SchemaCatalog.ColumnDef column : def.columns()) {
            parts.add("`" + column.name() + "` " + columnType(column));
            if (column.isPk()) {
                pkColumns.add(column.name());
            }
        }
        parts.add("PRIMARY KEY (`_row_id`)");

        if (!pkColumns.isEmpty()) {
            List<String> keys = new ArrayList<>();
            keys.add("`device_id`");
            for (String pk : pkColumns) {
                keys.add(indexPart(def, pk));
            }
            parts.add("UNIQUE KEY `uk_" + shortName(table, "device_pk") + "` (" + String.join(", ", keys) + ")");
        }
        parts.add("KEY `idx_" + shortName(table, "device") + "` (`device_id`)");

        int index = 0;
        for (String declared : def.indexes() == null ? List.<String>of() : def.indexes()) {
            String create = declared == null ? "" : declared.trim();
            if (create.isEmpty()) {
                continue;
            }
            java.util.regex.Matcher matcher = INDEX_PATTERN.matcher(create);
            if (matcher.find()) {
                String columns = matcher.group(3).trim();
                // SQLite 的部分索引（带 WHERE）在 MySQL 不支持，直接跳过
                if (columns.isEmpty() || create.toUpperCase().contains(" WHERE ")) {
                    continue;
                }
                String name = truncate(matcher.group(2), 60);
                parts.add((matcher.group(1) != null ? "UNIQUE KEY `" : "KEY `") + name + "` (" + columns + ")");
            } else if (!create.toUpperCase().startsWith("CREATE ")) {
                // 兼容「索引就是列名」的写法
                index++;
                parts.add("KEY `" + truncate("idx_" + table + "_" + index, 60) + "` (" + create + ")");
            }
        }

        String sql = "CREATE TABLE IF NOT EXISTS `" + table + "` (\n  "
                + String.join(",\n  ", parts)
                + "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci";
        execute(connection, sql);
    }

    /** 老库升级：补上 device_id 列。 */
    private void ensureDeviceColumn(Connection connection, String table) throws SQLException {
        if (columnExists(connection, table, "device_id")) {
            return;
        }
        execute(connection, "ALTER TABLE `" + table + "` ADD COLUMN `device_id` VARCHAR(64) NOT NULL DEFAULT ''");
    }

    private String columnType(SchemaCatalog.ColumnDef column) {
        String type = column.type() == null ? "TEXT" : column.type().toUpperCase();
        boolean text = !type.startsWith("INT") && !type.startsWith("REAL") && !type.startsWith("DOUBLE")
                && !type.startsWith("FLOAT") && !type.startsWith("NUMERIC") && !type.startsWith("BLOB");
        if (text) {
            // MySQL 的 TEXT/LONGTEXT 不支持字面量默认值，统一可空，非空由业务层校验
            return "BLOB".equals(type) ? "LONGBLOB NULL" : "LONGTEXT NULL";
        }
        String base = switch (type) {
            case "BLOB" -> "LONGBLOB";
            case "REAL", "DOUBLE", "FLOAT", "NUMERIC" -> "DOUBLE";
            default -> "BIGINT";
        };
        return base + (column.isNotNull() || column.isPk() ? " NOT NULL DEFAULT 0" : " NULL");
    }

    /** TEXT 主键需要前缀长度才能建唯一索引。 */
    private String indexPart(SchemaCatalog.TableDef def, String columnName) {
        for (SchemaCatalog.ColumnDef column : def.columns()) {
            if (column.name().equals(columnName)) {
                String type = column.type() == null ? "TEXT" : column.type().toUpperCase();
                if (type.startsWith("TEXT") || type.startsWith("VARCHAR") || type.startsWith("CHAR")) {
                    return "`" + columnName + "`(191)";
                }
            }
        }
        return "`" + columnName + "`";
    }

    // ───────────────────────────── 同步元数据表 ─────────────────────────────

    private void ensureSyncTables(Connection connection) throws SQLException {
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `devices` (
                  `device_id` VARCHAR(64) NOT NULL,
                  `name` VARCHAR(191) NOT NULL DEFAULT '',
                  `platform` VARCHAR(64) NOT NULL DEFAULT '',
                  `id_base` BIGINT NOT NULL DEFAULT 0,
                  `scope_dir` VARCHAR(255) NOT NULL DEFAULT '',
                  `last_seen_at` BIGINT NOT NULL DEFAULT 0,
                  `created_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`device_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `device_cursors` (
                  `device_id` VARCHAR(64) NOT NULL,
                  `last_pull_seq` BIGINT NOT NULL DEFAULT 0,
                  `last_push_at` BIGINT NULL,
                  `last_pull_at` BIGINT NULL,
                  PRIMARY KEY (`device_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `conflicts` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `device_id` VARCHAR(64) NOT NULL DEFAULT '',
                  `db` VARCHAR(32) NOT NULL DEFAULT '',
                  `table_name` VARCHAR(64) NOT NULL DEFAULT '',
                  `pk` BIGINT NOT NULL DEFAULT 0,
                  `incoming_rev` BIGINT NOT NULL DEFAULT 0,
                  `server_rev` BIGINT NOT NULL DEFAULT 0,
                  `incoming_device` VARCHAR(64) NOT NULL DEFAULT '',
                  `detected_at` BIGINT NOT NULL DEFAULT 0,
                  `resolution` VARCHAR(32) NOT NULL DEFAULT '',
                  `detail` LONGTEXT NULL,
                  PRIMARY KEY (`id`),
                  KEY `idx_conflicts_device` (`device_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `row_meta` (
                  `device_id` VARCHAR(64) NOT NULL,
                  `db` VARCHAR(32) NOT NULL,
                  `table_name` VARCHAR(64) NOT NULL,
                  `pk` BIGINT NOT NULL,
                  `rev` BIGINT NOT NULL DEFAULT 0,
                  `origin_device` VARCHAR(64) NOT NULL DEFAULT '',
                  `updated_at` BIGINT NOT NULL DEFAULT 0,
                  `deleted` INT NOT NULL DEFAULT 0,
                  `content_hash` VARCHAR(64) NOT NULL DEFAULT '',
                  PRIMARY KEY (`device_id`, `db`, `table_name`, `pk`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `change_log` (
                  `seq` BIGINT NOT NULL AUTO_INCREMENT,
                  `device_id` VARCHAR(64) NOT NULL,
                  `db` VARCHAR(32) NOT NULL DEFAULT '',
                  `table_name` VARCHAR(64) NOT NULL DEFAULT '',
                  `pk` BIGINT NOT NULL DEFAULT 0,
                  `op` VARCHAR(16) NOT NULL DEFAULT '',
                  `rev` BIGINT NOT NULL DEFAULT 0,
                  `origin_device` VARCHAR(64) NOT NULL DEFAULT '',
                  `server_time` BIGINT NOT NULL DEFAULT 0,
                  `payload` LONGTEXT NULL,
                  PRIMARY KEY (`seq`),
                  KEY `idx_change_device_seq` (`device_id`, `seq`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `sync_requests` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `target_device` VARCHAR(64) NOT NULL DEFAULT '',
                  `requested_by` VARCHAR(64) NOT NULL DEFAULT '',
                  `requested_at` BIGINT NOT NULL DEFAULT 0,
                  `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
                  `claimed_at` BIGINT NULL,
                  `finished_at` BIGINT NULL,
                  `result` LONGTEXT NULL,
                  PRIMARY KEY (`id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `sync_progress` (
                  `request_id` BIGINT NOT NULL,
                  `message` VARCHAR(255) NOT NULL DEFAULT '',
                  `current` BIGINT NULL,
                  `total` BIGINT NULL,
                  `updated_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`request_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `app_meta` (
                  `k` VARCHAR(64) NOT NULL,
                  `v` VARCHAR(255) NOT NULL DEFAULT '',
                  PRIMARY KEY (`k`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        ensureAgentTables(connection);
    }

    /** 右侧 Agent 面板：会话、消息、设置、任务计划。 */
    private void ensureAgentTables(Connection connection) throws SQLException {
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `agent_sessions` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `device_id` VARCHAR(64) NOT NULL DEFAULT '',
                  `title` VARCHAR(191) NOT NULL DEFAULT '',
                  `message_count` INT NOT NULL DEFAULT 0,
                  `created_at` BIGINT NOT NULL DEFAULT 0,
                  `updated_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`id`),
                  KEY `idx_agent_sessions_device` (`device_id`, `updated_at`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `agent_messages` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `session_id` BIGINT NOT NULL DEFAULT 0,
                  `device_id` VARCHAR(64) NOT NULL DEFAULT '',
                  `role` VARCHAR(16) NOT NULL DEFAULT 'user',
                  `content` LONGTEXT NULL,
                  `parts` LONGTEXT NULL,
                  `status` VARCHAR(16) NOT NULL DEFAULT 'done',
                  `error` VARCHAR(500) NULL,
                  `elapsed_ms` BIGINT NULL,
                  `created_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`id`),
                  KEY `idx_agent_messages_session` (`session_id`, `id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `agent_settings` (
                  `device_id` VARCHAR(64) NOT NULL,
                  `api_key` VARCHAR(255) NOT NULL DEFAULT '',
                  `base_url` VARCHAR(255) NOT NULL DEFAULT '',
                  `model` VARCHAR(64) NOT NULL DEFAULT '',
                  `temperature` DOUBLE NULL,
                  `max_tokens` INT NULL,
                  `top_p` DOUBLE NULL,
                  `frequency_penalty` DOUBLE NULL,
                  `presence_penalty` DOUBLE NULL,
                  `system_prompt` LONGTEXT NULL,
                  `web_search` TINYINT NOT NULL DEFAULT 0,
                  `search_count` INT NOT NULL DEFAULT 5,
                  `search_need_content` TINYINT NOT NULL DEFAULT 0,
                  `updated_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`device_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
        ensureColumn(connection, "agent_settings", "web_search", "TINYINT NOT NULL DEFAULT 0");
        ensureColumn(connection, "agent_settings", "search_count", "INT NOT NULL DEFAULT 5");
        ensureColumn(connection, "agent_settings", "search_need_content", "TINYINT NOT NULL DEFAULT 0");
        execute(connection, """
                CREATE TABLE IF NOT EXISTS `agent_tasks` (
                  `id` BIGINT NOT NULL AUTO_INCREMENT,
                  `session_id` BIGINT NOT NULL DEFAULT 0,
                  `device_id` VARCHAR(64) NOT NULL DEFAULT '',
                  `run_id` VARCHAR(64) NOT NULL DEFAULT '',
                  `title` VARCHAR(191) NOT NULL DEFAULT '',
                  `steps` LONGTEXT NULL,
                  `status` VARCHAR(16) NOT NULL DEFAULT 'running',
                  `created_at` BIGINT NOT NULL DEFAULT 0,
                  `updated_at` BIGINT NOT NULL DEFAULT 0,
                  PRIMARY KEY (`id`),
                  KEY `idx_agent_tasks_session` (`session_id`, `id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """);
    }

    // ───────────────────────────── 工具 ─────────────────────────────

    private boolean columnExists(Connection connection, String table, String column) throws SQLException {
        String sql = "SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() " +
                "AND table_name = ? AND column_name = ?";
        try (var ps = connection.prepareStatement(sql)) {
            ps.setString(1, table);
            ps.setString(2, column);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    private void ensureColumn(Connection connection, String table, String column, String definition)
            throws SQLException {
        if (!columnExists(connection, table, column)) {
            execute(connection, "ALTER TABLE `" + table + "` ADD COLUMN `" + column + "` " + definition);
        }
    }

    private void execute(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private static String shortName(String table, String suffix) {
        String name = table + "_" + suffix;
        return name.length() <= 60 ? name : name.substring(0, 60);
    }

    private static String truncate(String value, int max) {
        return value.length() <= max ? value : value.substring(0, max);
    }
}
