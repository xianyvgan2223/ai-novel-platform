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
    private String apiToken = "";
    private int maxUploadMb = 512;
    private int defaultPageSize = 50;
    private int maxPageSize = 500;
    private String webDeviceId = "web-console";
    private long webIdBase = 1_000_000_000L;

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
