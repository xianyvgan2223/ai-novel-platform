package com.deepseekapp.webserver.feature.agent.service;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * SSE 事件构造器：统一带 type 字段，其余字段按 key-value 顺序追加。
 *
 * <p>事件协议见 .trae/documents/web-agent-panel.md。前端按 type 分发，
 * 未知类型会原样透传给面板，所以新增事件不需要改前端解析逻辑。</p>
 */
public final class AgentEvent {

    private AgentEvent() {
    }

    public static Map<String, Object> of(String type, Object... keyValues) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", type);
        for (int i = 0; i + 1 < keyValues.length; i += 2) {
            event.put(String.valueOf(keyValues[i]), keyValues[i + 1]);
        }
        return event;
    }
}
