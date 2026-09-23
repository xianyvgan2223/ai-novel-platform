import 'package:flutter/material.dart';
import 'ai_battle/view/page/ai_battle_page.dart';
import 'outline_generation/view/page/outline_generation_page.dart';
import 'outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'chapter_writing/view/page/chapter_list_page.dart';
import 'outline_format/view/page/outline_format_page.dart';

/// 写小说模块入口页（功能导航）
class NovelWritingPage extends StatelessWidget {
  const NovelWritingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '写小说',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_stories, size: 64, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 16),
            const Text(
              '选择功能',
              style: TextStyle(fontSize: 16, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 32),

            // 一键生成大纲
            _buildNavButton(
              context,
              icon: Icons.list_alt,
              label: '一键生成大纲',
              color: const Color(0xFF4D6BFE),
              page: const OutlineGenerationPage(),
            ),
            const SizedBox(height: 16),

            // 大纲编辑（选小说 → 选章节 → 编辑 + AI 生成）
            _buildNavButton(
              context,
              icon: Icons.edit_note,
              label: '大纲编辑',
              color: const Color(0xFF2196F3),
              page: const OutlineEditNovelListPage(),
            ),
            const SizedBox(height: 16),

            // AI 写战斗
            _buildNavButton(
              context,
              icon: Icons.local_fire_department,
              label: 'AI 写战斗',
              color: const Color(0xFFFF5722),
              page: const AiBattlePage(),
            ),
            const SizedBox(height: 16),

            // 大纲转章节
            _buildNavButton(
              context,
              icon: Icons.auto_stories,
              label: '大纲转章节',
              color: const Color(0xFF7C4DFF),
              page: const ChapterListPage(),
            ),
            const SizedBox(height: 16),

            // 匹配大纲格式
            _buildNavButton(
              context,
              icon: Icons.format_align_left,
              label: '匹配大纲格式',
              color: const Color(0xFF00BFA5),
              page: const OutlineFormatPage(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required Widget page,
  }) {
    return SizedBox(
      width: 220,
      child: ElevatedButton.icon(
        onPressed: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
        },
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
