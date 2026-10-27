package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.util.UriUtils;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * APK 发布目录的读取、校验与发布。
 *
 * <pre>
 * data/app-update/
 *   latest.json
 *   deepseekapp-5.1.1.apk
 * </pre>
 *
 * latest.json 只存业务信息，size / sha256 每次按文件自动计算（按大小 + 修改时间缓存）。
 */
@Service
public class AppUpdateService {

    private static final Logger log = LoggerFactory.getLogger(AppUpdateService.class);
    private static final Pattern SAFE_FILE = Pattern.compile("[A-Za-z0-9._-]+");

    private final AppProperties props;
    private final Map<String, CachedHash> hashCache = new ConcurrentHashMap<>();
    private final Object publishLock = new Object();

    private record CachedHash(long size, long modified, String sha256) {
    }

    public record DownloadFile(Path path, String fileName, long size, String sha256) {
    }

    public AppUpdateService(AppProperties props) {
        this.props = props;
    }

    @PostConstruct
    public void init() {
        try {
            Files.createDirectories(props.appUpdateDirPath());
        } catch (Exception e) {
            log.warn("创建 APK 发布目录失败：{}", props.appUpdateDirPath(), e);
        }
    }

    public Path appUpdateDir() {
        return props.appUpdateDirPath();
    }

    /** 最新版本信息；没有发布过 APK 时返回 404 */
    public Map<String, Object> latest(Long currentVersionCode) {
        Map<String, Object> meta = readLatestMeta();
        if (meta == null) {
            throw new ApiException(404, "服务端还没有发布 APK");
        }
        long versionCode = longValue(meta.get("versionCode"), 0);
        String versionName = str(meta.get("versionName"));
        String file = str(meta.get("file"));
        if (versionCode <= 0 || versionName.isEmpty() || file.isEmpty()) {
            throw new ApiException(500, "latest.json 缺少 versionCode / versionName / file");
        }
        Path apk = resolveApk(file);
        CachedHash hash = hashOf(apk);
        boolean hasUpdate = currentVersionCode != null && currentVersionCode > 0
                && versionCode > currentVersionCode;

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("platform", "android");
        out.put("versionCode", versionCode);
        out.put("versionName", versionName);
        out.put("fileName", file);
        out.put("size", hash.size());
        out.put("sha256", hash.sha256());
        out.put("downloadPath", "/api/app/download/" +
                UriUtils.encodePathSegment(file, StandardCharsets.UTF_8));
        out.put("force", Boolean.TRUE.equals(meta.get("force")));
        out.put("changelog", str(meta.get("changelog")));
        out.put("releasedAt", longValue(meta.get("releasedAt"), 0));
        out.put("hasUpdate", hasUpdate);
        return out;
    }

    /** 只允许下载 latest.json 里登记的那个 APK，避免目录里其它文件被随意取走 */
    public DownloadFile downloadFile(String fileName) {
        Map<String, Object> meta = readLatestMeta();
        if (meta == null) {
            throw new ApiException(404, "服务端还没有发布 APK");
        }
        String file = str(meta.get("file"));
        if (!file.equals(fileName)) {
            throw new ApiException(404, "APK 不存在：" + fileName);
        }
        Path apk = resolveApk(file);
        CachedHash hash = hashOf(apk);
        return new DownloadFile(apk, file, hash.size(), hash.sha256());
    }

    /** 上传并发布新 APK；返回最新版本信息 */
    public Map<String, Object> publish(byte[] apkBytes, long versionCode, String versionName,
                                       boolean force, String changelog) {
        if (apkBytes == null || apkBytes.length < 4) {
            throw new ApiException(400, "APK 内容为空");
        }
        if (apkBytes[0] != 'P' || apkBytes[1] != 'K') {
            throw new ApiException(400, "不是有效的 APK（ZIP 文件头不匹配）");
        }
        if (versionCode <= 0) {
            throw new ApiException(400, "versionCode 必须大于 0");
        }
        String name = versionName == null ? "" : versionName.trim();
        if (name.isEmpty()) {
            throw new ApiException(400, "versionName 不能为空");
        }
        String safeVersion = name.replaceAll("[^A-Za-z0-9._-]", "_");
        String file = "deepseekapp-" + (safeVersion.isEmpty() ? versionCode : safeVersion) + ".apk";

        synchronized (publishLock) {
            Path dir = props.appUpdateDirPath();
            Path target = dir.resolve(file);
            try {
                Files.createDirectories(dir);
                Path temp = dir.resolve(file + ".tmp");
                Files.write(temp, apkBytes, StandardOpenOption.CREATE,
                        StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE);
                Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
                hashCache.remove(target.toString());

                Map<String, Object> meta = new LinkedHashMap<>();
                meta.put("versionCode", versionCode);
                meta.put("versionName", name);
                meta.put("file", file);
                meta.put("force", force);
                meta.put("changelog", changelog == null ? "" : changelog);
                meta.put("releasedAt", System.currentTimeMillis());
                Json.MAPPER.writerWithDefaultPrettyPrinter()
                        .writeValue(dir.resolve("latest.json").toFile(), meta);
                log.info("已发布 APK：{}（versionCode={}）", file, versionCode);
            } catch (Exception e) {
                throw new RuntimeException("发布 APK 失败：" + e.getMessage(), e);
            }
        }
        return latest(null);
    }

    private Map<String, Object> readLatestMeta() {
        Path metaFile = props.appUpdateDirPath().resolve("latest.json");
        if (!Files.isRegularFile(metaFile)) {
            return null;
        }
        try {
            return Json.asMap(Json.MAPPER.readValue(metaFile.toFile(), Object.class));
        } catch (Exception e) {
            throw new ApiException(500, "读取 latest.json 失败：" + e.getMessage());
        }
    }

    private Path resolveApk(String fileName) {
        if (fileName == null || !SAFE_FILE.matcher(fileName).matches()
                || ".".equals(fileName) || "..".equals(fileName)) {
            throw new ApiException(400, "非法的 APK 文件名：" + fileName);
        }
        Path dir = props.appUpdateDirPath().toAbsolutePath().normalize();
        Path apk = dir.resolve(fileName).normalize();
        if (!apk.startsWith(dir) || !Files.isRegularFile(apk)) {
            throw new ApiException(404, "APK 不存在：" + fileName);
        }
        return apk;
    }

    private CachedHash hashOf(Path apk) {
        try {
            long size = Files.size(apk);
            long modified = Files.getLastModifiedTime(apk).toMillis();
            CachedHash cached = hashCache.get(apk.toString());
            if (cached != null && cached.size() == size && cached.modified() == modified) {
                return cached;
            }

            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream in = Files.newInputStream(apk)) {
                byte[] buffer = new byte[64 * 1024];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    digest.update(buffer, 0, read);
                }
            }
            String hex = hex(digest.digest());
            CachedHash fresh = new CachedHash(size, modified, hex);
            hashCache.put(apk.toString(), fresh);
            return fresh;
        } catch (Exception e) {
            throw new RuntimeException("计算 APK 指纹失败：" + e.getMessage(), e);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16));
            sb.append(Character.forDigit(b & 0xF, 16));
        }
        return sb.toString();
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static long longValue(Object value, long fallback) {
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
}
