package com.deepseekapp.webserver.feature.agent.runtime;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 运行时事件缓冲与结束收尾。 */
class AgentRunTest {

    @Test
    void markFinishedSettlesRunningToolAndWaitingAsk() {
        List<String> finished = new ArrayList<>();
        AgentRunListener listener = new AgentRunListener() {
            @Override
            public void onStart(AgentRun run) {
            }

            @Override
            public void onEvent(AgentRun run, Map<String, Object> event) {
            }

            @Override
            public void onFinish(AgentRun run, String status, String error) {
                finished.add(status + ":" + error);
            }
        };
        AgentRun run = new AgentRun("r1", "device-1", 1L, listener, 30, 1000);

        run.emit(AgentEvent.of("tool_call", "id", "c1", "name", "list_data", "args", Map.of()));
        run.emit(AgentEvent.of("ask", "id", "a1", "question", "选哪个", "options", List.of("A")));
        run.markFinished("error", "boom");

        assertEquals(List.of("error:boom"), finished);
        assertTrue(run.finished());
        String parts = run.partsJson();
        // 工具不能永远「执行中」，提问不能永远「等待」
        assertFalse(parts.contains("\"status\":\"running\""));
        assertFalse(parts.contains("\"status\":\"waiting\""));
        assertTrue(parts.contains("运行已结束，未收到工具返回"));
    }

    @Test
    void replayOnlyKeepsLatestEvents() {
        AgentRun run = new AgentRun("r2", "device-1", 1L, null, 30, 100);
        for (int i = 0; i < 150; i++) {
            run.emit(AgentEvent.of("delta", "text", "x"));
        }
        run.markFinished("done", null);

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        run.attach(out, 0);
        String sse = out.toString(StandardCharsets.UTF_8);

        assertTrue(sse.contains("\"seq\":150"));
        assertTrue(sse.contains("\"seq\":51"));
        assertFalse(sse.contains("\"seq\":50,"));
    }
}
