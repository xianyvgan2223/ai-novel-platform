package com.deepseekapp.webserver.db;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.mapper.DeviceEntity;
import com.deepseekapp.webserver.db.mapper.DeviceMapper;
import com.deepseekapp.webserver.web.ApiException;
import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.sqlite.SQLiteConfig;

import javax.sql.DataSource;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;
import java.util.stream.Stream;

/**
 * 数据访问入口：MySQL 单库 + device_id 多设备隔离。
 *
 * <p>与原 SQLite 版保持相同的方法签名，调用方（DataController / SyncStore / Agent 工具）
 * 只需要在 SQL 里补 {@code device_id} 条件即可。</p>
 *
 * <p>并发策略保持不变：进程内用一把公平锁串行化数据库操作。这个服务是本地单机/局域网使用，
 * 并发极低；串行化可以避免同一连接被多个请求线程复用，也让「读-改-写」的同步逻辑保持简单。
 * 同一线程内的嵌套调用复用同一个连接（ThreadLocal），避免连接池被递归占满。</p>
 */
@Component
public class DatabaseManager {

    private static final Logger log = LoggerFactory.getLogger(DatabaseManager.class);

    @FunctionalInterface
    public interface SqlFunction<T> {
        T apply(Connection connection) throws Exception;
    }

    @FunctionalInterface
    public interface ScopeFunction<T> {
        T apply(DeviceScope scope) throws Exception;
    }

    @FunctionalInterface
    public interface ThrowingSupplier<T> {
        T get() throws Exception;
    }

    /** 单库之后，一个 scope 只有一条连接；保留原类型是为了不改同步层调用方式。 */
    public static final class DeviceScope {
        public final String deviceId;
        private final Connection connection;

        DeviceScope(String deviceId, Connection connection) {
            this.deviceId = deviceId;
            this.connection = connection;
        }

        public Connection db(String dbKey) {
            return connection;
        }
    }

    public record LegacyFile(String file, long bytes) {
    }

    private final DataSource dataSource;
    private final SchemaCatalog schema;
    private final AppProperties props;
    private final DeviceMapper deviceMapper;
    private final ReentrantLock lock = new ReentrantLock(true);
    private final ThreadLocal<Connection> current = new ThreadLocal<>();

    public DatabaseManager(DataSource dataSource, SchemaCatalog schema, AppProperties props,
                           DeviceMapper deviceMapper) {
        this.dataSource = dataSource;
        this.schema = schema;
        this.props = props;
        this.deviceMapper = deviceMapper;
    }

    public void init() {
        try (Connection connection = dataSource.getConnection()) {
            log.info("MySQL 连接正常：{}", connection.getMetaData().getURL());
        } catch (SQLException e) {
            throw new IllegalStateException("无法连接 MySQL：" + e.getMessage(), e);
        }
    }

    public void closeAll() {
        current.remove();
    }

    // ───────────────────────────── 连接与作用域 ─────────────────────────────

    private <T> T withConnection(SqlFunction<T> action) {
        Connection existing = current.get();
        if (existing != null) {
            return call(() -> action.apply(existing));
        }
        lock.lock();
        try (Connection connection = dataSource.getConnection()) {
            current.set(connection);
            try {
                return call(() -> action.apply(connection));
            } finally {
                current.remove();
            }
        } catch (SQLException e) {
            throw new RuntimeException("获取数据库连接失败：" + e.getMessage(), e);
        } finally {
            lock.unlock();
        }
    }

    /** 全局元数据（设备、同步请求、冲突）。 */
    public <T> T meta(SqlFunction<T> action) {
        return withConnection(action);
    }

    public <T> T scope(String deviceId, ScopeFunction<T> action) {
        String id = String.valueOf(deviceId);
        return withConnection(connection -> action.apply(new DeviceScope(id, connection)));
    }

    public <T> T app(String deviceId, String dbKey, SqlFunction<T> action) {
        if (!schema.hasDatabase(dbKey)) {
            throw new ApiException(404, "未知的数据库：" + dbKey);
        }
        return scope(deviceId, deviceScope -> action.apply(deviceScope.db(dbKey)));
    }

    /** 设备级同步元数据（row_meta / change_log），单库后与业务表共用一条连接。 */
    public <T> T scopeMeta(String deviceId, SqlFunction<T> action) {
        return scope(deviceId, deviceScope -> action.apply(deviceScope.db("")));
    }

    public Connection scopeMetaConnection(DeviceScope scope) {
        return scope.db("");
    }

    public <T> T locked(ThrowingSupplier<T> action) {
        return withConnection(connection -> action.get());
    }

    public SchemaCatalog schema() {
        return schema;
    }

    // ───────────────────────────── 设备 ─────────────────────────────

    public boolean deviceScopeExists(String deviceId) {
        if (deviceId == null || deviceId.isBlank()) {
            return false;
        }
        String id = String.valueOf(deviceId);
        return meta(connection -> {
            if (Db.queryOne(connection, "SELECT 1 AS x FROM devices WHERE device_id = ?", id) != null) {
                return true;
            }
            // 兼容旧数据目录：还没登记但已经有 .db 文件时也算存在
            return Files.exists(scopeDirOf(id));
        });
    }

    public List<String> knownDeviceIds() {
        return deviceMapper.selectList(new QueryWrapper<DeviceEntity>().orderByAsc("created_at"))
                .stream()
                .map(DeviceEntity::getDeviceId)
                .toList();
    }

    /** 清理一台设备的全部数据：业务表 + 同步元数据。 */
    public boolean dropDeviceScope(String deviceId) {
        String id = String.valueOf(deviceId);
        return meta(connection -> {
            boolean existed = Db.queryOne(connection,
                    "SELECT 1 AS x FROM devices WHERE device_id = ?", id) != null;
            for (SchemaCatalog.DatabaseDef database : schema.databases().values()) {
                for (String table : database.tables().keySet()) {
                    Db.update(connection, "DELETE FROM `" + table + "` WHERE device_id = ?", id);
                }
            }
            Db.update(connection, "DELETE FROM row_meta WHERE device_id = ?", id);
            Db.update(connection, "DELETE FROM change_log WHERE device_id = ?", id);
            Db.update(connection, "DELETE FROM device_cursors WHERE device_id = ?", id);
            Db.update(connection, "DELETE FROM conflicts WHERE device_id = ?", id);
            Db.update(connection, "DELETE FROM devices WHERE device_id = ?", id);
            return existed;
        });
    }

    // ───────────────────────────── 旧文件兼容（仅导入导出/迁移用）─────────────────────────────

    public Path dataDir() {
        return props.dataDirPath();
    }

    public Path devicesRootDir() {
        return dataDir().resolve("devices");
    }

    public Path scopeDirOf(String deviceId) {
        return devicesRootDir().resolve(sanitizeDeviceId(deviceId)).normalize();
    }

    public String sanitizeDeviceId(String deviceId) {
        String value = deviceId == null ? "" : deviceId.trim();
        if (value.isEmpty()) {
            return props.getWebDeviceId();
        }
        return value.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    public List<LegacyFile> legacyFiles() {
        List<LegacyFile> out = new ArrayList<>();
        Path root = devicesRootDir();
        if (!Files.isDirectory(root)) {
            return out;
        }
        try (Stream<Path> files = Files.walk(root, 3)) {
            files.filter(Files::isRegularFile)
                    .filter(path -> path.getFileName().toString().endsWith(".db"))
                    .sorted()
                    .forEach(path -> {
                        try {
                            out.add(new LegacyFile(root.relativize(path).toString().replace('\\', '/'),
                                    Files.size(path)));
                        } catch (IOException ignored) {
                            // 文件被占用时忽略大小
                        }
                    });
        } catch (IOException e) {
            log.warn("扫描旧数据文件失败：{}", e.getMessage());
        }
        return out;
    }

    /** 打开旧 SQLite 文件（只读导入 / 导出写入用）。 */
    public Connection openExternal(Path file, boolean readOnly) throws SQLException {
        SQLiteConfig config = new SQLiteConfig();
        if (readOnly) {
            config.setReadOnly(true);
        }
        String url = "jdbc:sqlite:" + file.toAbsolutePath().toString().replace('\\', '/');
        Connection connection = DriverManager.getConnection(url, config.toProperties());
        try (Statement statement = connection.createStatement()) {
            statement.execute("PRAGMA busy_timeout = 5000");
            if (!readOnly) {
                statement.execute("PRAGMA journal_mode = DELETE");
            }
        }
        return connection;
    }

    /**
     * 导出：把 MySQL 中某设备某库的数据写成 SQLite 文件，保持前端「下载 .db」的体验。
     */
    public Path snapshotToFile(String deviceId, String dbKey, Path target) {
        SchemaCatalog.DatabaseDef database = schema.database(dbKey);
        if (database == null) {
            throw new ApiException(400, "未知的数据库：" + dbKey);
        }
        try {
            Files.deleteIfExists(target);
            if (target.getParent() != null) {
                Files.createDirectories(target.getParent());
            }
            try (Connection sqlite = openExternal(target, false)) {
                schema.createAllTables(sqlite, dbKey);
                for (String table : database.tables().keySet()) {
                    exportTable(deviceId, table, sqlite);
                }
            }
            return target;
        } catch (Exception e) {
            throw new RuntimeException("导出 .db 失败：" + e.getMessage(), e);
        }
    }

    private void exportTable(String deviceId, String table, Connection target) throws Exception {
        List<Map<String, Object>> rows = app(deviceId, dbKeyOf(table), connection ->
                Db.query(connection, "SELECT * FROM `" + table + "` WHERE device_id = ? ORDER BY _row_id", deviceId));
        if (rows.isEmpty()) {
            return;
        }
        List<String> columns = new ArrayList<>(rows.get(0).keySet());
        columns.remove("_row_id");
        columns.remove("device_id");
        String placeholders = String.join(", ", java.util.Collections.nCopies(columns.size(), "?"));
        String sql = "INSERT INTO `" + table + "` (" + quote(columns) + ") VALUES (" + placeholders + ")";
        for (Map<String, Object> row : rows) {
            Object[] args = new Object[columns.size()];
            for (int i = 0; i < columns.size(); i++) {
                args[i] = row.get(columns.get(i));
            }
            Db.update(target, sql, args);
        }
    }

    private String dbKeyOf(String table) {
        for (Map.Entry<String, SchemaCatalog.DatabaseDef> entry : schema.databases().entrySet()) {
            if (entry.getValue().tables().containsKey(table)) {
                return entry.getKey();
            }
        }
        throw new ApiException(400, "未知的表：" + table);
    }

    private static String quote(List<String> columns) {
        List<String> out = new ArrayList<>();
        for (String column : columns) {
            out.add("`" + column + "`");
        }
        return String.join(", ", out);
    }

    private <T> T call(ThrowingSupplier<T> action) {
        try {
            return action.get();
        } catch (RuntimeException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException(e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage(), e);
        }
    }
}
