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

    void onFinish(AgentRun run, String status);
}
