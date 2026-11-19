package com.deepseekapp.webserver.feature.agent.runtime;

import java.util.Map;

/**
 * 运行生命周期监听：用于把运行状态与事件检查点写进数据库。
 *
 * <p>放在 runtime 包只依赖接口，具体落库实现（AgentJournal）在 service 包，
 * 避免运行时状态直接绑死持久层。</p>
 */
public interface AgentRunListener {

    void onStart(AgentRun run);

    void onEvent(AgentRun run, Map<String, Object> event);

    /** @param error 失败原因（成功/取消时为 null），写进 agent_runs.error 便于排障 */
    void onFinish(AgentRun run, String status, String error);
}
