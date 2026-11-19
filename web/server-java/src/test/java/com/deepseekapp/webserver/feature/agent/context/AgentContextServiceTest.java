package com.deepseekapp.webserver.feature.agent.context;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.feature.agent.service.AgentConversationService;
import com.deepseekapp.webserver.feature.agent.service.AgentLlmClient;
import com.deepseekapp.webserver.feature.agent.service.AgentOptions;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 自动压缩：选段、摘要、落库与事件。 */
class AgentContextServiceTest {

    private final AgentConversationService conversations = mock(AgentConversationService.class);
    private final AgentLlmClient llm = mock(AgentLlmClient.class);
    private final AgentContextService service =
            new AgentContextService(new AppProperties(), conversations, llm);

    private static AgentOptions options(int contextWindow) {
        return new AgentOptions("sk-test", "https://api.deepseek.com", "deepseek-flash",
                1.0, 256, null, null, null, "", contextWindow, false, 5, false, true, true, "high");
    }

    private static List<AgentHistory.Message> longHistory(int count) {
        List<AgentHistory.Message> messages = new ArrayList<>();
        for (int i = 1; i <= count; i++) {
            messages.add(new AgentHistory.Message(i, i % 2 == 1 ? "user" : "assistant",
                    "这是一段比较长的历史内容，用来触发上下文压缩，第" + i + "段"));
        }
        return messages;
    }

    @Test
    void compactsOldestMessagesAndPersistsSummary() {
        when(conversations.contextTokens("dev", 1L)).thenReturn(0L);
        when(llm.summarize(any(), anyString(), anyList(), anyInt())).thenReturn("用户在做一部仙侠作品");

        AgentContextService.Compacted result = service.compactIfNeeded(null, "dev", 1L,
                options(1_000), new AgentHistory("", 0, longHistory(5)), "系统提示", 0, "新问题", false);

        assertTrue(result.compacted());
        assertTrue(result.compactedCount() >= 1);
        assertTrue(result.history().hasSummary());
        assertTrue(result.history().messages().size() < 6);
        assertEquals("用户在做一部仙侠作品", result.history().summary());
        verify(conversations).saveSummary(eq("dev"), eq(1L), eq("用户在做一部仙侠作品"), anyLong());
    }

    @Test
    void leavesShortHistoryAlone() {
        AgentContextService.Compacted result = service.compactIfNeeded(null, "dev", 2L,
                options(1_000_000), new AgentHistory("", 0, longHistory(2)), "系统提示", 0, "新问题", false);

        assertFalse(result.compacted());
        assertEquals(2, result.history().messages().size());
        verify(llm, never()).summarize(any(), anyString(), anyList(), anyInt());
    }

    @Test
    void forceCompactsEvenBelowThreshold() {
        when(llm.summarize(any(), anyString(), anyList(), anyInt())).thenReturn("摘要");

        // 3 段各约 6 万 token：高于保留预算 159959，但低于 800000 阈值
        List<AgentHistory.Message> huge = new ArrayList<>();
        for (int i = 1; i <= 3; i++) {
            huge.add(new AgentHistory.Message(i, i % 2 == 1 ? "user" : "assistant", "长".repeat(60_000)));
        }

        AgentContextService.Compacted belowThreshold = service.compactIfNeeded(null, "dev", 3L,
                options(1_000_000), new AgentHistory("", 0, huge), "系统提示", 0, "", false);
        assertFalse(belowThreshold.compacted());

        AgentContextService.Compacted forced = service.compactIfNeeded(null, "dev", 3L,
                options(1_000_000), new AgentHistory("", 0, huge), "系统提示", 0, "", true);
        assertTrue(forced.compacted());
        assertTrue(forced.history().hasSummary());
        verify(conversations).saveSummary(eq("dev"), eq(3L), eq("摘要"), anyLong());
    }

    @Test
    void nothingToCompactWhenHistoryFitsRetain() {
        // 窗口很小但只有一条消息：保留段吃掉全部历史，没有可压缩的内容
        AgentContextService.Compacted result = service.compactIfNeeded(null, "dev", 4L,
                options(1_000), new AgentHistory("", 0, longHistory(1)), "系统提示", 0, "", false);

        assertFalse(result.compacted());
        verify(llm, never()).summarize(any(), anyString(), anyList(), anyInt());
    }
}
