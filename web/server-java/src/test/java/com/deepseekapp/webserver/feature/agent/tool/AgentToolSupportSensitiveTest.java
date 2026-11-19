package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.db.SchemaCatalog;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** schema.json 里标了 sensitive 的列不能交给模型。 */
class AgentToolSupportSensitiveTest {

    private final AgentToolSupport support =
            new AgentToolSupport(null, new SchemaCatalog(new ObjectMapper()));

    @Test
    void readableColumnsSkipApiKeys() {
        List<String> columns = support.readableColumns("deepseek", "user_settings");
        assertFalse(columns.contains("apiKey"));
        assertFalse(columns.contains("baidu_api_key"));
        assertTrue(columns.contains("model"));
    }

    @Test
    void redactMasksSensitiveValuesWithoutMutatingRow() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("id", 1L);
        row.put("model", "deepseek-flash");
        row.put("apiKey", "sk-secret");

        Map<String, Object> redacted = support.redactSensitive("deepseek", "user_settings", row);

        assertEquals("***", redacted.get("apiKey"));
        assertEquals("sk-secret", row.get("apiKey"));
        assertEquals("deepseek-flash", redacted.get("model"));
    }

    @Test
    void nonSensitiveTableIsUntouched() {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("title", "第一章");
        assertEquals(row, support.redactSensitive("deepseek", "outline_records", row));
    }
}
