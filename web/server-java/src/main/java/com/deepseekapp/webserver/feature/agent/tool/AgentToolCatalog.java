package com.deepseekapp.webserver.feature.agent.tool;

import org.springframework.ai.tool.annotation.Tool;
import org.springframework.stereotype.Component;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 工具目录：把分散在各能力类里的 {@code @Tool} 聚合成一份，
 * 供 AgentService 注册到模型、供 AgentController 输出给面板。
 */
@Component
public class AgentToolCatalog {

    private final List<ToolBean> beans;

    private record ToolBean(Object instance, Class<?> type) {
    }

    public AgentToolCatalog(DataTools dataTools, RagTools ragTools, WritingTools writingTools) {
        this.beans = List.of(
                new ToolBean(dataTools, DataTools.class),
                new ToolBean(ragTools, RagTools.class),
                new ToolBean(writingTools, WritingTools.class)
        );
    }

    /** 传给 {@code ChatClient.prompt().tools(...)} 的工具实例。 */
    public Object[] toolObjects() {
        return beans.stream().map(ToolBean::instance).toArray();
    }

    /** 面板空状态展示的工具清单。 */
    public List<Map<String, Object>> describe() {
        List<Map<String, Object>> list = new ArrayList<>();
        for (ToolBean bean : beans) {
            for (Method method : bean.type().getMethods()) {
                Tool tool = method.getAnnotation(Tool.class);
                if (tool == null) {
                    continue;
                }
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("name", tool.name());
                item.put("description", tool.description());
                list.add(item);
            }
        }
        list.sort(Comparator.comparing(item -> String.valueOf(item.get("name"))));
        return list;
    }
}
