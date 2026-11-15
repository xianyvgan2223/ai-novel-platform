package com.deepseekapp.webserver.feature.data.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

/**
 * 一次性迁移：把 data/devices 下的旧 SQLite 数据导入 MySQL。
 *
 * <p>执行顺序在 {@link com.deepseekapp.webserver.db.MySqlSchemaInitializer} 之后；
 * 完成后往 {@code app_meta} 写标记，后续启动不再重复执行。中途失败不会写标记，
 * 下次启动会重试（导入用 merge 模式，重复写入的行会被识别为 unchanged）。</p>
 */
@Component
@Order(2)
public class SqliteMigrationRunner implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(SqliteMigrationRunner.class);
    private static final String FLAG_KEY = "sqlite_migrated";

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final Importer importer;
    private final AppProperties props;

    public SqliteMigrationRunner(DatabaseManager databaseManager, SchemaCatalog schema,
                                 Importer importer, AppProperties props) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.importer = importer;
        this.props = props;
    }

    @Override
    public void run(ApplicationArguments args) {
        if (!props.isMigrateSqlite() || isDone()) {
            return;
        }
        try {
            migrateDevicesMetadata();
            int files = migrateDeviceFiles();
            markDone();
            log.info("旧 SQLite 数据迁移完成，共导入 {} 个库文件", files);
        } catch (Exception e) {
            log.warn("旧 SQLite 数据迁移未完成，下次启动会重试：{}", e.getMessage());
        }
    }

    /** 旧全局 sync.db 里的设备清单要搬到 MySQL，否则前端设备下拉框是空的。 */
    private void migrateDevicesMetadata() {
        Path globalSync = props.dataDirPath().resolve("sync.db");
        if (!Files.isRegularFile(globalSync)) {
            return;
        }
        try (Connection source = databaseManager.openExternal(globalSync, true)) {
            List<Map<String, Object>> devices = Db.query(source, "SELECT * FROM devices");
            if (devices.isEmpty()) {
                return;
            }
            databaseManager.meta(target -> {
                for (Map<String, Object> row : devices) {
                    Db.update(target,
                            "INSERT INTO devices (device_id, name, platform, id_base, scope_dir, last_seen_at, created_at) " +
                                    "VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE " +
                                    "name = VALUES(name), platform = VALUES(platform), id_base = VALUES(id_base), " +
                                    "scope_dir = VALUES(scope_dir), last_seen_at = VALUES(last_seen_at)",
                            row.get("device_id"),
                            value(row.get("name")),
                            value(row.get("platform")),
                            DbNumber.of(row.get("id_base")),
                            value(row.get("scope_dir")),
                            DbNumber.of(row.get("last_seen_at")),
                            DbNumber.of(row.get("created_at")));
                }
                return null;
            });
            log.info("已迁移 {} 条设备登记", devices.size());
        } catch (Exception e) {
            log.warn("迁移设备登记失败：{}", e.getMessage());
        }
    }

    private int migrateDeviceFiles() throws Exception {
        Path root = databaseManager.devicesRootDir();
        if (!Files.isDirectory(root)) {
            return 0;
        }
        Map<String, String> dirToDevice = deviceMapping();
        int count = 0;
        List<Path> dirs;
        try (Stream<Path> stream = Files.list(root)) {
            dirs = stream.filter(Files::isDirectory).sorted().toList();
        }
        for (Path dir : dirs) {
            String dirName = dir.getFileName().toString();
            String deviceId = dirToDevice.getOrDefault(dirName, dirName);
            for (Map.Entry<String, SchemaCatalog.DatabaseDef> entry : schema.databases().entrySet()) {
                Path file = dir.resolve(entry.getValue().file());
                if (!Files.isRegularFile(file)) {
                    continue;
                }
                // merge 模式：不删除 MySQL 已有数据，重复导入时未变化的行会被跳过
                importer.importAppDatabase(entry.getKey(), Files.readAllBytes(file), "merge", deviceId, deviceId);
                count++;
                log.info("已导入 {}（设备 {}，库 {}）", file.getFileName(), deviceId, entry.getKey());
            }
        }
        return count;
    }

    private Map<String, String> deviceMapping() {
        Map<String, String> out = new HashMap<>();
        try {
            databaseManager.meta(connection -> {
                for (Map<String, Object> row : Db.query(connection,
                        "SELECT device_id, scope_dir FROM devices")) {
                    String scopeDir = value(row.get("scope_dir"));
                    String deviceId = value(row.get("device_id"));
                    if (!scopeDir.isBlank()) {
                        String name = Path.of(scopeDir).getFileName().toString();
                        out.put(name, deviceId);
                    }
                    out.putIfAbsent(databaseManager.sanitizeDeviceId(deviceId), deviceId);
                }
                return null;
            });
        } catch (Exception e) {
            log.warn("读取设备目录映射失败：{}", e.getMessage());
        }
        return out;
    }

    private boolean isDone() {
        try {
            return databaseManager.meta(connection -> Db.queryOne(connection,
                    "SELECT v FROM app_meta WHERE k = ?", FLAG_KEY) != null);
        } catch (Exception e) {
            return false;
        }
    }

    private void markDone() {
        databaseManager.meta(connection -> {
            Db.update(connection,
                    "INSERT INTO app_meta (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)",
                    FLAG_KEY, String.valueOf(System.currentTimeMillis()));
            return null;
        });
    }

    private static String value(Object raw) {
        return raw == null ? "" : String.valueOf(raw);
    }

    private static final class DbNumber {
        private static long of(Object raw) {
            if (raw instanceof Number number) {
                return number.longValue();
            }
            try {
                return Long.parseLong(String.valueOf(raw));
            } catch (Exception e) {
                return 0L;
            }
        }
    }
}
