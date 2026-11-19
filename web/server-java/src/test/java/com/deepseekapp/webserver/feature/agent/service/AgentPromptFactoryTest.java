package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.feature.agent.context.AgentHistory;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Agent 提示词与对话消息构建。 */
class AgentPromptFactoryTest {

    private static AgentOptions options(boolean webSearch) {
        return new AgentOptions("sk-test", "https://api.deepseek.com", "deepseek-flash",
                1.0, 32768, null, null, null, "", null, webSearch, 5, false, true, true, "high");
    }

    @Test
    void conversationKeepsRolesAndSkipsBlank() {
        List<AgentHistory.Message> history = List.of(
                new AgentHistory.Message(1L, "user", "第一问"),
                new AgentHistory.Message(2L, "assistant", "第一答"),
                new AgentHistory.Message(3L, "user", "   "),
                new AgentHistory.Message(4L, "tool", "工具输出"));

        List<Map<String, Object>> messages = AgentPromptFactory.conversation(history, "第二问");

        assertEquals(3, messages.size());
        assertEquals("user", messages.get(0).get("role"));
        assertEquals("assistant", messages.get(1).get("role"));
        assertEquals("第二问", messages.get(2).get("content"));
    }

    @Test
    void systemPromptCarriesDeviceTimeAndSearchState() {
        String enabled = AgentPromptFactory.systemPrompt(options(true), "phone-1");
        assertTrue(enabled.contains("phone-1"));
        assertTrue(enabled.contains("已开启"));
        // 时间不能进系统提示：它每次请求都会变，会让整段历史与工具 schema 的缓存前缀失效
        assertFalse(enabled.contains("当前时间"));

        String disabled = AgentPromptFactory.systemPrompt(options(false), "phone-1");
        assertTrue(disabled.contains("未开启"));
    }

    @Test
    void systemPromptIsByteStableAcrossCalls() {
        assertEquals(AgentPromptFactory.systemPrompt(options(true), "phone-1"),
                AgentPromptFactory.systemPrompt(options(true), "phone-1"));
    }

    @Test
    void runtimeNoteGoesToTheLastUserMessage() {
        String note = AgentPromptFactory.runtimeNote(java.time.LocalDateTime.of(2026, 11, 17, 14, 30));
        List<Map<String, Object>> messages = AgentPromptFactory.conversation(
                List.of(new AgentHistory.Message(1L, "user", "第一问")), "第二问", note);

        assertEquals(2, messages.size());
        assertEquals("第一问", messages.get(0).get("content"));
        assertTrue(String.valueOf(messages.get(1).get("content")).startsWith("第二问"));
        assertTrue(String.valueOf(messages.get(1).get("content")).endsWith(note));
        assertTrue(note.contains("14:30"));
    }

    @Test
    void customSystemPromptIsAppended() {
        AgentOptions custom = new AgentOptions("sk-test", "https://api.deepseek.com", "deepseek-flash",
                1.0, 32768, null, null, null, "只写悬疑", null, true, 5, false, true, true, "high");
        String prompt = AgentPromptFactory.systemPrompt(custom, "phone-1");
        assertTrue(prompt.contains("只写悬疑"));
        assertFalse(prompt.contains("sk-test"));
    }

    @Test
    void systemPromptExplainsSaving() {
        String prompt = AgentPromptFactory.systemPrompt(options(true), "phone-1");
        assertTrue(prompt.contains("会直接落库"));
        assertTrue(prompt.contains("list_chapters"));
        assertTrue(prompt.contains("outlineId"));
        assertFalse(prompt.contains("生成结果不会自动保存"));
    }

    @Test
    void compactionSummaryIsInjectedIntoSystemPrompt() {
        String prompt = AgentPromptFactory.systemPrompt(options(true), "phone-1", "用户要一部仙侠，作品 1000000001");

        assertTrue(prompt.contains("检查点"));
        assertTrue(prompt.contains("<compacted-summary>"));
        assertTrue(prompt.contains("1000000001"));
        assertTrue(prompt.contains("</compacted-summary>"));
    }

    @Test
    void optionsToStringMasksApiKey() {
        assertTrue(options(true).toString().contains("apiKey=***"));
        assertFalse(options(true).toString().contains("sk-test"));
    }
}
