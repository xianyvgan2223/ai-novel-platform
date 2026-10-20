import '../../shared/outline_event_syntax.dart';

/// 一个「骨架已定义好的大事件」在展开块里的标准输出。
class NormalizedChunkEvent {
  /// 块内位置（0-based）。最终编号 = 块的 `globalStartIndex + position`。
  final int position;

  /// 大事件标题：以骨架为准（模型把标题写偏/漏写也不影响结构）
  final String title;

  /// 大事件概述：以骨架为准（精写后的概述 / 用户在检查点编辑后的内容），
  /// **原样完整输出**——模型在展开阶段重新写的概述不再采用。
  final String summary;

  /// 模型输出里属于这个小事件的部分（从第一条「○ 小事件N」行开始；没有则为空）
  final String minorsBody;

  const NormalizedChunkEvent({
    required this.position,
    required this.title,
    required this.summary,
    required this.minorsBody,
  });
}

/// 展开块归一化：把模型输出与**骨架**合成为最终的大事件块。
///
/// 为什么要有它（用户报的问题）：
/// - 展开（步骤 3）的提示词让模型「写大事件概述」，模型会据此**重写/压缩**概述，
///   最终大纲里的大事件内容于是与精写定稿不一致、甚至漏掉内容；
/// - 模型偶尔少输出某个大事件块 / 标题写成别的：旧逻辑按「实际配到的块」重建，
///   编号用循环下标，缺一块后面全错位，缺的那条整条消失。
///
/// 现在的约定：
/// - **每个骨架大事件都输出**：标题、概述一律来自骨架（[expected] 入参），
///   缺块也补上概述；
/// - 模型只负责提供**小事件部分**（从第一条小事件行起）；它写的大事件概述、
///   开场白（「好的，遵照您的指示…」）、markdown 标记都不进最终正文；
/// - 编号按骨架位置（而不是循环下标）计算，保证连续、不跳号。
class OutlineChunkNormalizer {
  const OutlineChunkNormalizer._();

  /// 标题归一化键：去空白、去结尾标点，用于标题比对与跨块去重。
  static String titleKey(String title) => title
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[。．.！？!?，,、；;：:…~～]+$'), '');

  /// 归一化一个展开块。
  ///
  /// [expected] 是本块应有的大事件（标题 + 骨架概述，顺序即输出顺序）；
  /// [modelText] 是模型流式输出的原文；
  /// [alreadySeenTitles] 是前面块已经输出过的标题（跨块回显去重）。
  ///
  /// 返回 null 表示模型输出里**切不出任何大事件块**（格式完全不可用）：
  /// 调用方应保留原文，避免把整块内容丢掉。
  static List<NormalizedChunkEvent>? normalize({
    required List<({String title, String summary})> expected,
    required String modelText,
    Iterable<String> alreadySeenTitles = const [],
  }) {
    if (expected.isEmpty) return const [];
    final blocks = _splitBlocks(modelText);
    if (blocks.isEmpty) return null;

    final expectedKeys = [for (final e in expected) titleKey(e.title)];
    final seen = {for (final t in alreadySeenTitles) titleKey(t)};
    final placed = <int, ({String title, String body})>{};
    final used = <int>{};
    final unmatched = <({String title, String body})>[];

    for (final b in blocks) {
      final key = titleKey(b.title);
      if (key.isEmpty) continue;
      // 前面块已经输出过的标题：除非骨架里本块确实还有同名事件，否则当回显丢掉
      if (seen.contains(key) && !expectedKeys.contains(key)) continue;
      // 块内重复标题只保留第一条
      if (placed.values.any((p) => titleKey(p.title) == key)) continue;

      int? pos;
      for (var i = 0; i < expected.length; i++) {
        if (!used.contains(i) && expectedKeys[i] == key) {
          pos = i;
          break;
        }
      }
      if (pos != null) {
        used.add(pos);
        placed[pos] = b;
      } else {
        unmatched.add(b);
      }
    }

    // 标题与骨架对不上的块（模型轻微改写标题）：按顺序填到剩余空位，
    // 只取它的小事件部分；标题 / 概述仍用骨架的，避免结构被带偏。
    for (final b in unmatched) {
      for (var i = 0; i < expected.length; i++) {
        if (!used.contains(i)) {
          used.add(i);
          placed[i] = b;
          break;
        }
      }
    }

    return [
      for (var i = 0; i < expected.length; i++)
        NormalizedChunkEvent(
          position: i,
          title: expected[i].title,
          summary: expected[i].summary.trim(),
          minorsBody: _extractMinors(placed[i]?.body ?? ''),
        ),
    ];
  }

  /// 从模型块正文里取「小事件部分」：从第一条小事件标题行开始到末尾。
  ///
  /// 之前的行（模型重写的大事件概述、开场白、`大事件概述：` 标签等）一律丢弃：
  /// 概述以骨架为准，不能让模型的改写覆盖它。
  static String _extractMinors(String body) {
    if (body.trim().isEmpty) return '';
    final lines = body.split('\n');
    var firstMinor = -1;
    for (var i = 0; i < lines.length; i++) {
      if (classifyOutlineLine(lines[i]).isMinor) {
        firstMinor = i;
        break;
      }
    }
    if (firstMinor < 0) return '';
    return lines.sublist(firstMinor).join('\n').trim();
  }

  static List<({String title, String body})> _splitBlocks(String text) {
    final blocks = <({String title, String body})>[];
    String? curTitle;
    final bodyBuf = StringBuffer();
    void flush() {
      if (curTitle != null) {
        blocks.add((title: curTitle!, body: bodyBuf.toString().trim()));
      }
      curTitle = null;
      bodyBuf.clear();
    }

    for (final raw in text.split('\n')) {
      final head = classifyOutlineLine(raw);
      if (head.isMajor) {
        flush();
        curTitle = stripNestedEventPrefix(head.title);
        continue;
      }
      if (curTitle != null) bodyBuf.writeln(raw.trimRight());
    }
    flush();
    return blocks;
  }
}
