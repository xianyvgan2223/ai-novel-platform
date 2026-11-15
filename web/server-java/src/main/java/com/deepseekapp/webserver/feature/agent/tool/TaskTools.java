package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.service.AgentTaskService;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 复杂任务工具：先列计划，再逐步回写状态。
 *
 * <p>面板收到 {@code task} 事件后渲染勾选清单，用户能直接看到「做到第几步」。</p>
 */
@Component
public class TaskTools {

    private final AgentTaskService taskService;
    private final AgentToolSupport support;

    public TaskTools(AgentTaskService taskService, AgentToolSupport support) {
        this.taskService = taskService;
        this.support = support;
    }

    @Tool(name = "plan_task",
            description = "把复杂任务拆成 3-8 个可执行步骤并登记到面板。"
                    + "遇到需要多步完成的需求（分析整本书、批量检查章节、生成后校对等）先调用它，再逐步执行。")
    public Map<String, Object> planTask(
            @ToolParam(description = "任务标题，一句话说明要达成什么") String title,
            @ToolParam(description = "步骤列表，3-8 条，每条是一个可独立完成的动作") List<String> steps,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("title", title);
        args.put("steps", steps);
        return support.traced(run, "plan_task", args, () -> {
            long sessionId = support.sessionOf(context);
            if (sessionId <= 0) {
                throw new IllegalArgumentException("当前对话没有会话，无法登记计划");
            }
            Map<String, Object> task = taskService.plan(
                    sessionId, support.deviceOf(context), run == null ? "" : run.id(), title, steps);
            if (run != null) {
                run.emit(AgentEvent.of("task", "task", task));
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("taskId", task.get("id"));
            out.put("steps", task.get("steps"));
            out.put("note", "计划已登记；每完成一步调用 update_task_step 回写状态");
            return out;
        });
    }

    @Tool(name = "update_task_step",
            description = "回写计划中某一步的状态。每完成一步就调用一次，让面板的勾选进度保持同步。")
    public Map<String, Object> updateTaskStep(
            @ToolParam(description = "plan_task 返回的 taskId") Long taskId,
            @ToolParam(description = "步骤序号，从 0 开始") Integer index,
            @ToolParam(description = "状态：pending / running / done / skipped") String status,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("taskId", taskId);
        args.put("index", index);
        args.put("status", status);
        return support.traced(run, "update_task_step", args, () -> {
            if (taskId == null) {
                throw new IllegalArgumentException("缺少 taskId");
            }
            Map<String, Object> task = taskService.updateStep(
                    taskId, index == null ? 0 : index, status == null ? "done" : status);
            if (run != null) {
                run.emit(AgentEvent.of("task", "task", task));
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("taskId", task.get("id"));
            out.put("status", task.get("status"));
            out.put("steps", task.get("steps"));
            return out;
        });
    }
}
