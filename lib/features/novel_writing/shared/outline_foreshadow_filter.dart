/// 纯文本伏笔清单的状态过滤。
///
/// 「伏笔清单」在库里是纯文本（一行一条，可能来自一键生成的账本、导入的 txt、
/// 旧记录或用户手动编辑）。点「小事件详写」写正文时会把整份清单注入提示词；
/// 已经回收 / 已实现的伏笔不应该再注入（模型会把完成的伏笔再写一遍，或为了
/// 呼应它而强行加戏）。
///
/// 规则：只按行过滤含「已回收 / 已实现 / 已兑现 / 回收完成」的行，其余行原样保留；
/// 全部被过滤时返回空串，调用方据此省略【伏笔清单】整段。
String filterResolvedForeshadowText(String text) {
  final kept = <String>[];
  for (final line in text.split('\n')) {
    if (_isResolvedForeshadowLine(line)) continue;
    kept.add(line);
  }
  final joined = kept.join('\n').trim();
  if (joined.isEmpty) return '';
  return joined.replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

bool _isResolvedForeshadowLine(String line) =>
    line.contains('已回收') ||
    line.contains('已实现') ||
    line.contains('已兑现') ||
    line.contains('回收完成');
