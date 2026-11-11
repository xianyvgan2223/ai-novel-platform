package com.deepseekapp.webserver.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * B站转写运行时配置（SESSDATA 登录态）。
 *
 * <p>存储在数据目录 bili/settings.json（网页设置界面写入，原子落盘）；
 * 读取来源链：settings.json → 环境变量 BILIBILI_SESSDATA →
 * web/server/.env（启动时已并入 System property，见 WebServerApplication）。
 * 保存时先调 nav 校验有效性，无效不落盘。</p>
 */
@Service
public class BiliSettingsService {

    private static final String ENV_KEY = "BILIBILI_SESSDATA";

    private final AppProperties props;
    private final BiliApiService biliApi;
    private final WhisperAsrService whisper;

    public BiliSettingsService(AppProperties props, BiliApiService biliApi, WhisperAsrService whisper) {
        this.props = props;
        this.biliApi = biliApi;
        this.whisper = whisper;
    }

    public boolean configured() {
        return !sessdata().isBlank();
    }

    /** 当前生效的 SESSDATA（可能为空串） */
    public String sessdata() {
        String fromFile = readSaved();
        if (!fromFile.isBlank()) {
            return fromFile;
        }
        String env = System.getenv(ENV_KEY);
        if (env != null && !env.isBlank()) {
            return env.trim();
        }
        String property = System.getProperty(ENV_KEY);
        if (property != null && !property.isBlank()) {
            return property.trim();
        }
        return "";
    }

    /** 配置概况（脱敏，不回传完整 SESSDATA） */
    public Map<String, Object> info() {
        Map<String, Object> data = new LinkedHashMap<>();
        String saved = readSaved();
        boolean fromFile = !saved.isBlank();
        String effective = sessdata();
        data.put("configured", !effective.isBlank());
        data.put("source", fromFile ? "web" : (!effective.isBlank() ? "env" : ""));
        if (fromFile) {
            data.put("preview", preview(saved));
            data.put("savedAt", readSavedAt());
        }
        data.put("pythonPath", props.getBiliPython());
        data.put("pythonOk", pythonOk());
        data.put("whisperOk", whisper.whisperReady());
        return data;
    }

    /** 保存：空串清除；非空先 nav 校验，无效抛 400 不落盘 */
    public Map<String, Object> save(String sessdata) throws IOException {
        if (sessdata == null || sessdata.isBlank()) {
            Files.deleteIfExists(settingsPath());
            Map<String, Object> cleared = new LinkedHashMap<>();
            cleared.put("configured", configured());
            cleared.put("cleared", true);
            return cleared;
        }
        Map<String, Object> check = biliApi.checkSessdata(sessdata.trim());
        if (!Boolean.TRUE.equals(check.get("valid"))) {
            throw new ApiException(400,
                    "SESSDATA 无效或已过期：请在电脑浏览器重新登录B站，按 F12 重新复制 SESSDATA 的值");
        }
        writeSaved(sessdata.trim());
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("configured", true);
        result.put("valid", true);
        result.put("uname", check.get("uname"));
        return result;
    }

    /* ── 存取 ── */

    private Path settingsPath() {
        return props.dataDirPath().resolve("bili").resolve("settings.json");
    }

    private String readSaved() {
        Path path = settingsPath();
        if (!Files.isRegularFile(path)) {
            return "";
        }
        try {
            JsonNode root = Json.MAPPER.readTree(Files.readString(path, StandardCharsets.UTF_8));
            return root.path("sessdata").asText("").trim();
        } catch (Exception e) {
            return "";
        }
    }

    private String readSavedAt() {
        try {
            JsonNode root = Json.MAPPER.readTree(Files.readString(settingsPath(), StandardCharsets.UTF_8));
            return root.path("savedAt").asText("");
        } catch (Exception e) {
            return "";
        }
    }

    /** 原子写入：先写 .tmp 再替换，避免写一半损坏 */
    private void writeSaved(String sessdata) throws IOException {
        Path path = settingsPath();
        Files.createDirectories(path.getParent());
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("sessdata", sessdata);
        data.put("savedAt", OffsetDateTime.now().toString());
        Path tmp = path.resolveSibling("settings.json.tmp");
        Files.writeString(tmp, Json.write(data), StandardCharsets.UTF_8);
        try {
            Files.move(tmp, path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            // 个别文件系统不支持原子移动，退回普通替换
            Files.move(tmp, path, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static String preview(String value) {
        if (value.length() <= 12) {
            return "***";
        }
        return value.substring(0, 6) + "***" + value.substring(value.length() - 4);
    }

    private boolean pythonOk() {
        try {
            return Files.isExecutable(Path.of(props.getBiliPython()));
        } catch (Exception e) {
            return false;
        }
    }
}
