package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.Db;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.net.InetAddress;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 生成可被手机 App 直接导入的 .db 文件 */
@Service
public class Exporter {

    private static final List<String> SECRET_COLUMNS = List.of("apiKey", "baidu_api_key");
    private static final DateTimeFormatter STAMP = DateTimeFormatter
            .ofPattern("yyyy-MM-dd-HHmmss")
            .withZone(ZoneOffset.UTC);

    public record ExportInfo(Path file, long bytes, String fileName, List<String> sanitized,
                             String deviceId, long generatedAt, String host) {
    }

    private final DatabaseManager databaseManager;
    private final SchemaCatalog schema;
    private final AppProperties props;

    public Exporter(DatabaseManager databaseManager, SchemaCatalog schema, AppProperties props) {
        this.databaseManager = databaseManager;
        this.schema = schema;
        this.props = props;
    }

    public ExportInfo exportDatabase(String dbKey, boolean sanitizeSecrets, String deviceId) {
        if (!schema.hasDatabase(dbKey)) {
            throw new ApiException(400, "未知的数据库：" + dbKey);
        }
        Path temp = props.dataDirPath().resolve("tmp-export-" + UUID.randomUUID() + ".db");
        try {
            databaseManager.snapshotToFile(deviceId, dbKey, temp);
            List<String> sanitized = new ArrayList<>();
            if (sanitizeSecrets && schema.hasTable(dbKey, "user_settings")) {
                List<String> columns = new ArrayList<>();
                for (SchemaCatalog.ColumnDef column : schema.tableDef(dbKey, "user_settings").columns()) {
                    if (SECRET_COLUMNS.contains(column.name())) {
                        columns.add(column.name());
                    }
                }
                if (!columns.isEmpty()) {
                    try (Connection out = databaseManager.openExternal(temp, false)) {
                        String sets = String.join(", ", columns.stream().map(c -> c + " = ?").toList());
                        Object[] args = columns.stream().map(c -> (Object) "").toArray();
                        Db.update(out, "UPDATE user_settings SET " + sets, args);
                        Db.exec(out, "PRAGMA wal_checkpoint(TRUNCATE)");
                        Db.exec(out, "VACUUM");
                    }
                    sanitized.addAll(columns);
                }
            }

            long bytes = Files.size(temp);
            String stamp = STAMP.format(Instant.now());
            String safeDevice = deviceId.equals(props.getWebDeviceId())
                    ? ""
                    : deviceId.replaceAll("[^A-Za-z0-9._-]", "_") + "_";
            String fileName = dbKey + "_" + safeDevice + "web-" + stamp + ".db";
            String host = "";
            try {
                host = InetAddress.getLocalHost().getHostName();
            } catch (Exception ignore) {
                // 拿不到主机名不影响导出
            }
            return new ExportInfo(temp, bytes, fileName, sanitized, deviceId,
                    System.currentTimeMillis(), host);
        } catch (ApiException e) {
            deleteQuietly(temp);
            throw e;
        } catch (Exception e) {
            deleteQuietly(temp);
            throw new RuntimeException("导出数据库失败：" + e.getMessage(), e);
        }
    }

    public static void deleteQuietly(Path file) {
        try {
            Files.deleteIfExists(file);
        } catch (Exception ignore) {
            // 临时文件删除失败不影响主流程
        }
    }
}
