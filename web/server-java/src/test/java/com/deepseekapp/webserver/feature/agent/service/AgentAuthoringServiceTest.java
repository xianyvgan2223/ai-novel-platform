package com.deepseekapp.webserver.feature.agent.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.sync.SyncStore;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 生成结果 → 作品/章节行的映射，必须和写作页保存的字段一致。 */
class AgentAuthoringServiceTest {

    private static final String NOW = "2026-11-17T05:00:00.000Z";

    private static Map<String, Object> outlineData() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("title", " 测试书 ");
        data.put("genre", "仙侠");
        data.put("theme", "逆袭");
        data.put("protagonist", "林舟");
        data.put("worldview", "九州");
        data.put("outlineText", "══ 大事件1：开局 ══\n正文");
        data.put("skeletonJson", "[{\"title\":\"第一幕\"}]");
        data.put("charactersJson", "[{\"name\":\"林舟\"}]");
        data.put("chapters", List.of(
                Map.of("index", 1, "type", "major", "title", "开局", "summary", "大事件概要"),
                Map.of("index", 2, "type", "minor", "title", "入门", "summary", "小事件概要")));
        return data;
    }

    @Test
    void outlineRowMapsToOutlineRecord() {
        Map<String, Object> row = AgentAuthoringService.outlineRow(1_000_000_001L, outlineData(), NOW);

        assertEquals(1_000_000_001L, row.get("id"));
        assertEquals("测试书", row.get("title"));
        assertEquals("仙侠", row.get("genre"));
        assertEquals("══ 大事件1：开局 ══\n正文", row.get("content"));
        assertEquals("[{\"title\":\"第一幕\"}]", row.get("skeleton"));
        assertEquals("[{\"name\":\"林舟\"}]", row.get("characters"));
        assertEquals("", row.get("foreshadows"));
        assertEquals("", row.get("story_state"));
        assertEquals(NOW, row.get("created_at"));
    }

    @Test
    void chapterRowMapsIndexAndPendingState() {
        Map<String, Object> chapter = Map.of(
                "index", 2, "type", "minor", "title", "入门", "summary", "小事件概要");

        Map<String, Object> row = AgentAuthoringService.chapterRow(2_000_000_001L, 1_000_000_001L, chapter, NOW);

        assertEquals(2_000_000_001L, row.get("id"));
        assertEquals(1_000_000_001L, row.get("outline_id"));
        assertEquals(2, row.get("event_index"));
        assertEquals("minor", row.get("event_type"));
        assertEquals("入门", row.get("event_title"));
        assertEquals("小事件概要", row.get("event_summary"));
        assertEquals("", row.get("content"));
        assertEquals("pending", row.get("status"));
        assertEquals(NOW, row.get("updated_at"));
    }

    @Test
    void chapterRowFallsBackWhenSummaryMissing() {
        Map<String, Object> chapter = new LinkedHashMap<>();
        chapter.put("index", 1);
        chapter.put("type", "major");
        chapter.put("title", "开局");

        Map<String, Object> row = AgentAuthoringService.chapterRow(3L, 4L, chapter, NOW);

        assertEquals("", row.get("event_summary"));
        assertEquals("开局", row.get("event_title"));
        assertEquals(1, row.get("event_index"));
    }

    @Test
    void saveOutlineWritesOutlineAndEveryChapter() {
        SyncStore store = mock(SyncStore.class);
        when(store.allocateWebId(anyString(), anyString(), eq("outline_records"))).thenReturn(1_000_000_001L);
        when(store.allocateWebId(anyString(), anyString(), eq("outline_chapters")))
                .thenReturn(2_000_000_001L, 2_000_000_002L);
        AgentAuthoringService service = new AgentAuthoringService(store, null, new AppProperties());

        Map<String, Object> saved = service.saveOutline("device-1", outlineData());

        assertEquals(1_000_000_001L, saved.get("outlineId"));
        assertEquals(2, saved.get("chapterCount"));
        assertEquals("测试书", saved.get("title"));
        verify(store).writeRow(eq("device-1"), eq("deepseek"), eq("outline_records"),
                argThat(row -> "测试书".equals(row.get("title"))
                        && "══ 大事件1：开局 ══\n正文".equals(row.get("content"))),
                anyString());
        verify(store, times(2)).writeRow(eq("device-1"), eq("deepseek"), eq("outline_chapters"),
                any(Map.class), anyString());
    }

    @Test
    void saveChapterContentMarksChapterCompleted() {
        SyncStore store = mock(SyncStore.class);
        Map<String, Object> existing = new LinkedHashMap<>();
        existing.put("id", 5L);
        existing.put("outline_id", 7L);
        existing.put("content", "旧正文");
        when(store.readRow("device-1", "deepseek", "outline_chapters", 5L)).thenReturn(existing);
        AgentAuthoringService service = new AgentAuthoringService(store, null, new AppProperties());

        Map<String, Object> saved = service.saveChapterContent("device-1", 5L, "新正文");

        assertEquals(5L, saved.get("chapterId"));
        assertEquals(7L, saved.get("outlineId"));
        assertEquals(3, saved.get("chars"));
        verify(store).writeRow(eq("device-1"), eq("deepseek"), eq("outline_chapters"),
                argThat(row -> "新正文".equals(row.get("content"))
                        && "completed".equals(row.get("status"))
                        && row.get("updated_at") != null),
                anyString());
    }
}
