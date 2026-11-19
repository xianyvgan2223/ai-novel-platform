import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/domain/chat_message.dart';

/// 每条回答自己的缓存命中率来自「产生它的那次请求」的 usage。
void main() {
  const request = ChatMessage(
    role: MessageRole.assistant,
    content: '回答',
    timestamp: '2026-11-17T15:00:00',
    promptTokens: 3010,
    cachedTokens: 2816,
    completionTokens: 3,
  );

  test('缓存命中率按这条消息那次请求计算', () {
    expect(request.cachePercent, 94);
  });

  test('没有 usage 的旧消息返回 null（界面显示「缓存命中 —」）', () {
    const old = ChatMessage(
      role: MessageRole.assistant,
      content: '旧的回答',
      timestamp: '2026-11-01T00:00:00',
    );
    expect(old.cachePercent, isNull);
    expect(old.promptTokens, 0);
  });

  test('copyWith 保留 usage，避免入库后丢失', () {
    final saved = request.copyWith(id: 7);
    expect(saved.id, 7);
    expect(saved.promptTokens, 3010);
    expect(saved.cachedTokens, 2816);
  });
}
