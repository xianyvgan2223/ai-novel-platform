import 'package:flutter/material.dart';

import '../../../shared/domain/outline_record.dart';
import '../../../outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'outline_listen_page.dart';

/// 「听大纲改名」的小说选择页。
///
/// 直接复用「大纲编辑」的选择页（同一份数据源、同一套卡片与滚动位置记忆），
/// 只换标题与空态文案，并在点开后进入 [OutlineListenPage]。
///
/// 点开小说时**不进章节选择页**：听的时候是顺着整篇往下听的，先让人勾选章节
/// 反而多一步；页内可以随时用「上一条 / 下一条」跳，也可以点任意一条从那开始。
class OutlineListenNovelListPage extends StatelessWidget {
  const OutlineListenNovelListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return OutlineEditNovelListPage(
      title: '听大纲改名',
      hint: '点卡片开始听，可边听边改，也能一键改名',
      emptyTitle: '还没有可朗读的小说',
      emptyHint: '请先在「一键生成大纲」中创建',
      onOpenNovel: _openListen,
    );
  }

  /// 打开听大纲改名页。
  ///
  /// **不在这里读章节表、也不传章节**：事件结构要由听大纲改名页按**库里的最新
  /// 正文**校正（`reconcileOutlineChapters`），与「大纲编辑」的章节选择页完全
  /// 同一套。这里若图省事读一次章表当参数传下去，出过两种事故：
  /// - 章表为空（还没在「大纲转章节」里解析过）时传下去一个空列表，
  ///   页面于是显示「没有可朗读的事件」——其实大纲正文里事件好好的；
  /// - 拿列表页那一刻的旧正文去校正（`content` 是 final，编辑页保存只写库、
  ///   不回填内存），会把「大纲编辑」里删掉的事件又解析回来。
  static Future<void> _openListen(
    BuildContext context,
    OutlineRecord outline,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OutlineListenPage(outline: outline),
      ),
    );
  }
}
