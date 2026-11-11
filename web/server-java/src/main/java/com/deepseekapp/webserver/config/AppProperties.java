package com.deepseekapp.webserver.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.nio.file.Path;

@Component
@ConfigurationProperties(prefix = "app")
public class AppProperties {

    private String dataDir = "../server/data";
    private String webDist = "../app/dist";
    private String appUpdateDir = "";
    private boolean usbAuto = true;
    private String apiToken = "";
    private int maxUploadMb = 512;
    private int defaultPageSize = 50;
    private int maxPageSize = 500;
    private String webDeviceId = "web-console";
    private long webIdBase = 1_000_000_000L;

    /** AI 写作：密钥可来自环境变量、application.yml，或 web/server/.env（见 WritingService） */
    private String deepseekApiKey = "";
    private String deepseekBaseUrl = "https://api.deepseek.com";
    private String deepseekModel = "deepseek-chat";
    private long aiTimeoutMs = 180000;

    /** B站视频转写：faster-whisper 用的 Python 解释器路径 */
    private String biliPython = "D:\\tools\\python3.10.10\\python.exe";
    /** faster-whisper 模型（tiny/base/small/medium/large-v3） */
    private String biliWhisperModel = "small";
    /** 超过该分钟数的视频拒绝本地转写（保护 CPU 与磁盘） */
    private int biliMaxVideoMinutes = 180;

    public String getDataDir() {
        return dataDir;
    }

    public void setDataDir(String dataDir) {
        this.dataDir = dataDir;
    }

    public String getWebDist() {
        return webDist;
    }

    public void setWebDist(String webDist) {
        this.webDist = webDist;
    }

    public String getApiToken() {
        return apiToken;
    }

    public void setApiToken(String apiToken) {
        this.apiToken = apiToken;
    }

    public String getAppUpdateDir() {
        return appUpdateDir;
    }

    public void setAppUpdateDir(String appUpdateDir) {
        this.appUpdateDir = appUpdateDir;
    }

    public boolean isUsbAuto() {
        return usbAuto;
    }

    public void setUsbAuto(boolean usbAuto) {
        this.usbAuto = usbAuto;
    }

    /** APK 发布目录；留空时跟随数据目录 */
    public Path appUpdateDirPath() {
        if (appUpdateDir == null || appUpdateDir.isBlank()) {
            return dataDirPath().resolve("app-update");
        }
        return resolve(appUpdateDir);
    }

    public int getMaxUploadMb() {
        return maxUploadMb;
    }

    public void setMaxUploadMb(int maxUploadMb) {
        this.maxUploadMb = maxUploadMb;
    }

    public int getDefaultPageSize() {
        return defaultPageSize;
    }

    public void setDefaultPageSize(int defaultPageSize) {
        this.defaultPageSize = defaultPageSize;
    }

    public int getMaxPageSize() {
        return maxPageSize;
    }

    public void setMaxPageSize(int maxPageSize) {
        this.maxPageSize = maxPageSize;
    }

    public String getWebDeviceId() {
        return webDeviceId;
    }

    public void setWebDeviceId(String webDeviceId) {
        this.webDeviceId = webDeviceId;
    }

    public long getWebIdBase() {
        return webIdBase;
    }

    public void setWebIdBase(long webIdBase) {
        this.webIdBase = webIdBase;
    }

    public String getDeepseekApiKey() {
        return deepseekApiKey;
    }

    public void setDeepseekApiKey(String deepseekApiKey) {
        this.deepseekApiKey = deepseekApiKey;
    }

    public String getDeepseekBaseUrl() {
        return deepseekBaseUrl;
    }

    public void setDeepseekBaseUrl(String deepseekBaseUrl) {
        this.deepseekBaseUrl = deepseekBaseUrl;
    }

    public String getDeepseekModel() {
        return deepseekModel;
    }

    public void setDeepseekModel(String deepseekModel) {
        this.deepseekModel = deepseekModel;
    }

    public long getAiTimeoutMs() {
        return aiTimeoutMs;
    }

    public void setAiTimeoutMs(long aiTimeoutMs) {
        this.aiTimeoutMs = aiTimeoutMs;
    }

    public String getBiliPython() {
        return biliPython;
    }

    public void setBiliPython(String biliPython) {
        this.biliPython = biliPython;
    }

    public String getBiliWhisperModel() {
        return biliWhisperModel;
    }

    public void setBiliWhisperModel(String biliWhisperModel) {
        this.biliWhisperModel = biliWhisperModel;
    }

    public int getBiliMaxVideoMinutes() {
        return biliMaxVideoMinutes;
    }

    public void setBiliMaxVideoMinutes(int biliMaxVideoMinutes) {
        this.biliMaxVideoMinutes = biliMaxVideoMinutes;
    }

    public Path dataDirPath() {
        return resolve(dataDir);
    }

    public Path webDistPath() {
        return resolve(webDist);
    }

    public long maxUploadBytes() {
        return (long) maxUploadMb * 1024L * 1024L;
    }

    private Path resolve(String value) {
        Path path = Path.of(value);
        if (path.isAbsolute()) {
            return path.normalize();
        }
        return Path.of(System.getProperty("user.dir")).resolve(path).normalize();
    }
}
