package com.deepseekapp.webserver.feature.agent.context;

/**
 * 粗略 token 估算：DeepSeek 的 tokenizer 未公开，用「中文 1 字 ≈ 1 token、其余 1 token ≈ 3.5 字符」
 * 的经验值。只用于压缩前的压力判断和首帧展示，真实值以 API 返回的 usage 为准。
 */
public final class TokenEstimator {

    /** 单条消息的固定开销（role、分隔符等）。 */
    public static final int MESSAGE_OVERHEAD = 4;

    private TokenEstimator() {
    }

    public static int estimate(String text) {
        if (text == null || text.isEmpty()) {
            return 0;
        }
        int cjk = 0;
        int other = 0;
        for (int i = 0; i < text.length(); ) {
            int codePoint = text.codePointAt(i);
            if (isCjk(codePoint)) {
                cjk++;
            } else {
                other++;
            }
            i += Character.charCount(codePoint);
        }
        return cjk + (int) Math.ceil(other / 3.5);
    }

    public static int estimateMessage(String content) {
        return estimate(content) + MESSAGE_OVERHEAD;
    }

    private static boolean isCjk(int codePoint) {
        return (codePoint >= 0x3000 && codePoint <= 0x303F)
                || (codePoint >= 0x3040 && codePoint <= 0x30FF)
                || (codePoint >= 0x3400 && codePoint <= 0x4DBF)
                || (codePoint >= 0x4E00 && codePoint <= 0x9FFF)
                || (codePoint >= 0xAC00 && codePoint <= 0xD7AF)
                || (codePoint >= 0xF900 && codePoint <= 0xFAFF)
                || (codePoint >= 0xFF00 && codePoint <= 0xFFEF);
    }
}
