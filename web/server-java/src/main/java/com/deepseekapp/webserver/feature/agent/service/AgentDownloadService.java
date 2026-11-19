package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.util.OutboundUrlGuard;
import com.deepseekapp.webserver.web.ApiException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Agent 下载库：把网页文件下载到 {@code <data-dir>/downloads/<deviceId>/}，
 * 元数据记在 {@code agent_downloads}。
 *
 * <p>安全边界：只允许 http/https；拒绝本机与内网地址（SSRF）；单文件上限 50MB；
 * 文件名做字符净化，存储路径由服务端生成，避免路径穿越。</p>
 */
@Service
public class AgentDownloadService {

    private static final Logger log = LoggerFactory.getLogger(AgentDownloadService.class);
    private static final long MAX_BYTES = 50L * 1024 * 1024;
    private static final int MAX_FILENAME = 120;
    private static final int MAX_URL = 1000;
    private static final int MAX_REDIRECTS = 3;

    private final AgentStore store;
    private final AppProperties props;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            // 重定向必须手动跟随：每一跳都要重新做内网校验，否则 302 到 127.0.0.1 就绕过了守卫
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    /** 实际取到的响应与最终地址（重定向后的地址用于推断文件名）。 */
    private record Fetched(URI uri, HttpResponse<InputStream> response) {
    }

    public AgentDownloadService(AgentStore store, AppProperties props) {
        this.store = store;
        this.props = props;
    }

    public Map<String, Object> download(String deviceId, String rawUrl, String requestedName) {
        String url = rawUrl == null ? "" : rawUrl.trim();
        if (url.isEmpty()) {
            throw new ApiException(400, "下载地址不能为空");
        }
        if (url.length() > MAX_URL) {
            throw new ApiException(400, "下载地址过长");
        }
        URI uri;
        try {
            uri = URI.create(url);
        } catch (IllegalArgumentException e) {
            throw new ApiException(400, "下载地址格式不正确");
        }
        if (!"http".equalsIgnoreCase(uri.getScheme()) && !"https".equalsIgnoreCase(uri.getScheme())) {
            throw new ApiException(400, "只支持 http/https 下载");
        }
        OutboundUrlGuard.requirePublicHost(uri.getHost());

        Map<String, Object> row = new LinkedHashMap<>();
        row.put("deviceId", deviceId);
        row.put("url", url);
        row.put("filename", "");
        row.put("mime", "");
        row.put("size", 0L);
        row.put("path", "");
        row.put("status", "running");
        row.put("error", null);
        row.put("createdAt", System.currentTimeMillis());

        try {
            Fetched fetched = open(uri);
            HttpResponse<InputStream> response = fetched.response();
            if (response.statusCode() >= 400) {
                throw new ApiException(502, "下载失败：HTTP " + response.statusCode());
            }
            long declared = response.headers().firstValueAsLong("content-length").orElse(-1);
            if (declared > MAX_BYTES) {
                throw new ApiException(413, "文件超过 50MB 上限");
            }

            String filename = resolveFilename(requestedName, response, fetched.uri());
            String mime = response.headers().firstValue("content-type").orElse("application/octet-stream");
            int semicolon = mime.indexOf(';');
            if (semicolon > 0) {
                mime = mime.substring(0, semicolon).trim();
            }

            Path dir = downloadRoot().resolve(safeSegment(deviceId));
            Files.createDirectories(dir);
            String storedName = System.currentTimeMillis() + "-" + filename;
            Path target = dir.resolve(storedName);

            long size = copyLimited(response.body(), target);
            row.put("filename", filename);
            row.put("mime", mime);
            row.put("size", size);
            row.put("path", target.toAbsolutePath().toString());
            row.put("status", "done");
            store.insertDownload(row);
            return view(row);
        } catch (ApiException e) {
            row.put("status", "failed");
            row.put("error", shorten(e.getMessage()));
            store.insertDownload(row);
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(500, "下载被中断");
        } catch (Exception e) {
            log.warn("下载失败 {}：{}", url, e.getMessage());
            row.put("status", "failed");
            row.put("error", shorten(e.getMessage()));
            store.insertDownload(row);
            throw new ApiException(502, "下载失败：" + e.getMessage());
        }
    }

    public List<Map<String, Object>> list(String deviceId) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> row : store.listDownloads(deviceId, 200)) {
            out.add(view(row));
        }
        return out;
    }

    public Path resolveFile(String deviceId, long id) {
        Map<String, Object> row = store.findDownload(id, deviceId);
        if (row == null) {
            throw new ApiException(404, "下载记录不存在");
        }
        String path = String.valueOf(row.getOrDefault("path", ""));
        if (path.isBlank()) {
            throw new ApiException(404, "文件已被清理");
        }
        Path file = Paths.get(path).toAbsolutePath().normalize();
        Path root = downloadRoot().toAbsolutePath().normalize();
        if (!file.startsWith(root) || !Files.isRegularFile(file)) {
            throw new ApiException(404, "文件不存在或路径非法");
        }
        return file;
    }

    public Map<String, Object> find(String deviceId, long id) {
        Map<String, Object> row = store.findDownload(id, deviceId);
        if (row == null) {
            throw new ApiException(404, "下载记录不存在");
        }
        return view(row);
    }

    public void delete(String deviceId, long id) {
        Map<String, Object> row = store.findDownload(id, deviceId);
        if (row == null) {
            return;
        }
        String path = String.valueOf(row.getOrDefault("path", ""));
        if (!path.isBlank()) {
            try {
                Path file = Paths.get(path).toAbsolutePath().normalize();
                if (file.startsWith(downloadRoot().toAbsolutePath().normalize())) {
                    Files.deleteIfExists(file);
                }
            } catch (IOException e) {
                log.warn("删除下载文件失败：{}", e.getMessage());
            }
        }
        store.deleteDownload(id, deviceId);
    }

    private Path downloadRoot() {
        return Paths.get(props.getDataDir()).resolve("downloads");
    }

    private static long copyLimited(InputStream in, Path target) throws IOException {
        long total = 0;
        try (InputStream source = in;
             OutputStream out = Files.newOutputStream(target, StandardOpenOption.CREATE,
                     StandardOpenOption.TRUNCATE_EXISTING)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = source.read(buffer)) >= 0) {
                total += read;
                if (total > MAX_BYTES) {
                    throw new IOException("文件超过 50MB 上限，已中止");
                }
                out.write(buffer, 0, read);
            }
        } catch (IOException e) {
            Files.deleteIfExists(target);
            throw e;
        }
        return total;
    }

    private static String resolveFilename(String requested, HttpResponse<?> response, URI uri) {
        String name = sanitize(requested);
        if (name.isBlank()) {
            String disposition = response.headers().firstValue("content-disposition").orElse("");
            name = sanitize(extractFilename(disposition));
        }
        if (name.isBlank()) {
            String path = uri.getPath();
            if (path != null && path.contains("/")) {
                name = sanitize(path.substring(path.lastIndexOf('/') + 1));
            }
        }
        if (name.isBlank()) {
            name = "download-" + System.currentTimeMillis() + ".bin";
        }
        return name;
    }

    private static String extractFilename(String disposition) {
        for (String part : disposition.split(";")) {
            String value = part.trim();
            if (value.toLowerCase().startsWith("filename*=")) {
                int idx = value.indexOf("''");
                return idx >= 0 ? value.substring(idx + 2) : value.substring(10);
            }
            if (value.toLowerCase().startsWith("filename=")) {
                return value.substring(9).replace("\"", "").trim();
            }
        }
        return "";
    }

    private static String sanitize(String name) {
        if (name == null) {
            return "";
        }
        String value = name.trim()
                .replaceAll("[\\\\/:*?\"<>|\\x00-\\x1F]", "_")
                .replaceAll("\\.{2,}", ".");
        if (value.equals(".") || value.equals("..")) {
            return "";
        }
        if (value.length() > MAX_FILENAME) {
            value = value.substring(value.length() - MAX_FILENAME);
        }
        return value;
    }

    private static String safeSegment(String value) {
        return value == null || value.isBlank() ? "default" : value.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    /**
     * 取回响应，手动跟随最多 {@link #MAX_REDIRECTS} 次跳转，并在每一跳前重新校验地址。
     */
    private Fetched open(URI uri) throws IOException, InterruptedException {
        URI current = uri;
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            OutboundUrlGuard.requirePublicHost(current.getHost());
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(current)
                    .timeout(Duration.ofSeconds(60))
                    .header("User-Agent", "deepseekapp-agent/1.0")
                    .GET()
                    .build();
            HttpResponse<InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
            int status = response.statusCode();
            if (status < 300 || status >= 400) {
                return new Fetched(current, response);
            }
            String location = response.headers().firstValue("location").orElse("");
            response.body().close();
            if (location.isBlank()) {
                throw new ApiException(502, "下载失败：重定向缺少目标地址");
            }
            URI next = current.resolve(location.trim());
            String scheme = next.getScheme() == null ? "" : next.getScheme().toLowerCase();
            if (!"http".equals(scheme) && !"https".equals(scheme)) {
                throw new ApiException(400, "重定向到了不支持的协议");
            }
            current = next;
        }
        throw new ApiException(502, "下载失败：重定向次数过多");
    }

    private static String shorten(String message) {
        String text = message == null ? "" : message;
        return text.length() > 400 ? text.substring(0, 400) : text;
    }

    private static Map<String, Object> view(Map<String, Object> row) {
        Map<String, Object> out = new LinkedHashMap<>();
        Object id = row.get("id");
        out.put("id", id);
        out.put("url", row.get("url"));
        out.put("filename", row.get("filename"));
        out.put("mime", row.get("mime"));
        out.put("size", row.get("size"));
        out.put("status", row.get("status"));
        out.put("error", row.get("error"));
        out.put("createdAt", row.get("created_at") == null ? row.get("createdAt") : row.get("created_at"));
        out.put("downloadUrl", "/api/agent/downloads/" + id + "/file");
        return out;
    }
}
