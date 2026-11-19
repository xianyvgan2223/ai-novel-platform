/// 移动端上下文预算：与网页端 / DSH 的 compaction-basic 同一套公式。
///
/// 窗口 W、输出预留 O、余量 B 时：
///   触发阈值 = min(W × 0.8, W − O − B)，B 默认 65536；
///   保留预算 = (W − O) × 16%，即压缩后逐字保留的最近对话。
///
/// 只做纯计算，方便单测；真正的摘要调用在 ChatController 里。
class ChatContextBudget {
  /// DeepSeek Flash / Pro 的上下文长度（官方文档：1M）。
  static const int defaultWindow = 1000000;

  /// 压缩前给输出和工具留的余量。
  static const int headroomTokens = 65536;

  static const double thresholdRatio = 0.8;
  static const double retainRatio = 0.16;

  final int window;
  final int maxOutput;
  final int threshold;
  final int retain;

  const ChatContextBudget({
    required this.window,
    required this.maxOutput,
    required this.threshold,
    required this.retain,
  });

  factory ChatContextBudget.of({required int maxTokens, int? window}) {
    final w = (window == null || window < 1024) ? defaultWindow : window;
    final out = maxTokens < 0 ? 0 : maxTokens;
    final base = w - out < 1 ? 1 : w - out;

    final byRatio = (w * thresholdRatio).floor();
    final byReserve = w - out - headroomTokens;
    final raw = byRatio < byReserve ? byRatio : byReserve;
    // 小窗口（自定义模型）算出来可能 ≤ 0，至少给窗口 5% 的兜底
    final floorValue = (w * 0.05).round().clamp(1, base).toInt();
    final threshold = raw.clamp(1, base).toInt();
    final resolvedThreshold = threshold < floorValue ? floorValue : threshold;

    var retain = (base * retainRatio).floor().clamp(1, base).toInt();
    if (retain >= resolvedThreshold) {
      retain = (resolvedThreshold ~/ 2).clamp(1, base).toInt();
    }
    return ChatContextBudget(
      window: w,
      maxOutput: out,
      threshold: resolvedThreshold,
      retain: retain,
    );
  }

  bool needsCompaction(int tokens) => tokens >= threshold;

  int percent(int tokens) {
    if (tokens <= 0) return 0;
    final value = (tokens * 100 / window).round();
    return value > 100 ? 100 : value;
  }

  /// 从最近的对话往前累加，返回「需要保留的起始下标」。
  ///
  /// 至少保留最后一条消息；返回 0 表示整段对话都在保留预算内、无需压缩。
  static int keepFrom(List<int> messageTokens, int retain) {
    if (messageTokens.isEmpty) return 0;
    var kept = 0;
    var start = messageTokens.length;
    for (var i = messageTokens.length - 1; i >= 0; i--) {
      final tokens = messageTokens[i];
      if (kept + tokens > retain && start < messageTokens.length) {
        break;
      }
      kept += tokens;
      start = i;
    }
    return start;
  }
}

/// 粗略 token 估算：中文按字、其余按 3.5 字符一个 token。
///
/// 只用于压缩前的压力判断和首帧展示；真实值以 API 返回的 usage 为准。
int estimateTokens(String? text) {
  if (text == null || text.isEmpty) return 0;
  var cjk = 0;
  var other = 0;
  for (var i = 0; i < text.length;) {
    final code = text.codeUnitAt(i);
    if (_isCjk(code)) {
      cjk++;
    } else {
      other++;
    }
    // 代理对（emoji 等）算一个字符
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      i += 2;
    } else {
      i += 1;
    }
  }
  return cjk + (other / 3.5).ceil();
}

/// 单条消息的估算（含 role 等协议开销）。
int estimateMessageTokens(String? content) => estimateTokens(content) + 4;

bool _isCjk(int code) {
  return (code >= 0x3000 && code <= 0x303F) ||
      (code >= 0x3040 && code <= 0x30FF) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0xAC00 && code <= 0xD7AF) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFF00 && code <= 0xFFEF);
}

/// 模型标识 → 上下文窗口。官方 Flash / Pro 都是 1M；自定义模型按默认 1M 处理，
/// 用户可以在服务端/模型侧自行收敛，这里不做硬编码猜测。
int contextWindowForModel(String apiModelId) => ChatContextBudget.defaultWindow;
