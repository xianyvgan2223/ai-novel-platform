package com.deepseekapp.webserver.feature.writing.service;

import com.deepseekapp.webserver.util.Json;
import com.deepseekapp.webserver.web.ApiException;
import com.fasterxml.jackson.core.json.JsonReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import com.deepseekapp.webserver.ai.NovelAiService;
import com.deepseekapp.webserver.ai.AiSettings;

/**
 * 网页端分阶段大纲生成，流程与移动端「一键生成大纲」对齐：
 *
 * <pre>
 * 定调（书名 + 核心概念）
 *   → 粗骨架（全部大事件仅标题 + 一句话定位）
 *   → 检查点：粗骨架
 *   → 分批精写大事件 + 抽取伏笔账本
 *   → 检查点：大事件
 *   → 按块展开小事件（每块最多 3 个大事件，承接前文、铺垫后文）
 *   → 检查点：小事件
 *   → 前端保存为作品
 * </pre>
 *
 * 提示词与移动端 OutlinePromptTemplate 保持一致；检查点由前端在各阶段请求之间暂停实现。
 */
@Service
public class OutlineStageService {

    public interface Sink {
        void stage(int index, int total, String label) throws IOException;

        void delta(String text) throws IOException;
    }

    private static final String JSON_SYSTEM = """
            你是一个专业的小说大纲生成助手，擅长搭建逻辑闭环、人物成长清晰、伏笔回收完整的长篇小说大纲。
            请严格按照用户要求的结构输出 JSON 数据，不要输出 JSON 以外的任何文字、解释或 markdown 代码块。""";

    private static final String TEXT_SYSTEM = """
            你是一个专业的小说大纲生成助手，擅长搭建逻辑闭环、人物成长清晰、伏笔回收完整的长篇小说大纲。
            请始终使用纯文本格式输出，禁止使用 markdown、表格、json、加粗符号或任何标记语言。
            不要添加多余的解释性文字。""";

    private static final int MAX_EVENTS_PER_CHUNK = 3;
    private static final int LEDGER_INTERVAL = 2;
    private static final int MAX_CONTINUATIONS = 3;

    /** 模型偶尔会在 JSON 字符串里输出未转义换行；解析时放宽，避免整批失败。 */
    private static final ObjectMapper MODEL_MAPPER = Json.MAPPER.copy()
            .enable(JsonReadFeature.ALLOW_UNESCAPED_CONTROL_CHARS.mappedFeature())
            .enable(JsonReadFeature.ALLOW_SINGLE_QUOTES.mappedFeature())
            .enable(JsonReadFeature.ALLOW_TRAILING_COMMA.mappedFeature());

    private final NovelAiService ai;

    public OutlineStageService(NovelAiService ai) {
        this.ai = ai;
    }

    public record Event(String title, String summary) {
    }

    public record Act(String name, List<Event> events) {
    }

    private record Batch(int actIndex, int startInAct, List<Event> events) {
    }

    private record Chunk(int actIndex, int chunkIndex, String actHeader,
                         String actName, String content, int startIndex, int endIndex) {
    }

    // ───────────────────────────── 阶段 1：定调 ─────────────────────────────

    public Map<String, Object> concept(Map<String, Object> body, Sink sink) throws IOException {
        AiSettings settings = AiSettings.from(body);
        String system = JSON_SYSTEM;
        String user = """
                根据以下小说设定，生成书名和核心概念简介，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

                小说类型：%s
                核心主题：%s
                主角完整人设：%s
                完整世界观：%s

                %s要求：
                - 书名务必贴合类型、主题、主角核心宿命，简洁有记忆点
                - 输出 JSON 格式为：{"title": "书名", "concept": "核心概念简介"}
                """.formatted(
                str(body, "genre"),
                str(body, "theme"),
                str(body, "protagonist"),
                str(body, "worldview"),
                extraSection(body)
        );
        String raw = streamText(system, user, sink, jsonSettings(settings, 0.3));
        JsonNode root = readObject(raw, "书名和核心概念生成失败：模型输出无法解析");
        String title = text(root, "title");
        String concept = text(root, "concept");
        if (title.isBlank() || concept.isBlank()) {
            throw new ApiException(502, "书名和核心概念生成失败：缺少 title 或 concept");
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("title", title);
        result.put("concept", concept);
        result.put("conceptText", "书名：《" + title + "》\n\n" + concept);
        result.put("genre", str(body, "genre"));
        result.put("theme", str(body, "theme"));
        result.put("protagonist", str(body, "protagonist"));
        result.put("worldview", str(body, "worldview"));
        return result;
    }

    // ───────────────────────────── 阶段 2a：粗骨架 ─────────────────────────────

    public Map<String, Object> skeleton(Map<String, Object> body, Sink sink) throws IOException {
        AiSettings settings = AiSettings.from(body);
        int majorCount = clamp(intVal(body.get("majorCount"), 6), 1, 30);
        int minorCount = clamp(intVal(body.get("minorCount"), 3), 1, 10);
        String title = str(body, "title");
        String concept = str(body, "concept");
        String titleAndConcept = title.isEmpty()
                ? str(body, "conceptText")
                : "书名：" + title + "\n核心概念：" + concept;

        String user = """
                请根据以下小说设定，规划全篇三幕结构的粗骨架，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

                小说类型：%s
                核心主题：%s
                主角完整人设：%s
                完整世界观：%s

                %s已有书名和核心概念：
                %s

                全篇主事件总数量：%d（三个 act 中 events 事件总数必须严格等于 %d）
                单个主事件配套小事件固定数量：%d

                三幕分配规则：第一幕开端占总主事件约30%%，第二幕发展约占50%%，第三幕高潮结局约占20%%，无法整除时第二幕多分配余量。

                粗骨架要求：
                1. 这一步只规划全局轨迹，每个大事件只写「标题 + 一句话定位」，不要展开细节
                2. 定位需写清：本事件的核心冲突、在故事弧线中的位置（铺垫/升级/转折/高潮/结局）
                3. 每5个大事件之间要有递进关系：铺垫→冲突升级→危机加剧→高潮→收束或者危机→冲突→怎么解决→反转→剧情展开
                4. 人物成长：每一幕结尾主角有阶段性性格变化，全篇完成「缺陷暴露→挣扎蜕变→闭环」
                5. 只做短线伏笔：每条伏笔必须能在 5 个大事件之内埋设并回收，不要写长线伏笔
                6. 第三幕需覆盖前文主要伏笔的回收点
                7. 定位里严禁写章节 / 事件编号：不要出现「第54章」「第54个事件」「大事件54」这类引用；
                   伏笔提示直接写内容本身（人物、物件、原话、场景），不要写「第几章埋的伏笔」

                输出 JSON 格式为：
                {"acts": [{"act": "第一幕：开端", "events": [{"title": "事件标题", "position": "一句话定位（含在故事中的位置与伏笔提示）"}]}]}
                要求：
                - 必须输出 3 个 act，act 依次为「第一幕：开端」「第二幕：发展」「第三幕：高潮&结局」
                - 每个 act 至少包含 1 个事件
                - 全部 events 数量必须严格等于 %d
                """.formatted(
                str(body, "genre"), str(body, "theme"), str(body, "protagonist"), str(body, "worldview"),
                extraSection(body), titleAndConcept, majorCount, majorCount, minorCount, majorCount
        );
        String raw = streamText(JSON_SYSTEM, user, sink, jsonSettings(settings, 0.3));
        JsonNode root = readObject(raw, "粗骨架生成失败：三幕结构或事件数量与设定不一致");
        List<Act> acts = parseActs(root.path("acts"));
        if (acts.isEmpty()) {
            throw new ApiException(502, "粗骨架生成失败：没有解析到三幕事件");
        }
        String render = renderActs(acts, true);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("title", title);
        result.put("concept", concept);
        result.put("acts", acts);
        result.put("coarseText", render);
        result.put("skeletonText", render);
        result.put("eventCount", countEvents(acts));
        result.put("majorCount", majorCount);
        result.put("minorCount", minorCount);
        return result;
    }

    // ───────────────────────────── 阶段 2b：精写大事件 ─────────────────────────────

    public Map<String, Object> events(Map<String, Object> body, Sink sink) throws IOException {
        AiSettings settings = AiSettings.from(body);
        List<Act> coarseActs = parseActs(Json.MAPPER.valueToTree(body.get("acts")));
        if (coarseActs.isEmpty()) {
            throw new ApiException(400, "缺少粗骨架数据");
        }
        int minorCount = clamp(intVal(body.get("minorCount"), 3), 1, 10);
        List<Act> acts = cloneActs(coarseActs);
        List<Batch> batches = buildBatches(acts);
        int ledgerCount = countLedgerBatches(batches.size());
        int totalSteps = batches.size() + ledgerCount;
        int step = 0;

        String title = str(body, "title");
        String concept = str(body, "concept");
        String coarseSkeleton = renderActs(coarseActs, false);
        String extra = str(body, "extra");
        Ledger ledger = new Ledger();
        String previousRefined = "";

        for (int b = 0; b < batches.size(); b++) {
            Batch batch = batches.get(b);
            if (b > 0) sleepQuietly(1200L);
            step++;
            sink.stage(step, totalSteps, "精写大事件 (" + (b + 1) + "/" + batches.size() + ")");
            String user = refinePrompt(body, title, concept, coarseSkeleton,
                    renderBatch(batch, acts, false), ledger.render(), previousRefined, extra);
            JsonNode events = null;
            String raw = "";
            for (int attempt = 0; attempt < 3; attempt++) {
                if (attempt > 0) sleepQuietly(1500L * attempt);
                raw = streamText(JSON_SYSTEM, user, sink,
                        jsonSettings(settings, settings == null || settings.temperature() == null ? 0.8 : settings.temperature()));
                JsonNode root;
                try {
                    root = readObject(raw, "第 " + (b + 1) + " 批大事件精写失败：JSON 无法解析");
                } catch (ApiException e) {
                    continue;
                }
                JsonNode candidate = root.path("events");
                if (candidate.isArray() && candidate.size() == batch.events().size()) {
                    events = candidate;
                    break;
                }
            }
            if (events == null) {
                throw new ApiException(502, "第 " + (b + 1) + " 批大事件精写失败：返回数量与粗骨架不一致"
                        + "（期望 " + batch.events().size() + "）：" + abbreviate(raw));
            }
            applyRefinedBatch(acts, batch, events);
            previousRefined = renderBatch(batch, acts, true);

            if (needsLedger(b, batches.size())) {
                if (b > 0) sleepQuietly(1000L);
                step++;
                sink.stage(step, totalSteps, "抽取伏笔账本 (" + (b + 1) + "/" + batches.size() + ")");
                String ledgerPrompt = ledgerPrompt(previousRefined, ledger.render());
                String ledgerRaw = streamText(JSON_SYSTEM, ledgerPrompt, sink,
                        jsonSettings(settings, 0.3));
                JsonNode ledgerRoot = readObject(ledgerRaw, "伏笔账本提取失败");
                ledger.merge(ledgerRoot);
            }
        }

        String eventsText = renderActs(acts, true);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("title", title);
        result.put("concept", concept);
        result.put("acts", acts);
        result.put("coarseActs", coarseActs);
        result.put("coarseText", renderActs(coarseActs, true));
        result.put("eventsText", eventsText);
        result.put("ledgerText", ledger.render());
        result.put("ledger", ledger.toMap());
        result.put("minorCount", minorCount);
        return result;
    }

    private String refinePrompt(Map<String, Object> body, String title, String concept,
                                String coarseSkeleton, String batchContent,
                                String ledgerText, String prevRefined, String extra) {
        String prevSection = prevRefined.isBlank() ? "" : """
                === 上一批已精写的大事件（本批必须严格承接其结局状态与已发生情节，禁止重复或矛盾） ===
                %s

                """.formatted(prevRefined);
        return """
                请根据以下全局设定、粗骨架和伏笔账本，精写本批大事件的完整概述，并以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

                小说类型：%s
                核心主题：%s
                主角完整人设：%s
                完整世界观：%s
                书名：%s
                核心概念：%s

                %s=== 全局粗骨架（全部大事件，仅标题与定位） ===
                %s

                === 本批需要精写的大事件（标题必须与粗骨架完全一致，按顺序输出） ===
                %s

                === 已积累的伏笔账本（来自此前各批，必须延续与照应） ===
                %s

                %s大事件粒度定义（严格遵守）：
                - 大事件 = 改变故事走向的重大阶段节点（如身份揭露、势力决裂、觉醒/蜕变、终局大战），应跨越时间与场景，可独立成章
                - 禁止把单个场景、单次对话、单一动作步骤当作大事件
                - 大事件数量多代表故事铺陈规模大，不代表粒度变细

                写作要求：
                1. 每个大事件包含外部矛盾，呼应本批定位中的伏笔提示
                2. 相邻大事件有递进关系，事件之间需有时间/场景跳跃，独立成章
                3. 延续伏笔账本：已埋伏笔按计划回收；本批新埋伏笔要在描述中点明，并且必须能在 5 个大事件之内回收；不要写长线伏笔，已回收的伏笔不要再写
                4. 承接上一批：本批首个大事件须延续上一批最后大事件的结局状态（人物处境、关系变化、已获得的信息、在场角色），已发生的情节与已出现的冲突不得重复（若未提供「上一批已精写的大事件」则忽略此条）
                5. 篇幅由你根据该事件在全局中的重要程度自行把握，写透核心冲突，宁实勿空
                6. 避免逻辑漏洞、人物动机割裂、强行降智
                7. 严禁编号引用（硬性要求）：概述正文里不得出现任何章节号 / 事件编号，包括
                   「第54章」「第54个事件」「大事件54」「小事件12」「54与70埋的」「第3幕」……
                   伏笔照应必须直接写出内容本身（人物、旧物件、原话、场景），让只读这一段的人
                   也能看懂指的是什么；不要写「第几章埋的伏笔」。
                   - 反例（禁止）：54与70埋的"只学会一种接受方式"在此第一次被真正掰开
                   - 正例（照此写）：他从前只学会一种接受方式——被人护着；这一次他第一次学着自己
                     接下别人的好意，也第一次肯让一个人替他挡在门前
                   编号只允许出现在输出 JSON 的 title 字段所对应的骨架定位里，summary 正文一律不带编号

                输出 JSON 格式为：
                {"events": [{"title": "与粗骨架完全一致的事件标题", "summary": "完整概述"}]}
                要求：
                - events 数量必须严格等于本批大事件数量
                - title 必须与粗骨架中的标题完全一致，保持顺序
                """.formatted(
                str(body, "genre"), str(body, "theme"), str(body, "protagonist"), str(body, "worldview"),
                title, concept, extraSection(body), coarseSkeleton, batchContent, ledgerText, prevSection
        );
    }

    private String ledgerPrompt(String batchContent, String prevLedger) {
        return """
                请阅读以下本批已精写的大事件，结合之前的伏笔账本，抽取并合并出最新的伏笔账本，以严格的 JSON 格式输出（不要输出任何额外文字、解释或 markdown 代码块）。

                === 本批已精写的大事件 ===
                %s

                === 之前已积累的伏笔账本（需保留未回收项，标注本批是否有进展） ===
                %s

                要求：
                1. 账本只保留未回收的短线伏笔：每条伏笔必须能在 5 个大事件之内回收，不要写长线伏笔；
                   已经跨过 5 个大事件仍未回收的伏笔直接删除，不要保留
                2. 更新各主要角色的当前处境与变化
                3. 列出尚未解决的悬念
                4. 本批内已经回收/兑现的伏笔直接删除，不要写进账本（账本里不再保留已实现的伏笔）
                   计划回收时机只写「第一幕 / 第二幕 / 第三幕 / 终章」这类叙事阶段
                5. 严禁编号引用：foreshadows / character_states / unresolved 的文本里不得出现
                   章节号或事件编号（「第54章」「第54个事件」「大事件54」「54与70埋的」等）；
                   伏笔内容直接写情节本身（人物/物件/原话/场景），不要写「第几章埋的伏笔」

                输出 JSON 格式为：
                {"foreshadows": [{"content": "伏笔内容", "status": "已埋/已回收", "plan": "计划回收时机"}], "character_states": ["角色状态1"], "unresolved": ["悬念1"]}
                """.formatted(batchContent, prevLedger);
    }

    // ───────────────────────────── 阶段 3：展开小事件 ─────────────────────────────

    public Map<String, Object> minor(Map<String, Object> body, Sink sink) throws IOException {
        AiSettings settings = AiSettings.from(body);
        List<Act> acts = parseActs(Json.MAPPER.valueToTree(body.get("acts")));
        if (acts.isEmpty()) {
            throw new ApiException(400, "缺少精写后的大事件数据");
        }
        int minorCount = clamp(intVal(body.get("minorCount"), 3), 1, 10);
        String title = str(body, "title");
        String concept = str(body, "concept");
        String extra = str(body, "extra");
        String ledgerText = str(body, "ledgerText");
        if (ledgerText.isBlank()) ledgerText = "（暂无）";
        String globalSummary = (title.isBlank() ? "" : "书名：《" + title + "》\n核心概念：" + concept + "\n\n")
                + "完整三幕骨架：\n" + renderActs(acts, true)
                + "\n\n伏笔账本：\n" + ledgerText;

        List<Chunk> chunks = buildChunks(acts);
        StringBuilder output = new StringBuilder();
        String previousContent = "";
        String system = textSystem(settings);

        for (int i = 0; i < chunks.size(); i++) {
            Chunk chunk = chunks.get(i);
            if (i > 0) sleepQuietly(1500L);
            sink.stage(i + 1, chunks.size(), "展开" + chunk.actName() + "小事件 (" + (i + 1) + "/" + chunks.size() + ")");
            Chunk next = i + 1 < chunks.size() ? chunks.get(i + 1) : null;
            String laterContent = next == null ? "" : renderNextSkeleton(acts, next);
            String prompt = step3Prompt(body, title, concept, acts, chunk, globalSummary,
                    previousContent, laterContent, minorCount, extra);
            String chunkText = "";
            for (int attempt = 0; attempt < 3 && chunkText.isBlank(); attempt++) {
                if (attempt > 0) sleepQuietly(1800L * attempt);
                chunkText = streamText(system, prompt, sink, textSettings(settings), true).trim();
            }
            if (chunkText.isBlank()) {
                // 极端情况下模型返回空流：保留本块框架，避免整份大纲失败
                chunkText = renderChunkFallback(chunk);
            }
            // 每块最多自动续写有限次数，避免 max_tokens 截断直接丢内容
            int continuation = 0;
            while (!chunkText.contains("○ 小事件") && continuation < MAX_CONTINUATIONS) {
                String continuePrompt = "请接着刚才的内容继续输出，不要重复已经生成的部分，不要添加解释性文字。";
                String more = streamText(system, prompt + "\n\n已生成内容：\n" + chunkText + "\n\n" + continuePrompt,
                        sink, textSettings(settings), true);
                chunkText = (chunkText + "\n" + more.trim()).trim();
                continuation++;
            }
            if (output.length() > 0) output.append('\n');
            if (chunk.chunkIndex() == 0) {
                output.append("══ ").append(chunk.actHeader()).append(" ══\n\n");
            }
            output.append(chunkText).append('\n');
            previousContent = chunkText;
        }

        String outlineText = output.toString().trim();
        List<Map<String, Object>> chapters = parseChapters(outlineText);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("title", title);
        result.put("concept", concept);
        result.put("acts", acts);
        result.put("outlineText", outlineText);
        result.put("chapters", chapters);
        result.put("ledgerText", ledgerText);
        result.put("minorCount", minorCount);
        return result;
    }

    private String step3Prompt(Map<String, Object> body, String title, String concept,
                               List<Act> acts, Chunk chunk, String globalSummary,
                               String previousContent, String laterContent,
                               int minorCount, String extra) {
        String previousSection = previousContent.isBlank() ? "" : """
                === 前一块已展开的详细内容（必须严格承接，禁止重复或矛盾） ===
                %s

                """.formatted(previousContent);
        String laterSection = laterContent.isBlank() ? "" : """
                === 紧接着的下一块大事件（本块结尾须为其铺垫与过渡） ===
                %s

                """.formatted(laterContent);
        String formatExample = """
                ══ 大事件%d：大事件标题 ══
                大事件概述（原样完整保留上面框架里该大事件给出的概述，不要重写/压缩/删减）
                ○ 小事件1：小标题
                小事件概要
                ○ 小事件2：小标题
                小事件概要
                ○ 小事件3：小标题
                小事件概要
                ……（循环至%d个小事件）""".formatted(chunk.startIndex(), minorCount);
        return """
                请展开第%d幕（%s）的详细内容。

                小说类型：%s
                核心主题：%s
                主角完整人设：%s
                完整世界观：%s
                书名：%s

                %s=== 全局框架（保证与全局设定、其他幕保持一致） ===
                %s

                %s%s=== 当前幕已有的大事件框架 ===
                %s

                请为上述每个大事件展开配套的小事件（共%d个小事件每个），严格遵循以下格式（纯文本，禁止任何 markdown 标记）：

                %s

                格式硬性要求（违反会直接导致大纲解析失败）：
                - 大事件标题行必须写成「══ 大事件N：标题 ══」，N 用本块框架里的具体数字，禁止写成「大事件X」或省略编号
                - 大事件概述必须原样完整保留「当前幕已有的大事件框架」里给出的该大事件概述：
                  只允许微调标点使语句通顺，不得删减信息、不得压缩、不得重写——你的任务只是为它补写小事件
                - 小事件标题行必须写成「○ 小事件N：标题」，N 在每个大事件内部从 1 开始连续编号
                - 禁止使用 markdown 标题（#、##、###）、加粗（**）、分隔线（---、===）和任何列表符号
                - 事件标题必须独立成行，标题内不得再嵌套「大事件N：」这类前缀

                ⚠️ 小事件写作核心要求：
                1. 每个小事件必须是独立完整的情节单元，不是大事件的一个执行步骤
                2. 禁止将单个事件拆成时序步骤（例如“前往→发现→战斗→撤退”这种只算1个小事件）
                3. 每个小事件应引入新的角色、地点、冲突或转折，而不是单纯推进上一个事件
                4. 好小事件 = 场景 + 冲突 + 变化，差小事件 = 下一个动作步骤
                5. 小事件组合起来必须完整覆盖该大事件概述里的全部关键情节、转折、场面、人物与伏笔，
                   不得跳过或省略概述中明确写到的事；不能只写概述的开头几段就收尾
                6. 伏笔只做短线：本块涉及的伏笔必须能在 5 个大事件之内回收，不要设计长线伏笔；
                   已经回收的伏笔不要再写

                注意：
                - 只输出当前这一幕的内容，不要输出其他幕
                - 本块需按顺序输出编号为「大事件%d」至「大事件%d」的大事件，每个大事件只允许输出一次
                - 编号只允许出现在标题行：大事件概述、小事件概要等正文里严禁出现任何章节号 /
                  事件编号引用（「第54章」「第54个事件」「大事件54」「小事件12」「54与70埋的」等）。
                  写伏笔照应时直接写出内容本身（人物、旧物件、原话、场景），不要写「第几章埋的伏笔」；
                  只读这一段的人也应当看得懂指的是什么
                - 严禁重复或回显任何已出现的大事件（包括全局框架中其他事件、前一块已展开的详细内容）
                - 保持大事件标题和概述与已有框架完全一致，不得自行改写、压缩或合并大事件
                - 小事件要有递进关系，禁止平铺流水账
                - 参照全局框架中其他幕的人物状态与伏笔，避免前后矛盾
                - 承接前文：若提供了「前一块已展开的详细内容」，本块开头必须紧接其最后一场戏的结尾状态
                - 铺垫后文：若提供了「紧接着的下一块大事件」，本块结尾要为其埋下伏笔、做好状态过渡
                """.formatted(
                chunk.actIndex() + 1, chunk.actName(),
                str(body, "genre"), str(body, "theme"), str(body, "protagonist"), str(body, "worldview"),
                title, extraSection(body), globalSummary, previousSection, laterSection, chunk.content(),
                minorCount, formatExample, chunk.startIndex(), chunk.endIndex()
        );
    }

    // ───────────────────────────── 批处理 / 渲染 ─────────────────────────────

    private List<Batch> buildBatches(List<Act> acts) {
        int total = countEvents(acts);
        int batchSize = calcBatchSize(total);
        List<Batch> batches = new ArrayList<>();
        for (int i = 0; i < acts.size(); i++) {
            List<Event> events = acts.get(i).events();
            for (int start = 0; start < events.size(); start += batchSize) {
                int end = Math.min(start + batchSize, events.size());
                batches.add(new Batch(i, start, new ArrayList<>(events.subList(start, end))));
            }
        }
        return batches;
    }

    private int calcBatchSize(int total) {
        int s = (int) Math.ceil(total / 10.0);
        return Math.min(5, Math.max(2, s));
    }

    private int countLedgerBatches(int totalBatches) {
        int count = 0;
        for (int b = 0; b < totalBatches; b++) {
            if (needsLedger(b, totalBatches)) count++;
        }
        return count;
    }

    private boolean needsLedger(int batchIndex, int totalBatches) {
        return batchIndex == totalBatches - 1 || (batchIndex + 1) % LEDGER_INTERVAL == 0;
    }

    private List<Chunk> buildChunks(List<Act> acts) {
        List<Chunk> chunks = new ArrayList<>();
        int globalIndex = 0;
        for (int actIndex = 0; actIndex < acts.size(); actIndex++) {
            Act act = acts.get(actIndex);
            List<Event> events = act.events();
            for (int start = 0; start < events.size(); start += MAX_EVENTS_PER_CHUNK) {
                int end = Math.min(start + MAX_EVENTS_PER_CHUNK, events.size());
                int chunkStart = globalIndex + 1;
                StringBuilder content = new StringBuilder();
                for (int i = start; i < end; i++) {
                    globalIndex++;
                    Event event = events.get(i);
                    if (content.length() > 0) content.append("\n\n");
                    content.append(formatMajorHeader(globalIndex, event.title())).append('\n').append(event.summary());
                }
                chunks.add(new Chunk(actIndex, start / MAX_EVENTS_PER_CHUNK,
                        act.name(), actName(actIndex), content.toString(), chunkStart, globalIndex));
            }
        }
        return chunks;
    }

    private String renderNextSkeleton(List<Act> acts, Chunk chunk) {
        int globalIndex = 0;
        StringBuilder out = new StringBuilder();
        for (int actIndex = 0; actIndex < acts.size(); actIndex++) {
            for (Event event : acts.get(actIndex).events()) {
                globalIndex++;
                if (globalIndex < chunk.startIndex() || globalIndex > chunk.endIndex()) continue;
                out.append(formatMajorHeader(globalIndex, event.title())).append('\n')
                        .append(event.summary()).append("\n\n");
            }
        }
        return out.toString().trim();
    }

    private String renderChunkFallback(Chunk chunk) {
        return chunk.content().trim();
    }

    private void applyRefinedBatch(List<Act> acts, Batch batch, JsonNode events) {
        Act old = acts.get(batch.actIndex());
        List<Event> newEvents = new ArrayList<>(old.events());
        for (int i = 0; i < batch.events().size(); i++) {
            JsonNode node = events.get(i);
            String title = text(node, "title");
            String summary = text(node, "summary");
            if (title.isEmpty()) title = batch.events().get(i).title();
            if (summary.isEmpty()) summary = batch.events().get(i).summary();
            newEvents.set(batch.startInAct() + i, new Event(title, summary));
        }
        acts.set(batch.actIndex(), new Act(old.name(), newEvents));
    }

    private String renderBatch(Batch batch, List<Act> acts, boolean refined) {
        StringBuilder out = new StringBuilder();
        List<Event> current = acts.get(batch.actIndex()).events();
        for (int i = 0; i < batch.events().size(); i++) {
            Event event = refined ? current.get(batch.startInAct() + i) : batch.events().get(i);
            out.append(refined ? "标题：" : "标题：").append(event.title()).append('\n')
                    .append(refined ? "概述：" : "定位：").append(event.summary()).append("\n\n");
        }
        return out.toString().trim();
    }

    private String renderActs(List<Act> acts, boolean withNumbers) {
        StringBuilder out = new StringBuilder();
        int index = 0;
        for (int i = 0; i < acts.size(); i++) {
            out.append("══ ").append(actLabel(acts.get(i).name(), i)).append(" ══\n\n");
            for (Event event : acts.get(i).events()) {
                index++;
                out.append(withNumbers ? formatMajorHeader(index, event.title()) : event.title()).append('\n')
                        .append(event.summary()).append("\n\n");
            }
        }
        return out.toString().trim();
    }

    private static String formatMajorHeader(int index, String title) {
        return "══ 大事件" + index + "：" + stripNumberPrefix(title) + " ══";
    }

    private static String stripNumberPrefix(String title) {
        String text = title == null ? "" : title.trim();
        for (int i = 0; i < 3; i++) {
            text = text.replaceAll("^[\\s═=＝*_]+", "").replaceAll("[\\s═=＝*_]+$", "")
                    .replaceAll("^(?:大事件|小事件|Major|事件)\\s*[0-9]+\\s*[：:]\\s*", "");
        }
        return text.trim();
    }

    private String actLabel(String name, int index) {
        String text = name == null ? "" : name.trim();
        if (text.isBlank()) {
            String[] defaults = {"第一幕：开端", "第二幕：发展", "第三幕：高潮&结局"};
            return index < defaults.length ? defaults[index] : "第" + (index + 1) + "幕";
        }
        return text;
    }

    private String actName(int index) {
        String[] names = {"第一幕", "第二幕", "第三幕"};
        return index < names.length ? names[index] : "第" + (index + 1) + "幕";
    }

    private static String actHeader(int index) {
        String[] headers = {"第一幕：开端", "第二幕：发展", "第三幕：高潮&结局"};
        return index < headers.length ? headers[index] : "第" + (index + 1) + "幕";
    }

    private List<Act> parseActs(JsonNode actsNode) {
        List<Act> acts = new ArrayList<>();
        if (actsNode == null || !actsNode.isArray()) return acts;
        int i = 0;
        for (JsonNode actNode : actsNode) {
            String name = text(actNode, "name");
            if (name.isBlank()) name = actHeader(i);
            List<Event> events = new ArrayList<>();
            for (JsonNode eventNode : actNode.path("events")) {
                String title = text(eventNode, "title");
                if (title.isBlank()) continue;
                String summary = text(eventNode, "summary");
                if (summary.isBlank()) summary = text(eventNode, "position");
                events.add(new Event(stripNumberPrefix(title), summary));
            }
            if (!events.isEmpty()) acts.add(new Act(name, events));
            i++;
        }
        return acts;
    }

    private List<Map<String, Object>> parseChapters(String text) {
        List<Map<String, Object>> rows = new ArrayList<>();
        int index = 0;
        String type = null;
        String title = null;
        StringBuilder summary = new StringBuilder();

        for (String raw : text.split("\n")) {
            String line = raw.trim();
            boolean isAct = line.matches("^[═=＝\\s]*第[一二三四五六七八九十百0-9]+幕.*$");
            boolean isMajor = line.contains("大事件") && line.matches("^[═=＝\\s]*大事件\\s*[0-9]+\\s*[：:].*$");
            boolean isMinor = line.matches("^[○◦◯oO]?\\s*小事件\\s*[0-9]+\\s*[：:].*$");
            if (isAct) {
                if (title != null) {
                    index++;
                    rows.add(chapterRow(index, type, title, summary));
                }
                type = null;
                title = null;
                summary = new StringBuilder();
                continue;
            }
            if (isMajor || isMinor) {
                if (title != null) {
                    index++;
                    rows.add(chapterRow(index, type, title, summary));
                }
                type = isMajor ? "major" : "minor";
                title = cleanupSectionTitle(line, isMajor ? "大事件" : "小事件");
                summary = new StringBuilder();
                continue;
            }
            if (title != null && !line.isEmpty()) {
                summary.append(line).append('\n');
            }
        }
        if (title != null) {
            index++;
            rows.add(chapterRow(index, type, title, summary));
        }
        return rows;
    }

    private static Map<String, Object> chapterRow(int index, String type, String title, StringBuilder summary) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("index", index);
        row.put("type", type == null ? "major" : type);
        row.put("title", title == null ? "" : title);
        row.put("summary", summary.toString().trim());
        return row;
    }

    private static String cleanupSectionTitle(String line, String prefix) {
        String text = line
                .replaceAll("^[═=＝\\s]+", "")
                .replaceAll("[═=＝\\s]+$", "")
                .trim();
        text = text.replaceFirst("^[○◦◯oO]\\s*", "");
        text = text.replaceFirst("^" + prefix + "\\s*[0-9]+\\s*[：:]\\s*", "");
        return text.trim();
    }

    // ───────────────────────────── AI / JSON / 工具 ─────────────────────────────

    private String streamText(String system, String user, Sink sink, AiSettings settings) throws IOException {
        return streamText(system, user, sink, settings, false);
    }

    private String streamText(String system, String user, Sink sink, AiSettings settings, boolean textMode) throws IOException {
        StringBuilder buffer = new StringBuilder();
        var stream = settings != null && settings.jsonMode()
                ? ai.streamJson(system, user, settings)
                : ai.stream(system, user, settings);
        for (String delta : stream.toIterable()) {
            buffer.append(delta);
            sink.delta(delta);
        }
        return buffer.toString();
    }

    private static AiSettings jsonSettings(AiSettings settings, double temperature) {
        AiSettings effective = settings == null
                ? new AiSettings("", temperature, 4096, null)
                : new AiSettings(settings.model(), temperature, settings.maxTokens(), null);
        return AiSettings.jsonOnly(effective);
    }

    private static AiSettings textSettings(AiSettings settings) {
        if (settings == null) return new AiSettings("", 0.8, 4096, null);
        return new AiSettings(settings.model(), settings.temperature(), settings.maxTokens(), null);
    }

    private static String textSystem(AiSettings settings) {
        if (settings != null && settings.systemPrompt() != null && !settings.systemPrompt().isBlank()) {
            return settings.systemPrompt().trim();
        }
        return TEXT_SYSTEM;
    }

    private static JsonNode readObject(String raw, String errorMessage) {
        String text = raw == null ? "" : raw.trim();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start >= 0 && end > start) text = text.substring(start, end + 1);
        try {
            JsonNode node = MODEL_MAPPER.readTree(text);
            if (node == null || !node.isObject()) throw new ApiException(502, errorMessage);
            return node;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(502, errorMessage + "：" + abbreviate(text));
        }
    }

    private static String extraSection(Map<String, Object> body) {
        String extra = str(body, "extra");
        if (extra.isBlank()) return "";
        return "=== 额外要求（必须严格遵守；与上述设定或规则冲突时以本要求为准） ===\n"
                + extra + "\n\n";
    }

    private static String str(Map<String, Object> body, String key) {
        Object value = body == null ? null : body.get(key);
        return value == null ? "" : String.valueOf(value).trim();
    }

    private static String abbreviate(String value) {
        if (value == null) return "";
        return value.length() > 500 ? value.substring(0, 500) + "…" : value;
    }

    private static String text(JsonNode node, String field) {
        JsonNode value = node == null ? null : node.get(field);
        return value == null || value.isNull() ? "" : value.asText("").trim();
    }

    private static int intVal(Object value, int fallback) {
        if (value instanceof Number number) return number.intValue();
        try {
            return Integer.parseInt(String.valueOf(value));
        } catch (Exception ignored) {
            return fallback;
        }
    }

    private static int clamp(int value, int min, int max) {
        return Math.min(Math.max(value, min), max);
    }

    private static int countEvents(List<Act> acts) {
        int count = 0;
        for (Act act : acts) count += act.events().size();
        return count;
    }

    private static void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static List<Act> cloneActs(List<Act> acts) {
        List<Act> copy = new ArrayList<>();
        for (Act act : acts) copy.add(new Act(act.name(), new ArrayList<>(act.events())));
        return copy;
    }

    private static final class Ledger {
        private final List<Map<String, String>> foreshadows = new ArrayList<>();
        private final List<String> characters = new ArrayList<>();
        private final List<String> unresolved = new ArrayList<>();

        void merge(JsonNode root) {
            Set<String> seen = new LinkedHashSet<>();
            for (Map<String, String> item : foreshadows) seen.add(item.getOrDefault("content", ""));
            JsonNode fs = root.path("foreshadows");
            if (fs.isArray()) {
                for (JsonNode node : fs) {
                    String content = text(node, "content");
                    if (content.isBlank()) continue;
                    String status = text(node, "status");
                    if (status.contains("已回收") || status.contains("已实现") || status.contains("已兑现")) {
                        foreshadows.removeIf(item -> content.equals(item.get("content")));
                        continue;
                    }
                    Map<String, String> item = new LinkedHashMap<>();
                    item.put("content", content);
                    item.put("status", status.isBlank() ? "已埋" : status);
                    item.put("plan", text(node, "plan"));
                    if (!seen.contains(content)) foreshadows.add(item);
                }
            }
            List<String> chars = stringList(root.path("character_states"));
            if (!chars.isEmpty()) {
                characters.clear();
                characters.addAll(chars);
            }
            List<String> unresolvedItems = stringList(root.path("unresolved"));
            if (!unresolvedItems.isEmpty()) {
                unresolved.clear();
                unresolved.addAll(unresolvedItems);
            }
        }

        String render() {
            if (foreshadows.isEmpty() && characters.isEmpty() && unresolved.isEmpty()) return "（暂无）";
            StringBuilder out = new StringBuilder();
            if (!foreshadows.isEmpty()) {
                out.append("伏笔：\n");
                for (Map<String, String> item : foreshadows) {
                    out.append("- ").append(item.getOrDefault("content", ""))
                            .append("（状态：").append(item.getOrDefault("status", "已埋"))
                            .append(" / 计划：").append(item.getOrDefault("plan", "未定")).append("）\n");
                }
            }
            if (!characters.isEmpty()) {
                out.append("角色状态：\n");
                for (String item : characters) out.append("- ").append(item).append('\n');
            }
            if (!unresolved.isEmpty()) {
                out.append("未解决悬念：\n");
                for (String item : unresolved) out.append("- ").append(item).append('\n');
            }
            return out.toString().trim();
        }

        Map<String, Object> toMap() {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("foreshadows", foreshadows);
            out.put("characters", characters);
            out.put("unresolved", unresolved);
            return out;
        }

        private static List<String> stringList(JsonNode node) {
            List<String> list = new ArrayList<>();
            if (node != null && node.isArray()) {
                for (JsonNode item : node) {
                    String value = item.asText("").trim();
                    if (!value.isEmpty()) list.add(value);
                }
            }
            return list;
        }
    }
}
