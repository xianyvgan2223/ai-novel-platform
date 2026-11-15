package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.feature.agent.service.AgentOptions;
import com.deepseekapp.webserver.feature.agent.service.AgentRun;
import com.deepseekapp.webserver.feature.agent.service.AgentSettingsService;
import com.deepseekapp.webserver.feature.agent.service.AgentWebSearchService;
import com.deepseekapp.webserver.web.ApiException;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 联网搜索工具。开关、条数、是否抓正文都由 Agent 面板设置控制；
 * 关闭时工具仍会注册，但调用会明确提示未开启，避免模型偷偷搜索。
 */
@Component
public class WebSearchTools {

    private final AgentWebSearchService searchService;
    private final AgentSettingsService settings;
    private final AgentToolSupport support;

    public WebSearchTools(AgentWebSearchService searchService,
                          AgentSettingsService settings,
                          AgentToolSupport support) {
        this.searchService = searchService;
        this.settings = settings;
        this.support = support;
    }

    @Tool(name = "web_search",
            description = "联网搜索网页获取实时信息（新闻、最新数据、外部资料）。"
                    + "只在用户问题需要当前互联网信息时使用；本地小说数据请用 list_data / search_rag。")
    public Map<String, Object> webSearch(
            @ToolParam(description = "搜索关键词，尽量具体") String query,
            @ToolParam(description = "返回条数；不传则使用设置里的条数", required = false) Integer count,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("query", query);
        args.put("count", count);
        return support.traced(run, "web_search", args, () -> {
            AgentOptions options = settings.resolve(support.deviceOf(context));
            if (!options.webSearch()) {
                throw new ApiException(400, "联网搜索未开启：请让用户在 Agent 面板设置里打开「联网搜索」后再试");
            }
            int size = Math.min(count == null ? options.searchCount() : count, 8);
            List<Map<String, Object>> results = searchService.search(
                    options, query, size, options.searchNeedContent());
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("query", query == null ? "" : query.trim());
            out.put("count", results.size());
            out.put("results", results);
            return out;
        });
    }
}
