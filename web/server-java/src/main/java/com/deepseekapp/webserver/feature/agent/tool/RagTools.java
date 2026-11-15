package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.rag.service.RagService;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** RAG 类工具：语义检索情节素材、查看素材库状态。 */
@Component
public class RagTools {

    private final RagService ragService;
    private final AgentToolSupport support;

    public RagTools(RagService ragService, AgentToolSupport support) {
        this.ragService = ragService;
        this.support = support;
    }

    @Tool(name = "search_rag",
            description = "语义检索情节素材库，返回与 query 最接近的情节片段。写新章节前用它找参考素材。")
    public Map<String, Object> searchRag(
            @ToolParam(description = "检索描述，例如「雨夜重逢，双方克制、未直接相认」") String query,
            @ToolParam(description = "返回条数，默认 6，最大 20", required = false) Integer size,
            @ToolParam(description = "可选标签过滤，例如 悬疑、情感", required = false) List<String> tags,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("query", query);
        args.put("size", size);
        args.put("tags", tags);
        return support.traced(run, "search_rag", args, () -> {
            if (query == null || query.isBlank()) {
                throw new ApiException(400, "检索描述不能为空");
            }
            List<RagService.Scene> hits = ragService.search(
                    query.trim(), AgentToolSupport.clamp(size == null ? 6 : size, 1, 20), tags);
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("query", query.trim());
            out.put("count", hits.size());
            out.put("hits", hits);
            return out;
        });
    }

    @Tool(name = "rag_status",
            description = "查看情节素材库状态：索引是否在线、已入库作品与标签。"
                    + "检索不到素材时先调用它确认库里有没有数据。")
    public Map<String, Object> ragStatus(ToolContext context) {
        AgentRun run = support.runOf(context);
        return support.traced(run, "rag_status", Map.of(), ragService::status);
    }
}
