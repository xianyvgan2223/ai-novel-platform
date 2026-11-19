package com.deepseekapp.webserver.feature.bili.service;

import com.deepseekapp.webserver.config.AppProperties;
import com.deepseekapp.webserver.web.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** B站提取记录：保存 / 列表（不含正文）/ 详情 / 删除，以及重启后仍能读到。 */
class BiliTranscriptStoreTest {

    @TempDir
    Path tempDir;

    private BiliTranscriptStore store() {
        AppProperties props = new AppProperties();
        props.setDataDir(tempDir.toString());
        return new BiliTranscriptStore(props);
    }

    @Test
    void savesListsReadsAndDeletes() throws Exception {
        BiliTranscriptStore store = store();
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("title", "测试视频");
        meta.put("owner", "UP");
        meta.put("bvid", "BV1xx411c7mD");
        meta.put("source", "subtitle");

        Map<String, Object> saved = store.save(meta, "第一行\n第二行\n");
        String id = String.valueOf(saved.get("id"));
        assertFalse(id.isBlank());
        assertEquals(1, store.list().size());

        // 重新按目录构造：验证写入磁盘后新实例也能读到索引与正文
        BiliTranscriptStore reopened = store();
        List<Map<String, Object>> list = reopened.list();
        assertEquals(1, list.size());
        assertEquals("测试视频", list.get(0).get("title"));
        assertFalse(list.get(0).containsKey("text"), "列表不应带正文");

        Map<String, Object> detail = reopened.get(id);
        assertEquals("第一行\n第二行\n", detail.get("text"));
        assertEquals(8, detail.get("chars"));

        assertTrue(reopened.delete(id));
        assertEquals(0, reopened.list().size());
        assertFalse(reopened.delete(id));
        assertThrows(ApiException.class, () -> reopened.get(id));
    }

    @Test
    void rejectsPathLikeIds() {
        assertThrows(ApiException.class, () -> store().get("../../secret"));
        assertThrows(ApiException.class, () -> store().delete("../x"));
    }
}