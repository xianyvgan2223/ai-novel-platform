import 'package:flutter/material.dart';
import '../../../outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'outline_history_detail_page.dart';

/// 「一键生成大纲」的历史入口：选择大纲的界面与「大纲编辑」完全共用
/// （OutlineEditNovelListPage：小说卡片网格 + 章节进度），只是点卡片后进入
/// 历史大纲详情页（可编辑正文与设定 / 重新生成 / 编辑粗骨 / 编辑大事件 /
/// 继续生成），而不是大纲编辑页。
class OutlineHistoryListPage extends StatelessWidget {
  const OutlineHistoryListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return OutlineEditNovelListPage(
      title: '历史大纲',
      hint: '点卡片查看详情 / 重新生成',
      emptyTitle: '还没有历史大纲',
      // 旧「历史大纲」列表页的删除入口：改成长按卡片触发
      allowDelete: true,
      onOpenNovel: (context, outline) async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OutlineHistoryDetailPage(record: outline),
          ),
        );
      },
    );
  }
}
