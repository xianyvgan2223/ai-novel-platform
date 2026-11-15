package com.deepseekapp.webserver.feature.writing.service;

import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Map;
import com.deepseekapp.webserver.ai.NovelAiService;
import com.deepseekapp.webserver.ai.AiSettings;

/**
 * 「AI 写战斗」：按双方技能、场景、结果三要素流式生成战斗场面。
 * 只输出正文，保存成 battle_scenes 记录由前端调用通用数据接口完成。
 */
@Service
public class BattleGenerationService {

    @FunctionalInterface
    public interface Sink {
        void delta(String text) throws IOException;
    }

    private static final String DEFAULT_SYSTEM = """
            你是一位专业的战斗场景描写作家。请根据用户提供的战斗要素（双方人物技能、战斗场景氛围、战斗结果），\
            生成一段精彩具体的战斗场景描写。

            要求：
            1. 紧扣用户提供的要素，不要偏离设定
            2. 描写要生动具体，包含动作、环境、心理等细节
            3. 合理运用打斗过程的起承转合
            4. 战斗结果必须与用户指定的结果一致
            5. 用中文创作，使用纯文本格式
            6. 篇幅在 1000-3000 字之间""";

    private final NovelAiService ai;
    private final WritingService writingService;

    public BattleGenerationService(NovelAiService ai, WritingService writingService) {
        this.ai = ai;
        this.writingService = writingService;
    }

    public void generate(Map<String, Object> body, Sink sink) throws IOException {
        writingService.requireConfig();

        StringBuilder user = new StringBuilder();
        String skills = str(body.get("skills"), "");
        String scene = str(body.get("scene"), "");
        String result = str(body.get("result"), "");
        if (skills.isEmpty() && scene.isEmpty() && result.isEmpty()) {
            throw new IllegalArgumentException("至少填写一项战斗要素（双方技能 / 场景 / 结果）");
        }
        if (!skills.isEmpty()) {
            user.append("【双方人物技能】").append(skills).append("\n\n");
        }
        if (!scene.isEmpty()) {
            user.append("【战斗场景】").append(scene).append("\n\n");
        }
        if (!result.isEmpty()) {
            user.append("【战斗结果】").append(result).append('\n');
        }
        String extra = str(body.get("extra"), "");
        if (!extra.isEmpty()) {
            user.append("\n额外要求：").append(extra).append('\n');
        }

        for (String delta : ai.stream(DEFAULT_SYSTEM, user.toString(), AiSettings.from(body)).toIterable()) {
            sink.delta(delta);
        }
    }

    private static String str(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String text = String.valueOf(value).trim();
        return text.isEmpty() ? fallback : text;
    }
}
