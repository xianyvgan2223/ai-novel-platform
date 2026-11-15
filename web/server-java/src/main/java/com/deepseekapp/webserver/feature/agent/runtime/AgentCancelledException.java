package com.deepseekapp.webserver.feature.agent.runtime;

/** Agent 运行被用户取消时抛出，用于从工具内部立即中止执行。 */
public class AgentCancelledException extends RuntimeException {

    public AgentCancelledException() {
        super("agent run cancelled");
    }
}
