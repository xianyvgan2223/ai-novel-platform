package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.data.AgentStore;
import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 复杂任务计划：Agent 先列步骤，再逐步执行并把每步状态写回。
 * 面板据此渲染勾选清单。
 */
@Service
public class AgentTaskService {

    private static final int MAX_STEPS = 12;
    private static final List<String> STATUSES = List.of("pending", "running", "done", "skipped");

    private final AgentStore store;

    public AgentTaskService(AgentStore store) {
        this.store = store;
    }

    public Map<String, Object> plan(long sessionId, String deviceId, String runId,
                                    String title, List<String> steps) {
        List<Map<String, Object>> normalized = new ArrayList<>();
        for (String step : steps == null ? List.<String>of() : steps) {
            String text = step == null ? "" : step.trim();
            if (text.isEmpty()) {
                continue;
            }
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("text", text);
            item.put("status", "pending");
            normalized.add(item);
            if (normalized.size() >= MAX_STEPS) {
                break;
            }
        }
        if (normalized.isEmpty()) {
            throw new ApiException(400, "计划至少需要一个步骤");
        }

        String taskTitle = title == null || title.isBlank() ? "任务计划" : title.trim();
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("sessionId", sessionId);
        row.put("deviceId", deviceId);
        row.put("runId", runId == null ? "" : runId);
        row.put("title", taskTitle.length() > 180 ? taskTitle.substring(0, 180) : taskTitle);
        row.put("steps", Json.write(normalized));
        row.put("now", System.currentTimeMillis());
        store.insertTask(row);
        return view(store.findTask(((Number) row.get("id")).longValue()));
    }

    public Map<String, Object> updateStep(long taskId, int index, String status) {
        Map<String, Object> row = store.findTask(taskId);
        if (row == null) {
            throw new ApiException(404, "任务不存在：" + taskId);
        }
        List<Map<String, Object>> steps = parseSteps(row.get("steps"));
        if (index < 0 || index >= steps.size()) {
            throw new ApiException(400, "步骤序号越界：" + index);
        }
        String normalized = STATUSES.contains(status) ? status : "done";
        steps.get(index).put("status", normalized);
        boolean finished = steps.stream()
                .allMatch(step -> "done".equals(step.get("status")) || "skipped".equals(step.get("status")));
        store.updateTask(taskId, Json.write(steps), finished ? "done" : "running", System.currentTimeMillis());
        return view(store.findTask(taskId));
    }

    public List<Map<String, Object>> list(long sessionId) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map<String, Object> row : store.listTasks(sessionId)) {
            out.add(view(row));
        }
        return out;
    }

    public Map<String, Object> view(Map<String, Object> row) {
        if (row == null) {
            return null;
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("id", row.get("id"));
        out.put("title", row.get("title"));
        out.put("status", row.get("status"));
        out.put("runId", row.get("run_id"));
        out.put("steps", parseSteps(row.get("steps")));
        out.put("createdAt", row.get("created_at"));
        out.put("updatedAt", row.get("updated_at"));
        return out;
    }

    @SuppressWarnings("unchecked")
    private static List<Map<String, Object>> parseSteps(Object raw) {
        if (raw == null || String.valueOf(raw).isBlank()) {
            return List.of();
        }
        try {
            Object parsed = Json.parse(String.valueOf(raw));
            return parsed instanceof List<?> list ? (List<Map<String, Object>>) list : List.of();
        } catch (RuntimeException e) {
            return List.of();
        }
    }
}
