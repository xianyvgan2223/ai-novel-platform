package com.deepseekapp.webserver.feature.rag.service;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 小说文本的结构化解析：格式检测 → 段落重建 → 章节识别 → 情节弧窗口。
 *
 * <p>不依赖某一种 txt 排版：
 * <ul>
 *   <li>有空行：按空行分段；</li>
 *   <li>一行一段（无空行）：按单换行分段；</li>
 *   <li>整篇没有换行：先按句子切，再组段。</li>
 * </ul>
 *
 * <p>识别到章节时按「章」组窗口（绝不跨章切）；没有章节时按段落组窗口。
 * 窗口之间按字符数重叠，保证跨窗口的完整情节至少在一个窗口里完整出现。</p>
 */
public final class RagDocumentParser {

    public enum ParagraphFormat {
        BLANK_LINE("空行分段"),
        SINGLE_NEWLINE("单换行分段"),
        WHOLE_TEXT("整篇无换行");

        private final String label;

        ParagraphFormat(String label) {
            this.label = label;
        }

        public String label() {
            return label;
        }
    }

    public record Chapter(int index, String title, int paragraphStart, int paragraphEnd) {
    }

    public record Window(int index, String title, String chapterRange, int chars, String text) {
    }

    public record ParsedDocument(ParagraphFormat format, String chapterPattern,
                                 List<String> paragraphs, List<Chapter> chapters,
                                 List<Window> windows, int totalChars, String text) {
    }

    private record PatternDef(String name, Pattern pattern, boolean needMonotonic) {
    }

    /** 章节标题候选：从强到弱，命中数量与编号单调性共同决定用哪个。 */
    private static final List<PatternDef> CHAPTER_PATTERNS = List.of(
            new PatternDef("第X回/章/节",
                    Pattern.compile("^第[0-9零〇一二三四五六七八九十百千万两]+[章回节]\\s*[、:：.．\\-]?\\s*\\S.{0,60}$"), false),
            new PatternDef("Chapter N",
                    Pattern.compile("(?i)^chapter\\s+\\d{1,4}\\b.{0,60}$"), true),
            new PatternDef("数字标题",
                    Pattern.compile("^\\d{1,4}[、.．]\\s*\\S.{0,60}$"), true)
    );

    private static final int MAX_HEADING_CHARS = 85;
    private static final int LONG_PARAGRAPH_CHARS = 1800;
    private static final int MAX_WINDOWS = 400;
    private static final int MAX_CHAPTERS_PER_WINDOW = 12;

    private RagDocumentParser() {
    }

    /** 清洗文本（编码解码由调用方完成）。 */
    public static String normalize(String input) {
        if (input == null) {
            return "";
        }
        String text = input.replace("\r\n", "\n").replace('\r', '\n').replace("\u0000", "");
        text = text.replace("\uFEFF", "");
        // 常见 txt 里混入的 HTML 标签
        text = text.replaceAll("<[^>\\n]{1,200}>", "");
        text = text.replaceAll("[\t ]+", " ");
        text = text.replaceAll("\\n{3,}", "\n\n");
        return text.trim();
    }

    /**
     * 解析全文。
     *
     * @param rawText      原始文本（未清洗也可以）
     * @param windowChars  单个情节弧窗口的目标字符数
     * @param overlapChars 相邻窗口重叠字符数
     */
    public static ParsedDocument parse(String rawText, int windowChars, int overlapChars) {
        String text = normalize(rawText);
        int target = Math.max(2000, windowChars);
        int overlap = Math.max(0, Math.min(overlapChars, target / 2));

        ParagraphFormat format = detectFormat(text);
        List<String> paragraphs = splitParagraphs(text, format);
        if (paragraphs.isEmpty()) {
            return new ParsedDocument(format, "", List.of(), List.of(), List.of(), text.length(), text);
        }

        ChapterMatch match = detectChapters(paragraphs);
        List<Chapter> chapters = match == null ? List.of() : buildChapters(paragraphs, match);
        List<Window> windows = chapters.isEmpty()
                ? buildParagraphWindows(paragraphs, target, overlap)
                : buildChapterWindows(paragraphs, chapters, target, overlap);

        return new ParsedDocument(format, match == null ? "" : match.def().name(),
                paragraphs, chapters, windows, text.length(), text);
    }

    public static int maxWindows() {
        return MAX_WINDOWS;
    }

    // ── 格式检测与段落重建 ──

    static ParagraphFormat detectFormat(String text) {
        String[] blankParts = text.split("\\n\\s*\\n");
        int blankParagraphs = 0;
        for (String part : blankParts) {
            if (!part.trim().isEmpty()) {
                blankParagraphs++;
            }
        }
        String[] lines = text.split("\\n");
        int nonEmptyLines = 0;
        List<Integer> lineLengths = new ArrayList<>();
        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) {
                continue;
            }
            nonEmptyLines++;
            lineLengths.add(trimmed.length());
        }
        if (blankParagraphs >= 3) {
            return ParagraphFormat.BLANK_LINE;
        }
        if (nonEmptyLines >= 30) {
            // 一行一段的网文：没有空行，但行数很多
            return ParagraphFormat.SINGLE_NEWLINE;
        }
        if (nonEmptyLines <= 1) {
            return ParagraphFormat.WHOLE_TEXT;
        }
        return ParagraphFormat.SINGLE_NEWLINE;
    }

    static List<String> splitParagraphs(String text, ParagraphFormat format) {
        List<String> result = new ArrayList<>();
        if (format == ParagraphFormat.BLANK_LINE) {
            for (String part : text.split("\\n\\s*\\n")) {
                String trimmed = part.trim();
                if (!trimmed.isEmpty()) {
                    result.add(trimmed);
                }
            }
        } else if (format == ParagraphFormat.SINGLE_NEWLINE) {
            for (String line : text.split("\\n")) {
                String trimmed = line.trim();
                if (!trimmed.isEmpty()) {
                    result.add(trimmed);
                }
            }
        } else {
            result.add(text.trim());
        }
        // 超长段落先按句子切成小段，窗口才能落在句子边界
        List<String> split = new ArrayList<>(result.size());
        for (String paragraph : result) {
            if (paragraph.length() <= LONG_PARAGRAPH_CHARS) {
                split.add(paragraph);
            } else {
                split.addAll(splitSentences(paragraph, LONG_PARAGRAPH_CHARS));
            }
        }
        return split;
    }

    // ── 章节识别 ──

    private record ChapterMatch(PatternDef def, List<Integer> positions) {
    }

    private static ChapterMatch detectChapters(List<String> paragraphs) {
        ChapterMatch best = null;
        int bestScore = 0;
        for (PatternDef def : CHAPTER_PATTERNS) {
            List<Integer> positions = new ArrayList<>();
            for (int i = 0; i < paragraphs.size(); i++) {
                String p = paragraphs.get(i).trim();
                if (p.isEmpty() || p.length() > MAX_HEADING_CHARS) {
                    continue;
                }
                if (p.endsWith("。") || p.endsWith("！") || p.endsWith("？")) {
                    continue;
                }
                if (def.pattern().matcher(p).matches()) {
                    positions.add(i);
                }
            }
            if (positions.size() < 3) {
                continue;
            }
            if (def.needMonotonic() && !monotonic(paragraphs, positions)) {
                continue;
            }
            int score = positions.size() * 10 + (def.name().startsWith("第X") ? 2 : 0);
            if (score > bestScore) {
                bestScore = score;
                best = new ChapterMatch(def, positions);
            }
        }
        return best;
    }

    /** 阿拉伯数字标题检查编号递增，避免把列表项误判成章节。 */
    private static boolean monotonic(List<String> paragraphs, List<Integer> positions) {
        int last = -1;
        int checked = 0;
        for (int pos : positions) {
            String p = paragraphs.get(pos).trim();
            Matcher m = Pattern.compile("^(?:chapter\\s+)?(\\d{1,4})").matcher(p);
            if (!m.find()) {
                continue;
            }
            int number = Integer.parseInt(m.group(1));
            if (number <= last) {
                return false;
            }
            last = number;
            checked++;
        }
        return checked >= 3;
    }

    private static List<Chapter> buildChapters(List<String> paragraphs, ChapterMatch match) {
        List<Chapter> chapters = new ArrayList<>();
        List<Integer> starts = match.positions();
        if (starts.get(0) > 0) {
            int preambleChars = 0;
            for (int i = 0; i < starts.get(0); i++) {
                preambleChars += paragraphs.get(i).length();
            }
            if (preambleChars >= 100) {
                chapters.add(new Chapter(0, "前言", 0, starts.get(0) - 1));
            }
        }
        for (int i = 0; i < starts.size(); i++) {
            int start = starts.get(i);
            int end = (i + 1 < starts.size() ? starts.get(i + 1) - 1 : paragraphs.size() - 1);
            if (end < start) {
                continue;
            }
            String title = paragraphs.get(start).trim();
            if (title.length() > 60) {
                title = title.substring(0, 60) + "…";
            }
            chapters.add(new Chapter(chapters.size(), title, start, end));
        }
        return chapters;
    }

    // ── 窗口构建 ──

    private static List<Window> buildChapterWindows(List<String> paragraphs, List<Chapter> chapters,
                                                    int target, int overlap) {
        List<Window> windows = new ArrayList<>();
        String prefix = "";
        int start = 0;
        while (start < chapters.size()) {
            int end = start;
            int chars = 0;
            while (end < chapters.size()) {
                int chapterChars = chapterChars(paragraphs, chapters.get(end));
                if (end > start && chars + chapterChars > target) {
                    break;
                }
                if (end > start && end - start >= MAX_CHAPTERS_PER_WINDOW) {
                    break;
                }
                chars += chapterChars;
                end++;
                if (chars >= target) {
                    break;
                }
            }
            if (end <= start) {
                end = start + 1;
            }
            // 单章过长：在章内部按句末切，避免一次 prompt 过大
            if (end - start == 1 && chapterChars(paragraphs, chapters.get(start)) > target * 2) {
                String chapterText = chapterText(paragraphs, chapters.get(start));
                List<String> parts = splitSentences(chapterText, target);
                String subPrefix = prefix;
                int subStart = 0;
                int partIndex = 0;
                while (subStart < parts.size()) {
                    int subEnd = subStart;
                    int subChars = 0;
                    while (subEnd < parts.size()) {
                        int len = parts.get(subEnd).length();
                        if (subEnd > subStart && subChars + len + 2 > target) {
                            break;
                        }
                        subChars += len + (subEnd > subStart ? 2 : 0);
                        subEnd++;
                        if (subChars >= target) {
                            break;
                        }
                    }
                    if (subEnd <= subStart) {
                        subEnd = subStart + 1;
                    }
                    String body = String.join("\n\n", parts.subList(subStart, subEnd));
                    String text = subPrefix.isEmpty() ? body : subPrefix + "\n\n" + body;
                    String title = chapters.get(start).title() + "（续" + (partIndex + 1) + "）";
                    windows.add(new Window(windows.size(), title, title, text.length(), text));
                    partIndex++;
                    subPrefix = tailText(body, overlap);
                    subStart = subEnd;
                }
                prefix = subPrefix;
                start++;
                continue;
            }

            String chapterBody = chapterRangeText(paragraphs, chapters, start, end - 1);
            String text = prefix.isEmpty() ? chapterBody : prefix + "\n\n" + chapterBody;
            String title = chapters.get(start).title();
            if (end - 1 > start) {
                title = title + " … " + chapters.get(end - 1).title();
            }
            windows.add(new Window(windows.size(), title, chapterRangeLabel(chapters, start, end - 1),
                    text.length(), text));
            prefix = tailText(chapterBody, overlap);
            start = end;
        }
        return windows;
    }

    private static List<Window> buildParagraphWindows(List<String> paragraphs, int target, int overlap) {
        List<Window> windows = new ArrayList<>();
        String prefix = "";
        int start = 0;
        while (start < paragraphs.size()) {
            int end = start;
            int chars = 0;
            while (end < paragraphs.size()) {
                int len = paragraphs.get(end).length();
                if (end > start && chars + len + 2 > target) {
                    break;
                }
                chars += len + (end > start ? 2 : 0);
                end++;
                if (chars >= target) {
                    break;
                }
            }
            if (end <= start) {
                end = start + 1;
            }
            String body = String.join("\n\n", paragraphs.subList(start, end));
            String text = prefix.isEmpty() ? body : prefix + "\n\n" + body;
            String title = "片段 " + (windows.size() + 1) + "（第 " + (start + 1) + "~" + end + " 段）";
            windows.add(new Window(windows.size(), title, "", text.length(), text));
            prefix = tailText(body, overlap);
            start = end;
        }
        return windows;
    }

    /**
     * 取一段文本末尾的若干字符作为下一窗口的重叠前缀。
     * 尽量从句子开头截，避免下一窗口以半句话开头。
     */
    private static String tailText(String text, int maxChars) {
        if (maxChars <= 0 || text == null || text.isBlank()) {
            return "";
        }
        String trimmed = text.trim();
        if (trimmed.length() <= maxChars) {
            return trimmed;
        }
        String tail = trimmed.substring(trimmed.length() - maxChars);
        int firstSentenceEnd = -1;
        int limit = Math.min(tail.length(), 200);
        for (int i = 0; i < limit; i++) {
            char c = tail.charAt(i);
            if (c == '。' || c == '！' || c == '？' || c == '!' || c == '?' || c == '…' || c == '；' || c == ';') {
                firstSentenceEnd = i + 1;
                break;
            }
        }
        if (firstSentenceEnd > 0 && firstSentenceEnd < tail.length()) {
            tail = tail.substring(firstSentenceEnd);
        }
        return tail.trim();
    }

    private static int chapterChars(List<String> paragraphs, Chapter chapter) {
        int chars = 0;
        for (int i = chapter.paragraphStart(); i <= chapter.paragraphEnd() && i < paragraphs.size(); i++) {
            chars += paragraphs.get(i).length() + 2;
        }
        return chars;
    }

    private static String chapterText(List<String> paragraphs, Chapter chapter) {
        int from = Math.max(0, chapter.paragraphStart());
        int to = Math.min(paragraphs.size() - 1, chapter.paragraphEnd());
        return String.join("\n\n", paragraphs.subList(from, to + 1));
    }

    private static String chapterRangeText(List<String> paragraphs, List<Chapter> chapters, int start, int end) {
        StringBuilder builder = new StringBuilder();
        for (int i = start; i <= end; i++) {
            if (builder.length() > 0) {
                builder.append("\n\n");
            }
            builder.append(chapterText(paragraphs, chapters.get(i)));
        }
        return builder.toString();
    }

    private static String chapterRangeLabel(List<Chapter> chapters, int start, int end) {
        if (start == end) {
            return chapters.get(start).title();
        }
        String label = chapters.get(start).title() + " ~ " + chapters.get(end).title();
        return label.length() > 100 ? label.substring(0, 100) + "…" : label;
    }

    // ── 句子切分 ──

    /** 按句末标点切成若干段，每段不超过 maxChars；用于超长段落/超长章内部再切。 */
    public static List<String> splitSentences(String text, int maxChars) {
        List<String> sentences = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        int limit = Math.max(200, maxChars);
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            current.append(c);
            boolean end = c == '。' || c == '！' || c == '？' || c == '!' || c == '?'
                    || c == '…' || c == '；' || c == ';' || c == '\n';
            if (end) {
                String sentence = current.toString().trim();
                if (!sentence.isEmpty()) {
                    sentences.add(sentence);
                }
                current.setLength(0);
                continue;
            }
            if (current.length() >= limit) {
                String sentence = current.toString().trim();
                if (!sentence.isEmpty()) {
                    sentences.add(sentence);
                }
                current.setLength(0);
            }
        }
        String tail = current.toString().trim();
        if (!tail.isEmpty()) {
            sentences.add(tail);
        }
        if (sentences.isEmpty()) {
            sentences.add(text.trim());
        }
        return sentences;
    }
}
