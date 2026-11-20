package com.deepseekapp.webserver.feature.rag.service;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 章节识别的内置规则与 AI 兜底。 */
class RagDocumentParserTest {

    private static final String NOVEL = """
            ◆ 卷一 风起

            正文一

            ◆ 卷二 云涌

            正文二

            ◆ 卷三 归途

            正文三
            """;

    @Test
    void aiPatternIsUsedWhenBuiltInRulesMiss() {
        RagDocumentParser.ParsedDocument plain = RagDocumentParser.parse(NOVEL, 12000, 1500);
        assertTrue(plain.chapters().isEmpty());
        assertEquals(6, plain.paragraphs().size());

        RagDocumentParser.ParsedDocument parsed =
                RagDocumentParser.parse(NOVEL, 12000, 1500, "^◆\\s*卷.*$");

        assertEquals(3, parsed.chapters().size());
        assertEquals("AI 识别", parsed.chapterPattern());
        assertEquals("◆ 卷一 风起", parsed.chapters().get(0).title());
    }

    @Test
    void invalidAiPatternFallsBackToParagraphWindows() {
        RagDocumentParser.ParsedDocument parsed = RagDocumentParser.parse(NOVEL, 12000, 1500, "(");

        assertTrue(parsed.chapters().isEmpty());
        assertEquals(1, parsed.windows().size());
    }

    @Test
    void greedyAiPatternIsRejected() {
        RagDocumentParser.ParsedDocument parsed = RagDocumentParser.parse(NOVEL, 12000, 1500, ".*");

        assertTrue(parsed.chapters().isEmpty());
    }
}
