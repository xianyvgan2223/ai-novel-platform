package com.deepseekapp.webserver.sync;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.db.DatabaseManager;
import com.deepseekapp.webserver.db.SchemaCatalog;
import com.deepseekapp.webserver.sync.SyncStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.Api;
import com.deepseekapp.webserver.web.ApiException;
import com.deepseekapp.webserver.web.RequestDevice;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 增量同步接口（手机 App ↔ Web） */
@RestController
@RequestMapping("/api/sync")
public class SyncController {

    private final AppProperties props;
    private final SyncStore syncStore;
    private final SchemaCatalog schema;
    private final DatabaseManager databaseManager;

    public SyncController(AppProperties props, SyncStore syncStore, SchemaCatalog schema,
                          DatabaseManager databaseManager) {
        this.props = props;
        this.syncStore = syncStore;
        this.schema = schema;
        this.databaseManager = databaseManager;
    }

    @GetMapping("/status")
    public Map<String, Object> status(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        boolean exists = syncStore.deviceExists(deviceId);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", deviceId);
        data.put("deviceSeq", exists ? syncStore.currentSeq(deviceId) : 0L);
        data.put("revision", syncStore.syncRevision());
        data.put("serverTime", System.currentTimeMillis());
        data.put("devices", syncStore.listDevices(false));
        data.put("databases", databasesSummary());
        return Api.ok(data);
    }

    @GetMapping("/devices")
    public Map<String, Object> devices(HttpServletRequest request) {
        List<Map<String, Object>> devices = syncStore.listDevices(true);
        long totalRows = 0;
        for (Map<String, Object> device : devices) {
            totalRows += SyncStore.longValue(device.get("rowsOwned"), 0);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("activeDeviceId", RequestDevice.deviceId(request, props));
        data.put("devices", devices);
        data.put("totalRows", totalRows);
        data.put("revision", syncStore.syncRevision());
        data.put("legacyFiles", databaseManager.legacyFiles());
        return Api.ok(data);
    }

    @PostMapping("/devices")
    public Map<String, Object> registerDevice(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> source = body == null ? Map.of() : body;
        Object rawId = source.get("deviceId");
        if (rawId == null || String.valueOf(rawId).isEmpty()) {
            throw new ApiException(400, "缺少 deviceId");
        }
        long idBase = SyncStore.longValue(source.get("idBase"), 0);
        Map<String, Object> device = syncStore.registerDevice(
                String.valueOf(rawId),
                source.get("name") == null ? "" : String.valueOf(source.get("name")),
                source.get("platform") == null ? "" : String.valueOf(source.get("platform")),
                idBase <= 0 ? null : idBase);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", device.get("device_id"));
        data.put("name", device.get("name"));
        data.put("scopeDir", device.get("scope_dir"));
        return Api.ok(data);
    }

    @DeleteMapping("/devices/{deviceId}")
    public Map<String, Object> removeDevice(@PathVariable String deviceId) {
        if (!syncStore.deviceExists(deviceId)) {
            throw new ApiException(404, "设备不存在：" + deviceId);
        }
        if (deviceId.equals(props.getWebDeviceId())) {
            throw new ApiException(400, "不能删除 Web 控制台自己的槽位");
        }
        Map<String, Object> removed = syncStore.removeDevice(deviceId);
        boolean purgedFiles = databaseManager.dropDeviceScope(deviceId);
        Map<String, Object> data = new LinkedHashMap<>(removed);
        data.put("purgedFiles", purgedFiles);
        return Api.ok(data);
    }

    @PostMapping("/request")
    public Map<String, Object> request(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> source = body == null ? Map.of() : body;
        Object rawTarget = source.get("targetDevice");
        String target = rawTarget == null || String.valueOf(rawTarget).isEmpty()
                ? "" : String.valueOf(rawTarget);
        if (!target.isEmpty() && !syncStore.deviceExists(target)) {
            throw new ApiException(404,
                    "设备不存在：" + target + "。请让这台手机先同步一次，它才会出现在设备列表里。");
        }
        return Api.ok(syncStore.createSyncRequest(target, props.getWebDeviceId()));
    }

    @GetMapping("/pending")
    public Map<String, Object> pending(HttpServletRequest request) {
        String deviceId = request.getParameter("deviceId");
        // 只查看、不领取：手机端要先弹窗询问用户是否同意
        return Api.ok(syncStore.peekPendingRequest(deviceId == null ? "" : deviceId));
    }

    /** 手机用户同意后领取请求（领取才会变成 claimed） */
    @PostMapping("/request/{id}/claim")
    public Map<String, Object> claim(@PathVariable long id, HttpServletRequest request) {
        String deviceId = request.getParameter("deviceId");
        Map<String, Object> claimed = syncStore.claimSyncRequest(id, deviceId == null ? "" : deviceId);
        if (claimed == null) {
            throw new ApiException(404, "同步请求不存在，或不属于这台设备");
        }
        return Api.ok(claimed);
    }

    @GetMapping("/request/{id}")
    public Map<String, Object> getRequest(@PathVariable long id) {
        Map<String, Object> request = syncStore.getSyncRequest(id);
        if (request == null) {
            throw new ApiException(404, "同步请求不存在");
        }
        return Api.ok(request);
    }

    @PostMapping("/progress")
    public Map<String, Object> progress(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> source = body == null ? Map.of() : body;
        Object rawId = source.get("requestId");
        if (rawId == null) {
            throw new ApiException(400, "缺少 requestId");
        }
        long id = SyncStore.longValue(rawId, 0);
        String message = source.get("message") == null ? "" : String.valueOf(source.get("message"));
        Long current = source.get("current") == null ? null : SyncStore.longValue(source.get("current"), 0);
        Long total = source.get("total") == null ? null : SyncStore.longValue(source.get("total"), 0);
        Map<String, Object> request = syncStore.updateSyncProgress(id, message, current, total);
        if (request == null) {
            throw new ApiException(404, "同步请求不存在");
        }
        return Api.ok(request);
    }

    @PostMapping("/request/{id}/complete")
    public Map<String, Object> complete(@PathVariable long id,
                                        @RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> source = body == null ? Map.of() : body;
        String status = source.get("status") == null ? null : String.valueOf(source.get("status"));
        String result = source.get("result") == null ? "" : String.valueOf(source.get("result"));
        Map<String, Object> request = syncStore.completeSyncRequest(id, status, result);
        if (request == null) {
            throw new ApiException(404, "同步请求不存在");
        }
        return Api.ok(request);
    }

    @GetMapping("/requests")
    public Map<String, Object> requests(HttpServletRequest request) {
        long limit = parseLong(request.getParameter("limit"), 10);
        if (limit == 0) {
            limit = 10;
        }
        limit = Math.min(Math.max(1, limit), 100);
        return Api.ok(syncStore.listSyncRequests(limit));
    }

    @GetMapping("/overview")
    public Map<String, Object> overview(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        boolean exists = syncStore.deviceExists(deviceId);
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", deviceId);
        data.put("deviceExists", exists);
        data.put("deviceSeq", exists ? syncStore.currentSeq(deviceId) : 0L);
        data.put("revision", syncStore.syncRevision());
        data.put("devices", syncStore.listDevices(true));
        data.put("recentConflicts", syncStore.listConflicts(10, false, deviceId));
        data.put("allConflicts", syncStore.listConflicts(200, false, null).size());
        data.put("stats", exists ? syncStore.statistics(deviceId) : null);
        return Api.ok(data);
    }

    @GetMapping("/pull")
    public Map<String, Object> pull(HttpServletRequest request) {
        long since = Math.max(0, parseLong(request.getParameter("since"), 0));
        long rawLimit = parseLong(request.getParameter("limit"), 500);
        int limit = (int) Math.min(Math.max(1, rawLimit == 0 ? 500 : rawLimit), 2000);
        String deviceId = request.getParameter("deviceId");
        if (deviceId == null || deviceId.isEmpty()) {
            throw new ApiException(400, "缺少 deviceId（拉取必须指明是哪台设备）");
        }
        String dbKey = request.getParameter("db");
        if (dbKey == null || !schema.hasDatabase(dbKey)) {
            dbKey = null;
        }
        syncStore.registerDevice(deviceId, "", "", null);
        Map<String, Object> data = new LinkedHashMap<>(syncStore.pullChanges(deviceId, since, limit, dbKey));
        data.put("deviceId", deviceId);
        return Api.ok(data);
    }

    @PostMapping("/push")
    public Map<String, Object> push(@RequestBody(required = false) Map<String, Object> body) {
        Map<String, Object> source = body == null ? Map.of() : body;
        Object rawDeviceId = source.get("deviceId");
        if (rawDeviceId == null || String.valueOf(rawDeviceId).isEmpty()) {
            throw new ApiException(400, "缺少 deviceId");
        }
        Object rawChanges = source.get("changes");
        if (!(rawChanges instanceof List<?> list)) {
            throw new ApiException(400, "changes 必须是数组");
        }
        String strategy = source.get("strategy") == null ? "server-wins" : String.valueOf(source.get("strategy"));
        if (!List.of("server-wins", "client-wins", "last-write-wins").contains(strategy)) {
            throw new ApiException(400, "strategy 只能是 server-wins / client-wins / last-write-wins");
        }
        List<Map<String, Object>> changes = new ArrayList<>();
        for (Object item : list) {
            Map<String, Object> change = Json.asMap(item);
            if (change == null) {
                throw new ApiException(400, "changes 中包含非对象元素");
            }
            changes.add(change);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", String.valueOf(rawDeviceId));
        data.putAll(syncStore.pushChanges(String.valueOf(rawDeviceId), changes, strategy));
        return Api.ok(data);
    }

    @GetMapping("/conflicts")
    public Map<String, Object> conflicts(HttpServletRequest request) {
        String deviceId = request.getParameter("device");
        long limit = parseLong(request.getParameter("limit"), 200);
        limit = Math.min(Math.max(1, limit == 0 ? 200 : limit), 1000);
        boolean unresolvedOnly = "1".equals(request.getParameter("unresolved"));
        return Api.ok(syncStore.listConflicts(limit, unresolvedOnly,
                deviceId == null || deviceId.isEmpty() ? null : deviceId));
    }

    @PostMapping("/prune")
    public Map<String, Object> prune(HttpServletRequest request) {
        String deviceId = RequestDevice.deviceId(request, props);
        if (!syncStore.deviceExists(deviceId)) {
            throw new ApiException(404, "设备不存在：" + deviceId);
        }
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", deviceId);
        data.putAll(syncStore.pruneChangeLog(deviceId));
        return Api.ok(data);
    }

    @GetMapping("/self")
    public Map<String, Object> self() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("deviceId", props.getWebDeviceId());
        data.put("idBase", props.getWebIdBase());
        return Api.ok(data);
    }

    private List<Map<String, Object>> databasesSummary() {
        List<Map<String, Object>> out = new ArrayList<>();
        for (SchemaCatalog.DatabaseDef def : schema.databases().values()) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("key", def.key());
            item.put("file", def.file());
            item.put("appVersion", def.appVersion());
            out.add(item);
        }
        return out;
    }

    private long parseLong(String value, long fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
