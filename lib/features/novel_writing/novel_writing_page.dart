import 'package:flutter/material.dart';
import 'package:deepseekapp/core/theme/app_palette.dart';
import '../../../core/widgets/settings_kit.dart';
import 'ai_battle/view/page/ai_battle_page.dart';
import 'outline_generation/view/page/outline_generation_page.dart';
import 'outline_editing/view/page/outline_edit_chapter_list_page.dart';
import 'outline_editing/view/page/outline_edit_novel_list_page.dart';
import 'outline_listening/view/page/outline_listen_novel_list_page.dart';
import 'chapter_writing/view/page/chapter_list_page.dart';
import 'outline_format/view/page/outline_format_page.dart';
import 'shared/domain/outline_record.dart';
import 'shared/outline_txt_export_sheet.dart';
import 'shared/outline_txt_import_dialog.dart';
import 'shared/outline_txt_transfer.dart';
import 'shared/outline_txt_transfer_service.dart';

/// 写小说模块入口页（功能导航）
///
/// 视觉：不用彩色大按钮，统一成「白卡列表 + 单色图标 chip + 副标题 + 箭头」，
/// 与各功能设置页同一套 settings_kit 语言；靠留白和文字层级而不是颜色区分功能。
///
/// 「导出大纲 txt / 导入大纲 txt」两行直接接在功能列表末尾（不单起分区标题），
/// 属于同一张卡片里的动作行。
class NovelWritingPage extends StatefulWidget {
  const NovelWritingPage({super.key});

  @override
  State<NovelWritingPage> createState() => _NovelWritingPageState();
}

class _NovelWritingPageState extends State<NovelWritingPage> {
  /// 本页提示（SnackBar）的宿主。
  ///
  /// SnackBar 默认挂在 MaterialApp 的 ScaffoldMessenger 上，**切换页面时会跟着
  /// 显示到下一个页面**（用户反馈：「已导入」提示切页后不会自己关掉）。
  /// 这里持有宿主的引用：任何一次从本页跳转 / 返回 / 打开弹层之前都主动收掉
  /// 当前提示，页面销毁时也收一次，保证提示只属于这一页。
  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    // 返回键 / 系统返回手势退出本页时，把可能还挂着的提示一并收掉。
    // 退场动画期间直接 setState 容易和导航栈刷新同帧打架，放到帧后执行。
    final messenger = _messenger;
    if (messenger != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (messenger.mounted) messenger.removeCurrentSnackBar();
      });
    }
    super.dispose();
  }

  /// 立刻收掉当前提示（不带动画），用于跳转 / 打开弹层之前。
  void _hideMessage() {
    _messenger?.removeCurrentSnackBar();
  }

  /// 打开功能页：先收掉提示再跳转，避免提示跟到新页面。
  void _openPage(Widget page) {
    _hideMessage();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          '写小说',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: p.textPrimary,
          ),
          onPressed: () {
            _hideMessage();
            Navigator.of(context).pop();
          },
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: p.border),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
            child: Text(
              '选择功能',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.6,
                color: p.textTertiary,
              ),
            ),
          ),
          SettingsCard(
            children: [
              _navRow(
                icon: Icons.auto_awesome_rounded,
                title: '一键生成大纲',
                subtitle: '填写设定，AI 流式生成完整大纲',
                page: const OutlineGenerationPage(),
              ),
              _navRow(
                icon: Icons.edit_note_rounded,
                title: '大纲编辑',
                subtitle: '选小说逐章精修，支持 AI 辅助改写',
                page: const OutlineEditNovelListPage(),
              ),
              _navRow(
                icon: Icons.headphones_rounded,
                title: '听大纲改名',
                subtitle: '边听边改，一键替换人名地名',
                page: const OutlineListenNovelListPage(),
              ),
              _navRow(
                icon: Icons.local_fire_department_rounded,
                title: 'AI 写战斗',
                subtitle: '多模型对战生成战斗场面',
                page: const AiBattlePage(),
              ),
              _navRow(
                icon: Icons.auto_stories_rounded,
                title: '小事件详写',
                subtitle: '按大纲拆分小事件并生成正文',
                page: const ChapterListPage(),
              ),
              _navRow(
                icon: Icons.format_align_left_rounded,
                title: '匹配大纲格式',
                subtitle: '解析外部大纲文本为可用格式',
                page: const OutlineFormatPage(),
              ),
              // 导出 / 导入大纲 txt：与上面的功能入口同属一张卡片，
              // 只是点击后不跳页面、直接弹层完成文件读写。
              SettingsActionRow(
                icon: Icons.file_upload_outlined,
                iconColor: p.textPrimary,
                softColor: p.surfaceMuted,
                title: '导出大纲 txt',
                subtitle: '选一部作品，把大纲正文存成 txt 文件',
                onTap: _handleExportOutline,
              ),
              SettingsActionRow(
                icon: Icons.file_download_outlined,
                iconColor: p.textPrimary,
                softColor: p.surfaceMuted,
                title: '导入大纲 txt',
                subtitle: '选一个 txt 文件，新建一部作品大纲',
                onTap: _handleImportOutline,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一键导出：选作品 → 读全文 → 系统保存框存成 txt。
  ///
  /// 取消保存框 / 关掉选作品弹层都静默结束；只有「没有作品」「正文为空」
  /// 和真正的写文件失败才提示。
  Future<void> _handleExportOutline() async {
    _hideMessage();
    final service = OutlineTxtTransferService();
    final List<OutlineRecord> novels;
    try {
      novels = await service.loadNovelSummaries();
    } catch (e, st) {
      debugPrint('[novel_writing] 读取作品列表失败：$e\n$st');
      if (mounted) _showMessage('读取作品列表失败：$e', error: true);
      return;
    }
    if (!mounted) return;
    if (novels.isEmpty) {
      _showMessage('还没有可导出的作品，先去「一键生成大纲」创建');
      return;
    }

    final picked = await showOutlineTxtExportSheet(context, novels);
    if (picked == null || !mounted) return;

    final name = _displayName(picked.title);
    try {
      final result = await service.exportOutlineTxt(picked);
      if (!mounted) return;
      switch (result.status) {
        case OutlineTxtExportStatus.exported:
          _showMessage('已导出《$name》大纲');
        case OutlineTxtExportStatus.cancelled:
          break;
        case OutlineTxtExportStatus.emptyContent:
          _showMessage('《$name》还没有大纲正文');
      }
    } catch (e, st) {
      debugPrint('[novel_writing] 导出大纲失败：$e\n$st');
      if (mounted) _showMessage('导出失败：$e', error: true);
    }
  }

  /// 一键导入：选 txt → 解码预览 → 新建大纲 → 按正文解析事件结构。
  ///
  /// **只新增，不覆盖**任何已有作品；解析结构失败也保留正文记录。
  Future<void> _handleImportOutline() async {
    _hideMessage();
    final service = OutlineTxtTransferService();
    final OutlineTxtImportDraft? draft;
    try {
      draft = await service.pickImportDraft();
    } on OutlineTxtImportException catch (e) {
      if (mounted) _showMessage(e.message, error: true);
      return;
    } catch (e, st) {
      debugPrint('[novel_writing] 读取大纲 txt 失败：$e\n$st');
      if (mounted) _showMessage('读取 txt 失败：$e', error: true);
      return;
    }
    // 用户在文件选择器里取消
    if (draft == null || !mounted) return;

    final title = await showOutlineTxtImportDialog(
      context,
      fileName: draft.fileName,
      initialTitle: draft.title,
      charCount: draft.charCount,
      eventCount: draft.eventCount,
      preview: _previewOf(draft.content),
    );
    if (title == null || !mounted) return;

    final OutlineTxtImportResult result;
    try {
      result = await service.createNovelFromDraft(draft, title: title);
    } catch (e, st) {
      debugPrint('[novel_writing] 导入大纲失败：$e\n$st');
      if (mounted) _showMessage('导入失败：$e', error: true);
      return;
    }
    if (!mounted) return;

    final record = result.record;
    final name = _displayName(record.title);
    // 结构解析失败时正文已经安全落库：文案按规格明确「导入成功、但结构失败」，
    // 不把它拼在成功文案后面（否则看起来像「已完整导入」）。
    final message = result.structureError != null
        ? '已导入《$name》，但事件结构解析失败（可进「大纲编辑」重试）'
        : '已导入《$name》，共 ${result.eventCount} 个事件';
    // SnackBarAction 会在用户之后任意时刻点击：捕获 NavigatorState 而不是
    // 页面 context，避免本页已经退出时用到失效的 context。
    final navigator = Navigator.of(context);
    final messenger = _messenger ?? ScaffoldMessenger.of(context);
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // 提示字号压小：整句偏长，默认字号在窄屏会折成两行且显得笨重
          content: Text(message, style: const TextStyle(fontSize: 12.5)),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '去编辑',
            onPressed: () {
              // 跳走之前先收掉提示，避免它显示到「大纲编辑」页面上
              _hideMessage();
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => OutlineEditChapterListPage(outline: record),
                ),
              );
            },
          ),
        ),
      );
  }

  String _displayName(String title) =>
      title.trim().isEmpty ? '未命名大纲' : title.trim();

  /// 导入确认弹窗里的正文预览：取前几行非空内容，限长避免把弹窗撑大。
  String _previewOf(String content) {
    final preview = content
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(5)
        .join('\n');
    if (preview.length <= 220) return preview;
    return '${preview.substring(0, 220)}…';
  }

  void _showMessage(String message, {bool error = false}) {
    final p = context.palette;
    // 新提示顶掉旧提示（而不是排队），避免连点后提示排队显示好几秒
    final messenger = _messenger ?? ScaffoldMessenger.of(context);
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12.5)),
          backgroundColor: error ? p.danger : null,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 单色导航行：图标 chip 用中性灰底（不用每行一个彩色），
  /// 整行可点，右侧箭头统一压线。
  Widget _navRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget page,
  }) {
    final p = context.palette;
    return SettingsActionRow(
      icon: icon,
      iconColor: p.textPrimary,
      softColor: p.surfaceMuted,
      title: title,
      subtitle: subtitle,
      onTap: () => _openPage(page),
    );
  }
}
