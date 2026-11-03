import 'package:flutter/material.dart';
import '../../../outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'chapter_write_page.dart';

/// 「小事件详写」入口：选择大纲的界面与「大纲编辑」完全共用
/// （OutlineEditNovelListPage：小说卡片网格 + 小事件进度），只是点卡片后进入
/// 小事件详写页，而不是大纲编辑页。
class ChapterListPage extends StatelessWidget {
  const ChapterListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return OutlineEditNovelListPage(
      title: '小事件详写',
      hint: '点卡片进入小事件详写',
      emptyTitle: '还没有大纲',
      onOpenNovel: (context, outline) async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ChapterWritePage(outline: outline)),
        );
      },
    );
  }
}
