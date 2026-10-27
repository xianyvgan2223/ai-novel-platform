package com.deepseekapp.webserver.db;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.sqlite.SQLiteConfig;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.locks.ReentrantLock;
import java.util.stream.Stream;

/**
 * SQLite 访问层：全局登记表 + 每台设备独立的数据槽位。
 *
 * <p>与原 Node 版保持一致：</p>
 * <pre>
 * data/
 *   devices/&lt;设备号&gt;/
 *     deepseek.db   该设备的业务库
 *     novel.db
 *     sync.db       该设备的 row_meta / change_log
 *   sync.db         全局登记表（设备 / 请求 / 冲突）
 * </pre>
 *
 * <p>并发策略：所有数据库操作共用一把可重入锁。这个服务是本地单机/局域网使用，
 * 并发量很低，SQLite 的写本身也串行；用一把锁可以彻底避免同一 Connection 被多个
 * 请求线程同时使用的问题。</p>
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

    public static final class DeviceScope {
        public final String deviceId;
        public final Path root;
        final Map<String, Connection> dbs = new HashMap<>();
        Connection syncMeta;

        DeviceScope(String deviceId, Path root) {
            this.deviceId = deviceId;
            this.root = root;
        }

        public Connection db(String dbKey) {
            return dbs.get(dbKey);
        }
    }

    public record LegacyFile(String file, long bytes) {
    }

    private final AppProperties props;
    private final SchemaCatalog schema;
    private final ReentrantLock lock = new ReentrantLock(true);

    private Connection meta;
    private final Map<String, DeviceScope> scopes = new LinkedHashMap<>();

    public DatabaseManager(AppProperties props, SchemaCatalog schema) {
        this.props = props;
        this.schema = schema;
    }

    // ───────────────────────────── 初始化 ─────────────────────────────

    @PostConstruct
    public void init() {
        lock.lock();
        try {
            Files.createDirectories(props.dataDirPath());
            meta = open(props.dataDirPath().resolve("sync.db"), false);
            Db.exec(meta, META_DDL);
            migrateMetaSchema();
            migrateLegacyData();
            ensureWebDevice();
            for (String deviceId : knownDeviceIdsInternal()) {
                openScope(deviceId);
            }
        } catch (IOException e) {
            throw new IllegalStateException("初始化数据目录失败", e);
        } finally {
            lock.unlock();
        }
    }

    @PreDestroy
    public void closeAll() {
        lock.lock();
        try {
            for (DeviceScope scope : scopes.values()) {
                for (Connection c : scope.dbs.values()) {
                    Db.closeQuietly(c);
                }
                Db.closeQuietly(scope.syncMeta);
            }
            scopes.clear();
            Db.closeQuietly(meta);
            meta = null;
        } finally {
            lock.unlock();
        }
    }

    // ───────────────────────────── 对外访问 ─────────────────────────────

    public <T> T meta(SqlFunction<T> action) {
        lock.lock();
        try {
            Connection connection = requireMeta();
            return call(() -> action.apply(connection));
        } finally {
            lock.unlock();
        }
    }

    public <T> T scope(String deviceId, ScopeFunction<T> action) {
        lock.lock();
        try {
            DeviceScope deviceScope = openScope(deviceId);
            return call(() -> action.apply(deviceScope));
        } finally {
            lock.unlock();
        }
    }

    public <T> T app(String deviceId, String dbKey, SqlFunction<T> action) {
        if (!schema.hasDatabase(dbKey)) {
            throw new ApiException(404, "未知的数据库：" + dbKey);
        }
        return scope(deviceId, scope -> {
            Connection connection = scope.dbs.get(dbKey);
            if (connection == null) {
                throw new ApiException(404, "未知的数据库：" + dbKey);
            }
            return action.apply(connection);
        });
    }

    public <T> T scopeMeta(String deviceId, SqlFunction<T> action) {
        return scope(deviceId, scope -> action.apply(scopeMetaConn(scope)));
    }

    /** 已经持有 scope 锁时，直接取该槽位的同步元数据库连接。 */
    public Connection scopeMetaConnection(DeviceScope scope) {
        return scopeMetaConn(scope);
    }

    /** 打开一个临时/外部 SQLite 文件（调用方负责关闭）。 */
    public Connection openExternal(Path file, boolean readOnly) {
        return open(file, readOnly);
    }

    /** 需要同时锁住多个槽位/多个库时使用；内部调用仍然可重入。 */
    public <T> T locked(ThrowingSupplier<T> action) {
        lock.lock();
        try {
            return call(action);
        } finally {
            lock.unlock();
        }
    }

    public SchemaCatalog schema() {
        return schema;
    }

    public Path dataDir() {
        return props.dataDirPath();
    }

    public Path devicesRootDir() {
        return dataDir().resolve("devices");
    }

    public Path scopeDirOf(String deviceId) {
        return devicesRootDir().resolve(sanitizeDeviceId(deviceId));
    }

    public boolean deviceScopeExists(String deviceId) {
        lock.lock();
        try {
            if (scopes.containsKey(deviceId)) {
                return true;
            }
            try {
                return Files.exists(scopeDirOf(deviceId));
            } catch (RuntimeException e) {
                return false;
            }
        } finally {
            lock.unlock();
        }
    }

    public List<String> knownDeviceIds() {
        return meta(conn -> {
            List<Map<String, Object>> rows = Db.query(conn,
                    "SELECT device_id FROM devices ORDER BY created_at ASC");
            List<String> out = new ArrayList<>();
            for (Map<String, Object> row : rows) {
                out.add(String.valueOf(row.get("device_id")));
            }
            return out;
        });
    }

    // ───────────────────────────── 槽位与连接 ─────────────────────────────

    private DeviceScope openScope(String rawDeviceId) {
        String deviceId = String.valueOf(rawDeviceId);
        DeviceScope cached = scopes.get(deviceId);
        if (cached != null) {
            return cached;
        }

        Path root = ensureDeviceScope(deviceId);
        DeviceScope scope = new DeviceScope(deviceId, root);
        for (Map.Entry<String, SchemaCatalog.DatabaseDef> entry : schema.databases().entrySet()) {
            Path file = root.resolve(entry.getValue().file());
            Connection connection = open(file, false);
            schema.createAllTables(connection, entry.getKey());
            scope.dbs.put(entry.getKey(), connection);
        }
        scopes.put(deviceId, scope);
        return scope;
    }

    /**
     * 首次用到某台设备时创建它的数据目录，并写入设备登记表。
     */
    private Path ensureDeviceScope(String deviceId) {
        DeviceScope cached = scopes.get(deviceId);
        if (cached != null) {
            return cached.root;
        }
        Map<String, Object> existing = Db.queryOne(requireMeta(),
                "SELECT * FROM devices WHERE device_id = ?", deviceId);
        Path root = scopeDirOf(deviceId);
        if (existing != null && existing.get("scope_dir") != null
                && !String.valueOf(existing.get("scope_dir")).isBlank()) {
            Path candidate = devicesRootDir().resolve(String.valueOf(existing.get("scope_dir"))).normalize();
            if (candidate.startsWith(devicesRootDir().normalize())) {
                root = candidate;
            }
        }
        try {
            Files.createDirectories(root);
        } catch (IOException e) {
            throw new RuntimeException("创建设备数据目录失败：" + root, e);
        }

        String scopeDir = devicesRootDir().relativize(root).toString().replace('\\', '/');
        if (scopeDir.isBlank()) {
            scopeDir = sanitizeDeviceId(deviceId);
        }
        if (existing == null) {
            Db.update(requireMeta(),
                    "INSERT INTO devices (device_id, name, platform, id_base, scope_dir, last_seen_at, created_at) " +
                            "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    deviceId, "", "", props.getWebIdBase(), scopeDir, null, System.currentTimeMillis());
        } else if (!scopeDir.equals(String.valueOf(existing.get("scope_dir")))) {
            Db.update(requireMeta(), "UPDATE devices SET scope_dir = ? WHERE device_id = ?", scopeDir, deviceId);
        }
        return root;
    }

    private Connection scopeMetaConn(DeviceScope scope) {
        if (scope.syncMeta == null) {
            scope.syncMeta = open(scope.root.resolve("sync.db"), false);
            Db.exec(scope.syncMeta, SCOPE_DDL);
        }
        return scope.syncMeta;
    }

    private Connection requireMeta() {
        if (meta == null) {
            throw new IllegalStateException("数据库未初始化，请先执行 init()");
        }
        return meta;
    }

    private Connection open(Path file, boolean readOnly) {
        SQLiteConfig config = new SQLiteConfig();
        if (readOnly) {
            config.setReadOnly(true);
        }
        String url = "jdbc:sqlite:" + file.toAbsolutePath().toString().replace('\\', '/');
        try {
            Connection connection = DriverManager.getConnection(url, config.toProperties());
            try (var st = connection.createStatement()) {
                if (!readOnly) {
                    st.execute("PRAGMA journal_mode = WAL");
                    st.execute("PRAGMA synchronous = NORMAL");
                }
                st.execute("PRAGMA foreign_keys = ON");
                st.execute("PRAGMA busy_timeout = 5000");
            }
            return connection;
        } catch (Exception e) {
            throw new RuntimeException("打开数据库失败：" + file, e);
        }
    }

    /** 导出用：合并 WAL 后把规范库复制成单文件 */
    public Path snapshotToFile(String deviceId, String dbKey, Path target) {
        return scope(deviceId, scope -> {
            Connection connection = scope.dbs.get(dbKey);
            if (connection == null) {
                throw new ApiException(400, "未知的数据库：" + dbKey);
            }
            Db.exec(connection, "PRAGMA wal_checkpoint(TRUNCATE)");
            Files.copy(scope.root.resolve(schema.database(dbKey).file()), target,
                    StandardCopyOption.REPLACE_EXISTING);
            return target;
        });
    }

    /** 删除一台设备的整个槽位目录（先关连接，再删文件） */
    public boolean dropDeviceScope(String deviceId) {
        lock.lock();
        try {
            DeviceScope scope = scopes.remove(deviceId);
            Path dir;
            if (scope != null) {
                for (Connection c : scope.dbs.values()) {
                    Db.closeQuietly(c);
                }
                Db.closeQuietly(scope.syncMeta);
                dir = scope.root;
            } else {
                dir = scopeDirOf(deviceId);
            }
            if (!Files.exists(dir)) {
                return false;
            }
            if (!dir.toAbsolutePath().normalize().startsWith(devicesRootDir().toAbsolutePath().normalize())) {
                return false;
            }
            try (Stream<Path> walk = Files.walk(dir)) {
                walk.sorted(Comparator.reverseOrder()).forEach(path -> {
                    try {
                        Files.deleteIfExists(path);
                    } catch (IOException e) {
                        throw new RuntimeException("删除文件失败：" + path, e);
                    }
                });
            }
            return true;
        } catch (IOException e) {
            throw new RuntimeException("删除设备槽位失败：" + deviceId, e);
        } finally {
            lock.unlock();
        }
    }

    // ───────────────────────────── 遗留数据 / 迁移 ─────────────────────────────

    /** v1 时期的共享库还在不在（data/deepseek.db 等） */
    public List<LegacyFile> legacyFiles() {
        List<LegacyFile> out = new ArrayList<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Path main = dataDir().resolve(def.file());
            if (Files.exists(main)) {
                out.add(new LegacyFile(def.file(), sizeOf(main)));
                continue;
            }
            Path wal = dataDir().resolve(def.file() + "-wal");
            if (Files.exists(wal)) {
                long bytes = sizeOf(wal);
                if (bytes > 0) {
                    out.add(new LegacyFile(def.file() + "-wal", bytes));
                }
            }
        }
        return out;
    }

    private void migrateMetaSchema() {
        List<String> added = new ArrayList<>();
        if (!Db.columnsOf(requireMeta(), "devices").contains("scope_dir")) {
            Db.exec(requireMeta(), "ALTER TABLE devices ADD COLUMN scope_dir TEXT NOT NULL DEFAULT ''");
            added.add("devices.scope_dir");
        }
        if (!Db.columnsOf(requireMeta(), "conflicts").contains("device_id")) {
            Db.exec(requireMeta(), "ALTER TABLE conflicts ADD COLUMN device_id TEXT NOT NULL DEFAULT ''");
            added.add("conflicts.device_id");
        }
        if (added.contains("conflicts.device_id")) {
            Db.exec(requireMeta(), "UPDATE conflicts SET device_id = incoming_device WHERE device_id = ''");
            added.add("conflicts.device_id 已按来源设备回填");
        }
        if (!added.isEmpty()) {
            log.info("同步元数据表已升级：{}", String.join("、", added));
        }
    }

    /**
     * v1 的服务端把全部设备的数据混在 data/deepseek.db 与 data/novel.db 里。
     * 首次启动（登记表里一台设备都没有时）把整份混库搬进 Web 控制台槽位，
     * 原文件改名成 *.legacy-bak 留档。
     */
    private void migrateLegacyData() {
        List<Path> legacy = new ArrayList<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Path file = dataDir().resolve(def.file());
            if (Files.exists(file)) {
                legacy.add(file);
            }
        }
        if (legacy.isEmpty()) {
            return;
        }
        Map<String, Object> countRow = Db.queryOne(requireMeta(), "SELECT COUNT(*) AS n FROM devices");
        long deviceCount = countRow == null ? 0 : ((Number) countRow.get("n")).longValue();
        if (deviceCount > 0) {
            log.info("检测到 v1 的共享库 {}，但它们不会再被自动读取（每台设备现在各有独立目录）。" +
                            "需要里面的数据时：在网页「同步与备份」页选中目标设备后上传该 .db 导入即可。",
                    legacy.stream().map(p -> p.getFileName().toString()).toList());
            return;
        }

        Path target = scopeDirOf(props.getWebDeviceId());
        try {
            Files.createDirectories(target);
        } catch (IOException e) {
            throw new RuntimeException("创建 Web 控制台槽位失败", e);
        }

        List<String> moved = new ArrayList<>();
        for (Path file : legacy) {
            for (String suffix : List.of("", "-wal", "-shm")) {
                Path from = Path.of(file.toString() + suffix);
                if (!Files.exists(from)) {
                    continue;
                }
                Path to = target.resolve(from.getFileName().toString());
                try {
                    if (!Files.exists(to)) {
                        Files.copy(from, to);
                    }
                    Files.move(from, Path.of(from.toString() + ".legacy-bak"),
                            StandardCopyOption.REPLACE_EXISTING);
                } catch (IOException e) {
                    throw new RuntimeException("迁移遗留数据库失败：" + from, e);
                }
            }
            moved.add(file.getFileName().toString());
        }
        log.info("检测到 v1 的共享库 {}，已复制到 Web 控制台槽位：{}，原文件已改名为 *.legacy-bak 留档。",
                String.join("、", moved), target);
    }

    private void ensureWebDevice() {
        Map<String, Object> existing = Db.queryOne(requireMeta(),
                "SELECT 1 AS x FROM devices WHERE device_id = ?", props.getWebDeviceId());
        if (existing == null) {
            Db.update(requireMeta(),
                    "INSERT INTO devices (device_id, name, platform, id_base, scope_dir, last_seen_at, created_at) " +
                            "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    props.getWebDeviceId(), "Web 控制台", "web", props.getWebIdBase(), "", null,
                    System.currentTimeMillis());
        }
    }

    private List<String> knownDeviceIdsInternal() {
        List<Map<String, Object>> rows = Db.query(requireMeta(),
                "SELECT device_id FROM devices ORDER BY created_at ASC");
        List<String> out = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            out.add(String.valueOf(row.get("device_id")));
        }
        return out;
    }

    // ───────────────────────────── 工具 ─────────────────────────────

    public String sanitizeDeviceId(String deviceId) {
        String raw = deviceId == null ? "" : deviceId.trim();
        if (raw.isEmpty()) {
            throw new ApiException(400, "设备号不能为空");
        }
        if (raw.length() > 64) {
            throw new ApiException(400, "设备号过长（上限 64 字符）：" + raw.substring(0, 32) + "…");
        }
        String clean = raw.replaceAll("[^A-Za-z0-9._-]", "_").replaceAll("^[.]+", "_");
        if (clean.equals(".") || clean.equals("..")) {
            throw new ApiException(400, "非法设备号：" + raw);
        }
        return clean;
    }

    private static long sizeOf(Path path) {
        try {
            return Files.size(path);
        } catch (IOException e) {
            return 0;
        }
    }

    private <T> T call(ThrowingSupplier<T> action) {
        try {
            return action.get();
        } catch (ApiException e) {
            throw e;
        } catch (RuntimeException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException(e.getMessage(), e);
        }
    }

    private static final String META_DDL = """
            CREATE TABLE IF NOT EXISTS devices (
              device_id     TEXT PRIMARY KEY,
              name          TEXT NOT NULL DEFAULT '',
              platform      TEXT NOT NULL DEFAULT '',
              id_base       INTEGER NOT NULL DEFAULT 1,
              scope_dir     TEXT NOT NULL DEFAULT '',
              last_seen_at  INTEGER,
              created_at    INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS device_cursors (
              device_id     TEXT PRIMARY KEY,
              last_pull_seq INTEGER NOT NULL DEFAULT 0,
              last_push_at  INTEGER,
              last_pull_at  INTEGER
            );

            CREATE TABLE IF NOT EXISTS conflicts (
              id              INTEGER PRIMARY KEY AUTOINCREMENT,
              device_id       TEXT NOT NULL DEFAULT '',
              db              TEXT NOT NULL,
              table_name      TEXT NOT NULL,
              pk              INTEGER NOT NULL,
              incoming_rev    INTEGER NOT NULL,
              server_rev      INTEGER NOT NULL,
              incoming_device TEXT NOT NULL,
              detected_at     INTEGER NOT NULL,
              resolution      TEXT NOT NULL DEFAULT 'server-wins',
              detail          TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS sync_requests (
              id            INTEGER PRIMARY KEY AUTOINCREMENT,
              target_device TEXT NOT NULL DEFAULT '',
              requested_by  TEXT NOT NULL DEFAULT '',
              requested_at  INTEGER NOT NULL,
              status        TEXT NOT NULL DEFAULT 'pending',
              claimed_at    INTEGER,
              finished_at   INTEGER,
              result        TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_sync_requests_status ON sync_requests(status, id);

            CREATE TABLE IF NOT EXISTS sync_progress (
              request_id INTEGER PRIMARY KEY,
              message    TEXT NOT NULL DEFAULT '',
              current    INTEGER,
              total      INTEGER,
              updated_at INTEGER NOT NULL
            );
            """;

    private static final String SCOPE_DDL = """
            CREATE TABLE IF NOT EXISTS row_meta (
              db            TEXT NOT NULL,
              table_name    TEXT NOT NULL,
              pk            INTEGER NOT NULL,
              rev           INTEGER NOT NULL DEFAULT 1,
              origin_device TEXT NOT NULL DEFAULT '',
              updated_at    INTEGER NOT NULL,
              deleted       INTEGER NOT NULL DEFAULT 0,
              content_hash  TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (db, table_name, pk)
            );
            CREATE INDEX IF NOT EXISTS idx_row_meta_updated ON row_meta(updated_at);

            CREATE TABLE IF NOT EXISTS change_log (
              seq           INTEGER PRIMARY KEY AUTOINCREMENT,
              db            TEXT NOT NULL,
              table_name    TEXT NOT NULL,
              pk            INTEGER NOT NULL,
              op            TEXT NOT NULL,
              rev           INTEGER NOT NULL,
              origin_device TEXT NOT NULL DEFAULT '',
              server_time   INTEGER NOT NULL,
              payload       TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_change_log_lookup ON change_log(db, table_name, pk);
            """;
}
