package com.deepseekapp.webserver.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.service.Exporter;
import com.deepseekapp.webserver.service.Importer;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.StreamingResponseBody;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** .db 文件导入 / 导出（作用于当前选中的设备槽位） */
@RestController
@RequestMapping("/api/transfer")
public class TransferController {

    private final AppProperties props;
    private final SchemaCatalog schema;
    private final Importer importer;
    private final Exporter exporter;

    public TransferController(AppProperties props, SchemaCatalog schema, Importer importer, Exporter exporter) {
        this.props = props;
        this.schema = schema;
        this.importer = importer;
        this.exporter = exporter;
    }

    @PostMapping("/import")
    public Map<String, Object> importDatabase(@RequestParam(defaultValue = "deepseek") String db,
                                              @RequestParam(defaultValue = "merge") String mode,
                                              @RequestParam(required = false) String originDevice,
                                              HttpServletRequest request) throws IOException {
        if (!schema.hasDatabase(db)) {
            throw new ApiException(400, "db 只能是 deepseek 或 novel");
        }
        if (!List.of("merge", "replace").contains(mode)) {
            throw new ApiException(400, "mode 只能是 merge 或 replace");
        }
        long max = props.maxUploadBytes();
        if (request.getContentLengthLong() > max) {
            throw new ApiException(413, "文件超过上限 " + props.getMaxUploadMb() + "MB");
        }
        byte[] body = readLimited(request.getInputStream(), max);
        if (body.length == 0) {
            throw new ApiException(400, "请求体为空，请以 application/octet-stream 上传 .db 文件");
        }

        String deviceId = RequestDevice.deviceId(request, props);
        String origin = originDevice == null || originDevice.isEmpty()
                ? props.getWebDeviceId()
                : originDevice;
        Map<String, Object> report = importer.importAppDatabase(db, body, mode, deviceId, origin);
        report.put("targetDevice", deviceId);
        return Api.ok(report);
    }

    @GetMapping("/export/{db}")
    public ResponseEntity<StreamingResponseBody> exportDatabase(@PathVariable String db,
                                                                HttpServletRequest request) {
        if (!schema.hasDatabase(db)) {
            throw new ApiException(400, "未知的数据库：" + db);
        }
        String deviceId = RequestDevice.deviceId(request, props);
        boolean sanitize = !"0".equals(request.getParameter("sanitize"));
        Exporter.ExportInfo info = exporter.exportDatabase(db, sanitize, deviceId);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.parseMediaType("application/vnd.sqlite3"));
        headers.set("X-Export-File", URLEncoder.encode(info.fileName(), StandardCharsets.UTF_8));
        headers.set("X-Export-Device", URLEncoder.encode(deviceId, StandardCharsets.UTF_8));
        headers.set(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + info.fileName() + "\"");
        headers.setContentLength(info.bytes());

        StreamingResponseBody body = outputStream -> {
            try (InputStream in = Files.newInputStream(info.file())) {
                in.transferTo(outputStream);
            } finally {
                Exporter.deleteQuietly(info.file());
            }
        };
        return new ResponseEntity<>(body, headers, HttpStatus.OK);
    }

    @GetMapping("/export-info")
    public Map<String, Object> exportInfo(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        Map<String, Object> databases = new LinkedHashMap<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Exporter.ExportInfo info = exporter.exportDatabase(def.key(), true, deviceId);
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("fileName", info.fileName());
            item.put("bytes", info.bytes());
            item.put("sanitized", info.sanitized());
            item.put("appVersion", def.appVersion());
            databases.put(def.key(), item);
            Exporter.deleteQuietly(info.file());
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", deviceId);
        data.put("databases", databases);
        return Api.ok(data);
    }

    private byte[] readLimited(InputStream input, long max) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[64 * 1024];
        long total = 0;
        int read;
        while ((read = input.read(buffer)) != -1) {
            total += read;
            if (total > max) {
                throw new ApiException(413, "文件超过上限 " + props.getMaxUploadMb() + "MB");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }
}
