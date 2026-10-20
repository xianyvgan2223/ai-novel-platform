import 'package:flutter/foundation.dart';

import '../../shared/outline_event_syntax.dart';

/// 大纲生成文本里**对章节 / 事件编号的引用**的识别与清理。
///
/// 模型写伏笔照应时爱用「54与70埋的…」「第52章那根铁条」「88旧台补法失传」这类
/// **编号引用**——编号只是生成过程的定位手段（大事件N、第N个事件），写进
/// 大事件概述 / 小事件概要后会有两个后果：
/// 1. 后续批次与展开块把编号当事实继续抄，越传越乱；
/// 2. 读者读不懂「54 与 70 埋的…」——用户明确要求：**伏笔照应要直接写出
///    内容本身（人物、物件、原话、场景），不允许写「第几章埋的伏笔」**。
///
/// 这里按两层处理：
/// - **硬规则**（任何时候都清理）：`第N章/回/节`、`第N个事件`、`大事件N`、
///   `N与M埋的`、`第N幕` 等明确带编号标记的写法；
/// - **启发式**（只在该行讨论伏笔 / 回收 / 悬念等「生成元信息」时）：把裸编号
///   （如「52搬出宅邸」「90姜黎」「88旧台」）也去掉，同时保护 30年 / 3000人 /
///   3天 这类正常数量词。
///
/// 清理只动**正文行**：`══ 大事件N：标题 ══` / `○ 小事件N：标题` 这类标题行里的
/// 编号是格式的一部分，必须原样保留。
@immutable
class OutlineMetaRefCleaner {
  const OutlineMetaRefCleaner._();

  // ── 硬规则：明确的编号引用 ──
  // 第54章 / 第54、70章 / 54章
  static final RegExp _chapterRef = RegExp(
    r'(?:第\s*)?\d+(?:\s*[、,，和与]\s*\d+)*\s*[章回节卷]',
  );
  // 第3幕 / 第3幕的高潮
  static final RegExp _actRef = RegExp(r'第\s*\d+\s*幕');
  // 第54个事件 / 第54号事件 / 54事件
  static final RegExp _eventOrdinalRef = RegExp(
    r'(?:第\s*)?\d+(?:\s*[、,，和与]\s*\d+)*\s*(?:个|号|条)?\s*(?:大|小)?事件',
  );
  // 大事件54埋的 → 此前埋的（先于下面的通配替换，避免变成「此前的事件埋的」）
  static final RegExp _namedEventPlantRef = RegExp(
    r'(?:大|小)事件\s*\d+(?:\s*[、,，和与]\s*\d+)*(?=\s*埋)',
  );
  // 大事件54 / 小事件12 → 此前的事件
  static final RegExp _namedEventRef = RegExp(
    r'(?:大|小)事件\s*\d+(?:\s*[、,，和与]\s*\d+)*',
  );
  // 54与70埋的 → 此前埋的
  static final RegExp _pairedPlantRef = RegExp(
    r'\d+(?:\s*[、,，和与]\s*\d+)+(?=\s*埋)',
  );
  // 54埋的 / 第54埋的 → 此前埋的
  static final RegExp _ordinalPlantRef = RegExp(
    r'(?:第\s*)?\d+(?:\s*[、,，和与]\s*\d+)*(?=\s*埋的|\s*埋下)',
  );

  // ── 启发式：带「生成元信息」的行里，裸编号也去掉 ──
  static final RegExp _metaHint = RegExp(
    r'伏笔|埋下|埋的|埋了|埋过|回收|照应|合扣|呼应|铺垫|悬念|欠着|前文',
  );

  /// 数字后面紧跟这些字时不是编号引用（时间 / 数量 / 计量 / 序数单位），保留。
  static const String _unitChars =
      '年月日号天时分秒岁个名位人只头匹条张件次回趟遍层楼栋间处家座米里'
      '斤公斤克吨元块角万亿元倍成度级星期周季代世页行字句篇本册卷集部组队'
      '群批波轮场步招种类型款式颗粒滴片份部分';

  /// 裸编号：1~3 位数字（4 位多为年份，直接排除），前面不是字母数字 / 「第」，
  /// 后面紧跟汉字且不是单位字。
  static final RegExp _bareNumberRef = RegExp(
    '(?<![0-9A-Za-z第])[0-9]{1,3}(?=[\\u4e00-\\u9fa5])(?![$_unitChars])',
  );

  /// 清理**整段大纲正文**：逐行处理，跳过事件 / 幕标题行（编号是格式的一部分）。
  static String cleanBodyText(String text) {
    if (text.isEmpty) return text;
    return text
        .split('\n')
        .map((line) {
          final kind = classifyOutlineLine(line);
          if (kind.isEvent || kind.isAct) return line;
          return _cleanLine(line);
        })
        .join('\n');
  }

  /// 清理单段文本（标题之外的任意文本，如伏笔账本的 content / plan 字段）。
  static String clean(String text) =>
      text.isEmpty ? text : _cleanLine(text);

  /// 是否还残留明确的编号引用（测试 / 巡检用）
  static bool hasNumberReference(String text) {
    for (final line in text.split('\n')) {
      final kind = classifyOutlineLine(line);
      if (kind.isEvent || kind.isAct) continue;
      if (_chapterRef.hasMatch(line) ||
          _actRef.hasMatch(line) ||
          _eventOrdinalRef.hasMatch(line) ||
          _namedEventRef.hasMatch(line) ||
          _pairedPlantRef.hasMatch(line) ||
          _ordinalPlantRef.hasMatch(line)) {
        return true;
      }
      if (_metaHint.hasMatch(line) && _bareNumberRef.hasMatch(line)) {
        return true;
      }
    }
    return false;
  }

  static String _cleanLine(String line) {
    if (line.isEmpty) return line;
    var out = line;
    // 顺序很重要：带「埋」的组合先处理，再处理通用的「N个事件 / 大事件N」
    out = out.replaceAll(_namedEventPlantRef, '此前');
    out = out.replaceAll(_namedEventRef, '此前的事件');
    out = out.replaceAll(_pairedPlantRef, '此前');
    out = out.replaceAll(_ordinalPlantRef, '此前');
    out = out.replaceAll(_chapterRef, '此前');
    out = out.replaceAll(_eventOrdinalRef, '此前的事件');
    out = out.replaceAll(_actRef, '这一幕');
    // 启发式：这一行在讨论伏笔 / 回收 / 悬念时，裸编号（52搬出宅邸 / 90姜黎）也去掉
    if (_metaHint.hasMatch(out)) {
      out = out.replaceAll(_bareNumberRef, '');
    }
    return out;
  }
}
