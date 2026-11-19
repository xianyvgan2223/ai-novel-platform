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

    /** 启动时是否把 data/devices 下的旧 SQLite 数据迁移到 MySQL（只跑一次） */
    private boolean migrateSqlite = true;

    /** AI 写作：密钥可来自环境变量、application.yml，或 web/server/.env（见 WritingService） */
    private String deepseekApiKey = "";
    private String deepseekBaseUrl = "https://api.deepseek.com";
    private String deepseekModel = "deepseek-chat";
    private long aiTimeoutMs = 180000;

    /** ── Agent 面板运行时限制（都可被 application.yml 覆盖）── */
    /** 单次对话最多几轮工具调用，超过后强制一次无工具的收尾回答 */
    private int agentMaxRounds = 8;
    /** 单次模型请求超时（秒） */
    private int agentLlmTimeoutSeconds = 180;
    /** 浏览器断开后等待重连的时间（秒），超时才取消运行 */
    private int agentDetachGraceSeconds = 120;
    /** 单次运行保留的事件条数上限（用于断线重放） */
    private int agentMaxEvents = 2000;
    /** 同时运行的 Agent 数量上限 */
    private int agentMaxConcurrentRuns = 8;
    /** 历史上下文最多几条消息（压缩后只加载摘要之后的消息） */
    private int agentHistoryMessages = 2000;
    /** 历史上下文总字符预算（仅作兜底，真正上限由 token 压缩控制） */
    private int agentHistoryMaxChars = 1_000_000;
    /** 默认上下文窗口（DeepSeek flash / v4-pro 都是 1M）；面板里可单独覆盖 */
    private int agentContextWindow = 1_000_000;
    /** 压缩触发阈值：min(W × ratio, W − 输出预留 − headroom) */
    private double agentContextThresholdRatio = 0.8;
    /** 压缩前给输出和工具留的余量（tokens） */
    private int agentHeadroomTokens = 65_536;
    /** 压缩后逐字保留的近期历史，占 W − 输出预留 的比例 */
    private double agentRetainRatio = 0.16;

    /** B站视频转写：faster-whisper 用的 Python 解释器路径 */
    private String biliPython = "D:\\tools\\python3.10.10\\python.exe";
    /** faster-whisper 模型（tiny/base/small/medium/large-v3） */
    private String biliWhisperModel = "small";
    /** 超过该分钟数的视频拒绝本地转写（保护 CPU 与磁盘） */
    private int biliMaxVideoMinutes = 180;

    /** ── RAG 情节素材库 ── */
    private String ragEsUrl = "http://127.0.0.1:9211";
    private String ragEsIndex = "novel_rag_scenes";
    private String dashscopeApiKey = "";
    private String dashscopeBaseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1";
    private String embeddingModel = "qwen3.7-text-embedding-flash";
    private int embeddingDim = 1024;
    private int ragChunkChars = 8000;
    /** 单个情节弧窗口的目标字符数（按章节组窗口） */
    private int ragWindowChars = 12000;
    /** 相邻窗口重叠字符数，保证跨窗口情节至少完整出现在一个窗口 */
    private int ragOverlapChars = 1500;
    /** 并行提炼 DeepSeek 的窗口数 */
    private int ragExtractConcurrency = 4;

    public String getRagEsUrl() {
        return ragEsUrl;
    }

    public void setRagEsUrl(String ragEsUrl) {
        this.ragEsUrl = ragEsUrl;
    }

    public String getRagEsIndex() {
        return ragEsIndex;
    }

    public void setRagEsIndex(String ragEsIndex) {
        this.ragEsIndex = ragEsIndex;
    }

    public String getDashscopeApiKey() {
        return dashscopeApiKey;
    }

    public void setDashscopeApiKey(String dashscopeApiKey) {
        this.dashscopeApiKey = dashscopeApiKey;
    }

    public String getDashscopeBaseUrl() {
        return dashscopeBaseUrl;
    }

    public void setDashscopeBaseUrl(String dashscopeBaseUrl) {
        this.dashscopeBaseUrl = dashscopeBaseUrl;
    }

    public String getEmbeddingModel() {
        return embeddingModel;
    }

    public void setEmbeddingModel(String embeddingModel) {
        this.embeddingModel = embeddingModel;
    }

    public int getEmbeddingDim() {
        return embeddingDim;
    }

    public void setEmbeddingDim(int embeddingDim) {
        this.embeddingDim = embeddingDim;
    }

    public int getRagChunkChars() {
        return ragChunkChars;
    }

    public void setRagChunkChars(int ragChunkChars) {
        this.ragChunkChars = ragChunkChars;
    }

    public int getRagWindowChars() {
        return ragWindowChars;
    }

    public void setRagWindowChars(int ragWindowChars) {
        this.ragWindowChars = ragWindowChars;
    }

    public int getRagOverlapChars() {
        return ragOverlapChars;
    }

    public void setRagOverlapChars(int ragOverlapChars) {
        this.ragOverlapChars = ragOverlapChars;
    }

    public int getRagExtractConcurrency() {
        return ragExtractConcurrency;
    }

    public void setRagExtractConcurrency(int ragExtractConcurrency) {
        this.ragExtractConcurrency = ragExtractConcurrency;
    }

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

    public boolean isMigrateSqlite() {
        return migrateSqlite;
    }

    public void setMigrateSqlite(boolean migrateSqlite) {
        this.migrateSqlite = migrateSqlite;
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

    public int getAgentMaxRounds() {
        return agentMaxRounds;
    }

    public void setAgentMaxRounds(int agentMaxRounds) {
        this.agentMaxRounds = agentMaxRounds;
    }

    public int getAgentLlmTimeoutSeconds() {
        return agentLlmTimeoutSeconds;
    }

    public void setAgentLlmTimeoutSeconds(int agentLlmTimeoutSeconds) {
        this.agentLlmTimeoutSeconds = agentLlmTimeoutSeconds;
    }

    public int getAgentDetachGraceSeconds() {
        return agentDetachGraceSeconds;
    }

    public void setAgentDetachGraceSeconds(int agentDetachGraceSeconds) {
        this.agentDetachGraceSeconds = agentDetachGraceSeconds;
    }

    public int getAgentMaxEvents() {
        return agentMaxEvents;
    }

    public void setAgentMaxEvents(int agentMaxEvents) {
        this.agentMaxEvents = agentMaxEvents;
    }

    public int getAgentMaxConcurrentRuns() {
        return agentMaxConcurrentRuns;
    }

    public void setAgentMaxConcurrentRuns(int agentMaxConcurrentRuns) {
        this.agentMaxConcurrentRuns = agentMaxConcurrentRuns;
    }

    public int getAgentHistoryMessages() {
        return agentHistoryMessages;
    }

    public void setAgentHistoryMessages(int agentHistoryMessages) {
        this.agentHistoryMessages = agentHistoryMessages;
    }

    public int getAgentHistoryMaxChars() {
        return agentHistoryMaxChars;
    }

    public void setAgentHistoryMaxChars(int agentHistoryMaxChars) {
        this.agentHistoryMaxChars = agentHistoryMaxChars;
    }

    public int getAgentContextWindow() {
        return agentContextWindow;
    }

    public void setAgentContextWindow(int agentContextWindow) {
        this.agentContextWindow = agentContextWindow;
    }

    public double getAgentContextThresholdRatio() {
        return agentContextThresholdRatio;
    }

    public void setAgentContextThresholdRatio(double agentContextThresholdRatio) {
        this.agentContextThresholdRatio = agentContextThresholdRatio;
    }

    public int getAgentHeadroomTokens() {
        return agentHeadroomTokens;
    }

    public void setAgentHeadroomTokens(int agentHeadroomTokens) {
        this.agentHeadroomTokens = agentHeadroomTokens;
    }

    public double getAgentRetainRatio() {
        return agentRetainRatio;
    }

    public void setAgentRetainRatio(double agentRetainRatio) {
        this.agentRetainRatio = agentRetainRatio;
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
