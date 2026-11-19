package com.deepseekapp.webserver.feature.agent.tool;

import com.deepseekapp.webserver.feature.agent.runtime.AgentEvent;
import com.deepseekapp.webserver.feature.agent.runtime.AgentRun;
import com.deepseekapp.webserver.feature.agent.service.AgentDownloadService;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 下载工具：把网页文件存进本地下载库。
 * 下载完成后发一个 download 事件，前端据此刷新下载库。
 */
@Component
public class DownloadTools {

    private final AgentDownloadService downloads;
    private final AgentToolSupport support;

    public DownloadTools(AgentDownloadService downloads, AgentToolSupport support) {
        this.downloads = downloads;
        this.support = support;
    }

    @Tool(name = "download_file",
            description = "从网页下载文件并保存到本地下载库（仅 http/https，单文件上限 50MB，不支持本机/内网地址）。"
                    + "用户给出素材、图片、文档链接时可以用；下载后文件可在前端「下载库」里查看和保存到本机。")
    public Map<String, Object> downloadFile(
            @ToolParam(description = "要下载的 http/https 地址") String url,
            @ToolParam(description = "保存文件名，可选；不传则从响应头或 URL 推断", required = false) String filename,
            ToolContext context) {
        AgentRun run = support.runOf(context);
        Map<String, Object> args = new LinkedHashMap<>();
        args.put("url", url);
        args.put("filename", filename);
        return support.traced(run, "download_file", args, () -> {
            Map<String, Object> record = downloads.download(support.deviceOf(context), url, filename);
            if (run != null) {
                run.emit(AgentEvent.of("download", "download", record));
            }
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("id", record.get("id"));
            out.put("filename", record.get("filename"));
            out.put("size", record.get("size"));
            out.put("mime", record.get("mime"));
            out.put("downloadUrl", record.get("downloadUrl"));
            return out;
        });
    }
}
