package com.deepseekapp.webserver.feature.update.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.config.ServerInfo;
import com.deepseekapp.webserver.feature.update.service.AppUpdateService;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.StreamingResponseBody;
import org.springframework.web.util.HtmlUtils;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

/** App 更新：版本查询、APK 下载、发布与浏览器下载页 */
@RestController
public class AppUpdateController {

    private final AppProperties props;
    private final AppUpdateService service;
    private final ServerInfo serverInfo;

    public AppUpdateController(AppProperties props, AppUpdateService service, ServerInfo serverInfo) {
        this.props = props;
        this.service = service;
        this.serverInfo = serverInfo;
    }

    @GetMapping("/api/app/latest")
    public Map<String, Object> latest(@RequestParam(required = false) Long versionCode,
                                      @RequestParam(defaultValue = "android") String platform) {
        if (!"android".equalsIgnoreCase(platform)) {
            throw new ApiException(400, "暂只支持 Android");
        }
        return Api.ok(service.latest(versionCode));
    }

    @GetMapping("/api/app/download/{fileName}")
    public ResponseEntity<StreamingResponseBody> download(@PathVariable String fileName) {
        AppUpdateService.DownloadFile file = service.downloadFile(fileName);
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.parseMediaType("application/vnd.android.package-archive"));
        headers.setContentDisposition(ContentDisposition.attachment()
                .filename(file.fileName(), StandardCharsets.UTF_8)
                .build());
        headers.setContentLength(file.size());
        headers.setETag("\"" + file.sha256() + "\"");
        headers.setCacheControl("no-cache");

        StreamingResponseBody body = outputStream -> {
            try (InputStream in = Files.newInputStream(file.path())) {
                in.transferTo(outputStream);
            }
        };
        return new ResponseEntity<>(body, headers, HttpStatus.OK);
    }

    /**
     * 发布新 APK。只允许本机访问，或带正确的 x-api-token。
     *
     * <pre>
     * POST /api/app/upload?versionCode=4&amp;versionName=5.2.0&amp;force=false
     * Content-Type: application/octet-stream
     * </pre>
     */
    @PostMapping("/api/app/upload")
    public Map<String, Object> upload(@RequestParam(required = false) Long versionCode,
                                      @RequestParam(required = false) String versionName,
                                      @RequestParam(defaultValue = "false") boolean force,
                                      @RequestParam(defaultValue = "") String changelog,
                                      HttpServletRequest request) throws IOException {
        requireAdmin(request);
        if (versionCode == null) {
            throw new ApiException(400, "缺少 versionCode");
        }
        if (versionName == null || versionName.isBlank()) {
            throw new ApiException(400, "缺少 versionName");
        }
        long max = props.maxUploadBytes();
        if (request.getContentLengthLong() > max) {
            throw new ApiException(413, "APK 超过上限 " + props.getMaxUploadMb() + "MB");
        }
        byte[] body = readLimited(request.getInputStream(), max);
        return Api.ok(service.publish(body, versionCode, versionName.trim(), force, changelog));
    }

    /** 浏览器直接下载页（手机不方便走 App 内更新时用） */
    @GetMapping(value = "/download", produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> downloadPage() {
        Map<String, Object> latest;
        try {
            latest = service.latest(null);
        } catch (ApiException e) {
            String html = """
                    <!doctype html>
                    <html lang="zh-CN"><head><meta charset="utf-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1">
                    <title>deepseekapp 下载</title></head>
                    <body style="font-family:system-ui,sans-serif;padding:40px;line-height:1.7">
                      <h1>deepseekapp</h1>
                      <p>服务端还没有发布 APK。</p>
                      <p>请先把 APK 放到：<code>%s</code></p>
                    </body></html>
                    """.formatted(HtmlUtils.htmlEscape(props.appUpdateDirPath().toString()));
            return ResponseEntity.ok().contentType(MediaType.TEXT_HTML).body(html);
        }

        long size = latest.get("size") instanceof Number n ? n.longValue() : 0;
        String versionName = HtmlUtils.htmlEscape(String.valueOf(latest.get("versionName")));
        String versionCode = HtmlUtils.htmlEscape(String.valueOf(latest.get("versionCode")));
        String changelog = HtmlUtils.htmlEscape(String.valueOf(latest.get("changelog")))
                .replace("\n", "<br>");
        String downloadPath = HtmlUtils.htmlEscape(String.valueOf(latest.get("downloadPath")));
        String html = """
                <!doctype html>
                <html lang="zh-CN">
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>deepseekapp 下载</title>
                  <style>
                    body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#f5f6f8;
                         margin:0;padding:40px 20px;color:#1f2329;line-height:1.7}
                    main{max-width:560px;margin:0 auto;background:#fff;border-radius:18px;padding:28px 26px;
                         box-shadow:0 8px 30px rgba(0,0,0,.06)}
                    h1{margin:0 0 8px;font-size:24px}
                    .ver{font-size:18px;font-weight:600;margin:0 0 4px}
                    .meta{color:#6b7280;margin:0 0 18px}
                    .changelog{white-space:normal;background:#f7f8fa;border-radius:12px;padding:14px 16px;
                               color:#374151;margin:0 0 22px}
                    .btn{display:block;text-align:center;background:#4f6ef7;color:#fff;text-decoration:none;
                         padding:14px 18px;border-radius:12px;font-weight:600}
                    .hint{color:#8b95a7;font-size:13px;margin-top:18px}
                    code{background:#eef1f6;padding:2px 6px;border-radius:6px}
                  </style>
                </head>
                <body>
                  <main>
                    <h1>deepseekapp</h1>
                    <p class="ver">最新版本 v%s（versionCode %s）</p>
                    <p class="meta">APK 大小 %.1f MB</p>
                    <div class="changelog">%s</div>
                    <a class="btn" href="%s">下载 APK</a>
                    <p class="hint">手机与电脑需在同一局域网；也可以走 USB 隧道
                      <code>http://127.0.0.1:%d</code>。</p>
                  </main>
                </body>
                </html>
                """.formatted(versionName, versionCode, size / 1024.0 / 1024.0,
                changelog.isEmpty() ? "暂无更新说明" : changelog, downloadPath,
                serverInfo.port());
        return ResponseEntity.ok().contentType(MediaType.TEXT_HTML).body(html);
    }

    private void requireAdmin(HttpServletRequest request) {
        String address = request.getRemoteAddr();
        boolean local = "127.0.0.1".equals(address)
                || "0:0:0:0:0:0:0:1".equals(address)
                || "::1".equals(address);
        String expected = props.getApiToken();
        String token = request.getHeader("x-api-token");
        boolean tokenOk = expected != null && !expected.isEmpty() && expected.equals(token);
        if (!local && !tokenOk) {
            throw new ApiException(403, "上传 APK 需要本机访问或有效 API 令牌");
        }
    }

    private byte[] readLimited(InputStream input, long max) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        long total = 0;
        int read;
        while ((read = input.read(buffer)) != -1) {
            total += read;
            if (total > max) {
                throw new ApiException(413, "APK 超过上限 " + props.getMaxUploadMb() + "MB");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }
}
