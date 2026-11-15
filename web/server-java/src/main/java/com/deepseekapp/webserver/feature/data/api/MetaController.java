package com.deepseekapp.webserver.feature.data.api;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.config.ServerInfo;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.util.NetworkUtil;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 健康检查、表目录、数据概览、连接地址 */
@RestController
@RequestMapping("/api")
public class MetaController {

    private final AppProperties props;
    private final ServerInfo serverInfo;
    private final SyncStore syncStore;
    private final SchemaCatalog schema;
    private final DatabaseManager databaseManager;
    private final NetworkUtil networkUtil;

    public MetaController(AppProperties props, ServerInfo serverInfo, SyncStore syncStore,
                          SchemaCatalog schema, DatabaseManager databaseManager, NetworkUtil networkUtil) {
        this.props = props;
        this.serverInfo = serverInfo;
        this.syncStore = syncStore;
        this.schema = schema;
        this.databaseManager = databaseManager;
        this.networkUtil = networkUtil;
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        List<Map<String, Object>> devices = syncStore.listDevices(false);
        List<Map<String, Object>> deviceSummaries = new ArrayList<>();
        for (Map<String, Object> d : devices) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("deviceId", d.get("deviceId"));
            item.put("name", d.get("name"));
            item.put("lastSeenAt", d.get("lastSeenAt"));
            deviceSummaries.add(item);
        }

        Map<String, Object> data = new LinkedHashMap<>();
        data.put("service", "deepseekapp-web-sync");
        data.put("apiVersion", 2);
        data.put("serverTime", System.currentTimeMillis());
        data.put("uptimeSeconds", Math.round(ManagementFactory.getRuntimeMXBean().getUptime() / 1000.0));
        data.put("node", System.getProperty("java.version"));
        data.put("runtime", "java");
        data.put("dataDir", props.dataDirPath().toString());
        data.put("authRequired", props.getApiToken() != null && !props.getApiToken().isEmpty());
        data.put("isolation", "per-device");
        data.put("devicesRoot", "devices/");
        data.put("deviceCount", devices.size());
        data.put("devices", deviceSummaries);
        data.put("legacyFiles", databaseManager.legacyFiles().stream()
                .map(DatabaseManager.LegacyFile::file).toList());
        data.put("databases", databasesSummary());
        return Api.ok(data);
    }

    @GetMapping("/net")
    public Map<String, Object> net() {
        int port = serverInfo.port();
        List<Map<String, Object>> lan = new ArrayList<>();
        for (NetworkUtil.LanAddress address : networkUtil.lanAddresses()) {
            if (address.isVirtual()) {
                continue;
            }
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("name", address.name());
            item.put("address", address.address());
            lan.add(item);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("port", port);
        data.put("host", serverInfo.host());
        data.put("usbUrl", "http://127.0.0.1:" + port);
        data.put("candidates", networkUtil.connectionCandidates(port));
        data.put("lanAddresses", lan);
        data.put("hotspotHint", NetworkUtil.hotspotHint());
        return Api.ok(data);
    }

    @GetMapping("/catalog")
    public Map<String, Object> catalog() {
        List<Map<String, Object>> databases = new ArrayList<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("key", def.key());
            item.put("label", def.label());
            item.put("file", def.file());
            item.put("appVersion", def.appVersion());
            item.put("tables", schema.tableCatalog(def.key()));
            databases.add(item);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("databases", databases);
        return Api.ok(data);
    }

    @GetMapping("/stats")
    public Map<String, Object> stats(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        boolean exists = syncStore.deviceExists(deviceId);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", deviceId);
        data.put("deviceExists", exists);
        data.put("deviceSeq", exists ? syncStore.currentSeq(deviceId) : 0L);
        data.put("revision", syncStore.syncRevision());
        data.put("devices", syncStore.listDevices(true));
        data.put("databases", exists ? syncStore.statistics(deviceId) : null);
        return Api.ok(data);
    }

    private List<Map<String, Object>> databasesSummary() {
        List<Map<String, Object>> out = new ArrayList<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("key", def.key());
            item.put("file", def.file());
            item.put("appVersion", def.appVersion());
            item.put("label", def.label());
            out.add(item);
        }
        return out;
    }
}
