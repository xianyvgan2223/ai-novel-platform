import 'package:flutter/material.dart';
import '../../../core/widgets/settings_kit.dart';
import 'ai_battle/view/page/ai_battle_page.dart';
import 'outline_generation/view/page/outline_generation_page.dart';
import 'outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'outline_listening/view/page/outline_listen_novel_list_page.dart';
import 'chapter_writing/view/page/chapter_list_page.dart';
import 'outline_format/view/page/outline_format_page.dart';

/// 写小说模块入口页（功能导航）
///
/// 视觉：不用彩色大按钮，统一成「白卡列表 + 单色图标 chip + 副标题 + 箭头」，
/// 与各功能设置页同一套 settings_kit 语言；靠留白和文字层级而不是颜色区分功能。
class NovelWritingPage extends StatelessWidget {
  const NovelWritingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSettingsPageBg,
      appBar: AppBar(
        backgroundColor: kSettingsCardBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '写小说',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kSettingsTitle,
          ),
        ),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: kSettingsLabel,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: kSettingsAppBarDivider,
          ),
        ),
      ),
      // ListView 天然可滚动：键盘弹起等矮高度场景不会像裸 Center 那样溢出。
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          kSettingsCardMarginH,
          8,
          kSettingsCardMarginH,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 10),
            child: Text(
              '选择功能',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.6,
                color: kSettingsSubtitle,
              ),
            ),
          ),
          SettingsCard(
            children: [
              _navRow(
                context,
                icon: Icons.auto_awesome_rounded,
                title: '一键生成大纲',
                subtitle: '填写设定，AI 流式生成完整大纲',
                page: const OutlineGenerationPage(),
              ),
              _navRow(
                context,
                icon: Icons.edit_note_rounded,
                title: '大纲编辑',
                subtitle: '选小说逐章精修，支持 AI 辅助改写',
                page: const OutlineEditNovelListPage(),
              ),
              _navRow(
                context,
                icon: Icons.headphones_rounded,
                title: '听大纲改名',
                subtitle: '边听边改，一键替换人名地名',
                page: const OutlineListenNovelListPage(),
              ),
              _navRow(
                context,
                icon: Icons.local_fire_department_rounded,
                title: 'AI 写战斗',
                subtitle: '多模型对战生成战斗场面',
                page: const AiBattlePage(),
              ),
              _navRow(
                context,
                icon: Icons.auto_stories_rounded,
                title: '大纲转章节',
                subtitle: '按大纲拆分章节并生成正文',
                page: const ChapterListPage(),
              ),
              _navRow(
                context,
                icon: Icons.format_align_left_rounded,
                title: '匹配大纲格式',
                subtitle: '解析外部大纲文本为可用格式',
                page: const OutlineFormatPage(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单色导航行：图标 chip 用中性灰底（不用每行一个彩色），
  /// 整行可点，右侧箭头统一压线。
  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget page,
  }) {
    return SettingsActionRow(
      icon: icon,
      iconColor: kSettingsTitle,
      softColor: kSettingsChipBg,
      title: title,
      subtitle: subtitle,
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      },
    );
  }
}
