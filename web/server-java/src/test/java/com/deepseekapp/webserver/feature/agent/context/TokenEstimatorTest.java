package com.deepseekapp.webserver.feature.agent.context;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 粗略 token 估算：中文按字、英文按 3.5 字符一个 token。 */
class TokenEstimatorTest {

    @Test
    void emptyTextHasNoTokens() {
        assertEquals(0, TokenEstimator.estimate(null));
        assertEquals(0, TokenEstimator.estimate(""));
    }

    @Test
    void chineseCountsOneTokenPerCharacter() {
        assertEquals(4, TokenEstimator.estimate("你好世界"));
    }

    @Test
    void englishIsCheaperThanCharacterCount() {
        int tokens = TokenEstimator.estimate("hello world");
        assertEquals(4, tokens);
        assertTrue(tokens < "hello world".length());
    }

    @Test
    void mixedTextAddsUp() {
        // 2 个中文字 + " world" 6 个非中文字符（ceil(6/3.5)=2）
        assertEquals(4, TokenEstimator.estimate("你好 world"));
    }

    @Test
    void messageAddsProtocolOverhead() {
        assertEquals(TokenEstimator.estimate("你好") + TokenEstimator.MESSAGE_OVERHEAD,
                TokenEstimator.estimateMessage("你好"));
    }
}
