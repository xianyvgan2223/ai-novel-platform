import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/character_profile.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/data/outline_chapter_db_helper.dart';
import '../../../shared/domain/outline_chapter.dart';
import '../../controller/chapter_write_controller.dart';

/// 剧情状态账本查看/编辑页
///
/// - 人物档案：姓名 / 描述 / 能力 / 性格。描述与能力可由 AI 随章节提炼更新，
///   性格仅允许在这里由用户修改（AI 提炼不会覆盖）。
/// - 剧情状态：AI 随章节累积的文本账本，可手动编辑。
class StoryStatePage extends StatefulWidget {
  final int outlineId;
  final ChapterWriteController controller;
  const StoryStatePage({
    super.key,
    required this.outlineId,
    required this.controller,
  });

  @override
  State<StoryStatePage> createState() => _StoryStatePageState();
}

class _StoryStatePageState extends State<StoryStatePage> {
  List<CharacterProfile> _characters = [];
  final _storyStateCtrl = TextEditingController();
  final _foreshadowsCtrl = TextEditingController(); // 伏笔清单（可查看/编辑）
  bool _loading = true;
  bool _generatingProtagonist = false;
  bool _regeneratingForeshadows = false;
  bool _lastRefreshingForeshadows = false; // 后台提炼状态快照（轮询刷新显示）
  Timer? _foreshadowWatchTimer; // 轻量轮询：后台伏笔提炼开始/结束时刷新界面
  OutlineChapter? _latestChapter; // 最新已完成章节（账本页展示其内容）

  @override
  void initState() {
    super.initState();
    _load();
    _startForeshadowWatch();
  }

  @override
  void dispose() {
    _foreshadowWatchTimer?.cancel();
    _storyStateCtrl.dispose();
    _foreshadowsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await OutlineRecordDbHelper().getById(widget.outlineId);
      if (row != null) {
        _characters = _parseCharacters(row['characters'] as String? ?? '');
        _storyStateCtrl.text = row['story_state'] as String? ?? '';
        _foreshadowsCtrl.text = row['foreshadows'] as String? ?? '';
      }
      // 最新已完成章节：账本页展示的是最新一章的账本
      final all = await OutlineChapterDbHelper().getByOutlineId(widget.outlineId);
      final completed = all
          .map((m) => OutlineChapter.fromMap(m))
          .where((c) => c.eventType == 'minor' && c.status == 'completed')
          .toList()
        ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
      _latestChapter = completed.isEmpty ? null : completed.last;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  /// 手动从大纲生成主角档案（提炼 + AI 审查），生成完成后刷新列表
  Future<void> _generateProtagonist() async {
    if (_generatingProtagonist) return;
    setState(() => _generatingProtagonist = true);
    final result = await widget.controller.generateProtagonistProfile();
    await _load();
    if (mounted) {
      setState(() => _generatingProtagonist = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result), duration: const Duration(seconds: 1)),
      );
    }
  }

  /// 轻量轮询：控制器后台伏笔提炼状态变化时刷新界面（提炼开始显示加载提示，
  /// 完成自动消失）；提炼结束后停止轮询
  void _startForeshadowWatch() {
    _foreshadowWatchTimer?.cancel();
    _foreshadowWatchTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        final refreshing = widget.controller.isRefreshingForeshadows;
        if (refreshing != _lastRefreshingForeshadows) {
          _lastRefreshingForeshadows = refreshing;
          setState(() {});
        }
        if (!refreshing) t.cancel();
      },
    );
  }

  /// 手动重新提炼伏笔清单（后台 AI 调用），完成后刷新列表
  Future<void> _regenerateForeshadows() async {
    if (_regeneratingForeshadows) return;
    setState(() => _regeneratingForeshadows = true);
    final result = await widget.controller.regenerateForeshadows();
    await _load();
    if (mounted) {
      setState(() => _regeneratingForeshadows = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result), duration: const Duration(seconds: 1)),
      );
    }
  }

  Future<void> _save() async {
    final chars = _characters.where((c) => c.name.trim().isNotEmpty).toList();
    await OutlineRecordDbHelper().update(widget.outlineId, {
      'characters': jsonEncode(chars.map((c) => c.toJson()).toList()),
      'story_state': _storyStateCtrl.text,
      'foreshadows': _foreshadowsCtrl.text,
    });
    // 同步到最新已完成章节的独立账本，保持每章账本与全局展示一致
    if (_latestChapter?.id != null) {
      await OutlineChapterDbHelper().updateStoryState(
        _latestChapter!.id!,
        _storyStateCtrl.text,
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('账本已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pop();
    }
  }

  List<CharacterProfile> _parseCharacters(String jsonText) {
    if (jsonText.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(CharacterProfile.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 剧情状态放大编辑弹窗
  void _showStoryStateEnlargeDialog() {
    final editCtrl = TextEditingController(text: _storyStateCtrl.text);
    final screenHeight = MediaQuery.heightOf(context);
    final screenWidth = MediaQuery.widthOf(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text(
          '剧情状态',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: screenHeight * 0.72,
            maxWidth: screenWidth * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 10, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              // 防止快速连点造成重复 pop（会连带关闭下层页面触发框架断言）
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              _storyStateCtrl.text = editCtrl.text;
              setState(() {});
              scheduleControllerDispose(editCtrl);
            },
            child: const Text(
              '确定',
              style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
  }

  /// 伏笔清单按行展示（每条一行，空行跳过）
  List<Widget> _buildForeshadowLines() {
    final lines = _foreshadowsCtrl.text.split('\n');
    return [
      for (final line in lines)
        if (line.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(Icons.circle, size: 6, color: Color(0xFF4D6BFE)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    line.trim(),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: Color(0xFF666666),
                    ),
                  ),
                ),
              ],
            ),
          ),
    ];
  }

  /// 打开 AI 伏笔生成详情页：流式展示 AI 思考过程与生成清单
  void _openForeshadowDetail() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ForeshadowDetailPage(
          outlineId: widget.outlineId,
          controller: widget.controller,
        ),
      ),
    );
  }

  /// 打开伏笔进度详情页：当前伏笔清单 + 各已完成章节账本中的【伏笔】记录
  void _openForeshadowProgress() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ForeshadowProgressPage(outlineId: widget.outlineId),
      ),
    );
  }

  /// 伏笔清单编辑弹窗：多行文本编辑后写回 _foreshadowsCtrl
  void _showForeshadowsEditDialog() {
    final editCtrl = TextEditingController(text: _foreshadowsCtrl.text);
    final screenHeight = MediaQuery.heightOf(context);
    final screenWidth = MediaQuery.widthOf(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text(
          '伏笔清单',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: screenHeight * 0.72,
            maxWidth: screenWidth * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: '每条伏笔一行，形如：伏笔内容（埋设位置 / 计划回收时机）',
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 10, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              _foreshadowsCtrl.text = editCtrl.text;
              setState(() {});
              scheduleControllerDispose(editCtrl);
            },
            child: const Text(
              '确定',
              style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
  }

  /// 把剧情状态文本按「【分区标题】内容」拆分为带标题和分割的展示行。
  /// 旧数据无分区标记时退化为按行展示，保证每种格式都可读。
  List<Widget> _buildStoryStateSections() {
    final lines = _storyStateCtrl.text.split('\n');
    final sectionRe = RegExp(r'^【(.+?)】');
    final sections = <Widget>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = sectionRe.firstMatch(t);
      if (m != null) {
        // 分区标题行：【角色处境】内容...
        final title = m.group(1)!;
        final rest = t.substring(t.indexOf('】') + 1).trim();
        sections.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4D6BFE),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
              ],
            ),
          ),
        );
        if (rest.isNotEmpty) {
          sections.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 10),
              child: Text(
                rest,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFF666666),
                ),
              ),
            ),
          );
        }
      } else {
        // 普通内容行
        sections.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              t,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Color(0xFF666666),
              ),
            ),
          ),
        );
      }
    }
    return sections;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text(
          '剧情状态账本',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _loading ? null : _save,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF4D6BFE),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildOverviewCard(),
                const SizedBox(height: 20),
                _buildSectionHeader(
                  title: '人物档案',
                  subtitle: '描述与能力由 AI 随章节更新；性格仅由你修改，AI 不会覆盖',
                  trailing: OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _characters = [..._characters, const CharacterProfile()];
                    }),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加人物'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF4D6BFE),
                      side: const BorderSide(color: Color(0xFF4D6BFE)),
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_characters.isEmpty) ...[
                  _buildEmptyCard('暂无人物档案，可添加人物、从大纲生成主角档案，或先写一章由系统自动提取'),
                  const SizedBox(height: 10),
                  Center(
                    child: OutlinedButton.icon(
                      onPressed: _generatingProtagonist
                          ? null
                          : _generateProtagonist,
                      icon: _generatingProtagonist
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 16),
                      label: Text(
                        _generatingProtagonist ? '正在生成...' : '从大纲生成主角档案',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF4D6BFE),
                        side: const BorderSide(color: Color(0xFF4D6BFE)),
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ] else
                  ..._characters.asMap().entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _CharacterEditor(
                        key: ValueKey('char_${entry.key}_${entry.value.name}'),
                        character: entry.value,
                        onChanged: (c) => setState(() {
                          _characters[entry.key] = c;
                        }),
                        onDelete: () => setState(() {
                          _characters.removeAt(entry.key);
                        }),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                _buildSectionHeader(
                  title: '剧情状态',
                  subtitle: _latestChapter != null
                      ? '最新一章「' + _latestChapter!.eventTitle + '」的账本（AI 生成可手动修改；每章账本可在章节列表的「账本」按钮查看/回退）'
                      : 'AI 每章完成后自动更新：角色处境 / 时间地点 / 伏笔 / 悬念 / 冲突',
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE8ECF4)),
                  ),
                  child: _storyStateCtrl.text.trim().isEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.menu_book_outlined,
                                  size: 18,
                                  color: Colors.grey[300],
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '暂无剧情状态，写完第一章后自动生成，也可点击「编辑」手动填写',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[400],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Divider(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: _showStoryStateEnlargeDialog,
                                child: const Text(
                                  '编辑',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF4D6BFE),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ..._buildStoryStateSections(),
                            const SizedBox(height: 4),
                            const Divider(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: _showStoryStateEnlargeDialog,
                                child: const Text(
                                  '编辑',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF4D6BFE),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),
                _buildSectionHeader(
                  title: '伏笔清单',
                  subtitle: 'AI 从大纲提炼，章节写作时注入【伏笔清单】；可手动修改',
                  trailing: (_regeneratingForeshadows ||
                          widget.controller.isRefreshingForeshadows)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '伏笔提炼中...',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        )
                      : OutlinedButton.icon(
                        onPressed: _regenerateForeshadows,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('重新提炼'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF4D6BFE),
                          side: const BorderSide(color: Color(0xFF4D6BFE)),
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE8ECF4)),
                  ),
                  child: _foreshadowsCtrl.text.trim().isEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.flag_outlined,
                                  size: 18,
                                  color: Colors.grey[300],
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '暂无伏笔清单，可点击「重新提炼」从大纲生成，或点击「编辑」手动填写',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[400],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Divider(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  GestureDetector(
                                    onTap: _showForeshadowsEditDialog,
                                    child: const Text(
                                      '编辑',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF4D6BFE),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: _openForeshadowProgress,
                                    child: const Text(
                                      '伏笔进度',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF00897B),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: _openForeshadowDetail,
                                    child: const Text(
                                      'AI 生成详情',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF7C4DFF),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ..._buildForeshadowLines(),
                            const SizedBox(height: 4),
                            const Divider(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  GestureDetector(
                                    onTap: _showForeshadowsEditDialog,
                                    child: const Text(
                                      '编辑',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF4D6BFE),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: _openForeshadowProgress,
                                    child: const Text(
                                      '伏笔进度',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF00897B),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: _openForeshadowDetail,
                                    child: const Text(
                                      'AI 生成详情',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF7C4DFF),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildOverviewCard() {
    final charCount = _characters.length;
    final stateLength = _storyStateCtrl.text.trim().length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: Row(
        children: [
          _buildStat(charCount, '人物'),
          _buildDivider(),
          _buildStat(stateLength, '剧情状态字数'),
        ],
      ),
    );
  }

  Widget _buildStat(int value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF333333),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(width: 1, height: 34, color: const Color(0xFFEEEEEE));
  }

  Widget _buildSectionHeader({
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF4D6BFE),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  Widget _buildEmptyCard(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: Column(
        children: [
          Icon(Icons.person_outline, size: 32, color: Colors.grey[300]),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}

/// 单个可编辑人物卡片
class _CharacterEditor extends StatefulWidget {
  final CharacterProfile character;
  final ValueChanged<CharacterProfile> onChanged;
  final VoidCallback onDelete;

  const _CharacterEditor({
    super.key,
    required this.character,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  State<_CharacterEditor> createState() => _CharacterEditorState();
}

class _CharacterEditorState extends State<_CharacterEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _abilCtrl;
  late final TextEditingController _persCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.character.name);
    _descCtrl = TextEditingController(text: widget.character.description);
    _abilCtrl = TextEditingController(text: widget.character.abilities);
    _persCtrl = TextEditingController(text: widget.character.personality);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _abilCtrl.dispose();
    _persCtrl.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(
      CharacterProfile(
        name: _nameCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        abilities: _abilCtrl.text.trim(),
        personality: _persCtrl.text.trim(),
        isProtagonist: widget.character.isProtagonist,
      ),
    );
  }

  /// 放大编辑弹窗：大屏编辑后写回目标输入框
  void _showEnlargeDialog({
    required TextEditingController targetCtrl,
    required String label,
  }) {
    final editCtrl = TextEditingController(text: targetCtrl.text);
    final screenHeight = MediaQuery.heightOf(context);
    final screenWidth = MediaQuery.widthOf(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: screenHeight * 0.72,
            maxWidth: screenWidth * 0.92,
          ),
          child: TextField(
            controller: editCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(4, 2, 4, 2),
              filled: true,
              fillColor: Color(0xFFFAFAFA),
            ),
            style: const TextStyle(fontSize: 10, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              scheduleControllerDispose(editCtrl);
            },
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              if (!closeDialogSafely(ctx)) return;
              targetCtrl.text = editCtrl.text;
              _emit();
              scheduleControllerDispose(editCtrl);
            },
            child: const Text(
              '确定',
              style: TextStyle(fontSize: 12, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = _nameCtrl.text.trim().isEmpty
        ? '?'
        : _nameCtrl.text.trim().characters.first;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8ECF4)),
        boxShadow: [
          BoxShadow(
            color: const Color(0x0D000000),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFFEDF0FF),
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4D6BFE),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  onChanged: (_) => _emit(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                  decoration: InputDecoration(
                    hintText: '姓名',
                    hintStyle: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[400],
                    ),
                    isDense: true,
                    border: InputBorder.none,
                    suffixIcon: IconButton(
                      onPressed: () => _showEnlargeDialog(
                        targetCtrl: _nameCtrl,
                        label: '姓名',
                      ),
                      icon: const Icon(Icons.open_in_full, size: 14),
                      color: const Color(0xFF999999),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      tooltip: '放大编辑',
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Colors.grey[400],
                ),
                tooltip: '删除人物',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (widget.character.isProtagonist) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF0FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '主角 · 档案直接注入每章',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4D6BFE),
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          _buildField(
            label: '描述',
            hint: '外貌 / 身份 / 背景',
            controller: _descCtrl,
            maxLines: 2,
          ),
          const SizedBox(height: 10),
          _buildField(
            label: '能力',
            hint: '天赋 / 技能 / 成长',
            controller: _abilCtrl,
            maxLines: 2,
          ),
          const SizedBox(height: 10),
          _buildField(
            label: '性格（仅你修改）',
            hint: 'AI 提炼不会覆盖此字段',
            controller: _persCtrl,
            maxLines: 2,
            accent: true,
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required int maxLines,
    bool accent = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: accent ? const Color(0xFF4D6BFE) : Colors.grey[600],
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          onChanged: (_) => _emit(),
          maxLines: maxLines,
          style: const TextStyle(fontSize: 10, height: 1.5),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 10, color: Colors.grey[400]),
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFFAFAFB),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey[200]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF4D6BFE)),
            ),
            suffixIcon: IconButton(
              onPressed: () =>
                  _showEnlargeDialog(targetCtrl: controller, label: label),
              icon: const Icon(Icons.open_in_full, size: 14),
              color: const Color(0xFF999999),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: '放大编辑',
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          ),
        ),
      ],
    );
  }
}

/// 伏笔进度详情页：展示当前伏笔清单 + 各已完成章节账本中的【伏笔】记录，
/// 按章节顺序查看每条伏笔的埋设/回收进展。
class _ForeshadowProgressPage extends StatefulWidget {
  final int outlineId;
  const _ForeshadowProgressPage({required this.outlineId});

  @override
  State<_ForeshadowProgressPage> createState() =>
      _ForeshadowProgressPageState();
}

class _ForeshadowProgressPageState extends State<_ForeshadowProgressPage> {
  String _foreshadows = '';
  final List<({String title, String storyState})> _chapters = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await OutlineRecordDbHelper().getById(widget.outlineId);
      _foreshadows = row?['foreshadows'] as String? ?? '';
      final all = await OutlineChapterDbHelper().getByOutlineId(widget.outlineId);
      final completed = all
          .map((m) => OutlineChapter.fromMap(m))
          .where((c) => c.eventType == 'minor' && c.status == 'completed')
          .toList()
        ..sort((a, b) => a.eventIndex.compareTo(b.eventIndex));
      _chapters
        ..clear()
        ..addAll(completed.map((c) => (title: c.eventTitle, storyState: c.storyState)));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  /// 从章节账本文本中提取【伏笔】分区内容（无则返回空串）
  String _extractForeshadowSection(String storyState) {
    if (storyState.trim().isEmpty) return '';
    final buf = <String>[];
    var inSection = false;
    for (final line in storyState.split('\n')) {
      final t = line.trim();
      if (t.startsWith('【')) {
        if (inSection) break;
        if (t.startsWith('【伏笔】')) {
          inSection = true;
          final rest = t.substring(t.indexOf('】') + 1).trim();
          if (rest.isNotEmpty) buf.add(rest);
        }
        continue;
      }
      if (inSection && t.isNotEmpty) buf.add(t);
    }
    return buf.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '伏笔进度',
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 当前伏笔清单 ──
                _sectionHeader('当前伏笔清单', '账本页可编辑/重新提炼'),
                const SizedBox(height: 8),
                _card(
                  child: _foreshadows.trim().isEmpty
                      ? Text(
                          '（暂无伏笔清单，可到剧情账本页点击「重新提炼」生成）',
                          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final line in _foreshadows.split('\n'))
                              if (line.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.only(top: 4),
                                        child: Icon(
                                          Icons.circle,
                                          size: 6,
                                          color: Color(0xFF4D6BFE),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          line.trim(),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.5,
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),
                // ── 各章伏笔进度 ──
                _sectionHeader('各章伏笔进度', '按章节顺序展示每章账本中的【伏笔】记录'),
                const SizedBox(height: 8),
                if (_chapters.isEmpty)
                  _card(
                    child: Text(
                      '（还没有已完成的章节，完成章节后每章账本会自动记录伏笔进展）',
                      style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    ),
                  )
                else
                  for (final c in _chapters) ...[
                    _card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.menu_book_outlined,
                                size: 16,
                                color: Color(0xFF4D6BFE),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  c.title,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF333333),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _extractForeshadowSection(c.storyState).isEmpty
                              ? Text(
                                  '（本章账本无伏笔记录）',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[400],
                                  ),
                                )
                              : Text(
                                _extractForeshadowSection(c.storyState),
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Color(0xFF666666),
                                ),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF333333),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: child,
    );
  }
}

/// AI 伏笔生成详情页：流式实时展示伏笔提炼的 AI 思考过程（reasoning_content）
/// 与生成结果；提炼中实时刷新，也可在本页直接发起提炼。
class _ForeshadowDetailPage extends StatefulWidget {
  final int outlineId;
  final ChapterWriteController controller;
  const _ForeshadowDetailPage({
    required this.outlineId,
    required this.controller,
  });

  @override
  State<_ForeshadowDetailPage> createState() => _ForeshadowDetailPageState();
}

class _ForeshadowDetailPageState extends State<_ForeshadowDetailPage> {
  Timer? _watchTimer; // 轻量轮询：流式内容实时刷新
  bool _starting = false;
  String _lastResult = '';

  @override
  void initState() {
    super.initState();
    _watchTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {}); // 流式内容/状态实时刷新
    });
  }

  @override
  void dispose() {
    _watchTimer?.cancel();
    super.dispose();
  }

  /// 在本页直接发起流式提炼（与账本页「重新提炼」同一入口）
  Future<void> _start() async {
    if (_starting || widget.controller.isRefreshingForeshadows) return;
    setState(() {
      _starting = true;
      _lastResult = '';
    });
    final result = await widget.controller.regenerateForeshadows();
    if (mounted) {
      setState(() {
        _starting = false;
        _lastResult = result;
      });
    }
  }

  Widget _bubble({
    required IconData icon,
    required String title,
    required String content,
    required String emptyHint,
    Color color = const Color(0xFFF0F4FF),
    Color borderColor = const Color(0xFFD8E2FF),
    Color iconColor = const Color(0xFF4D6BFE),
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: iconColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            content.trim().isEmpty ? emptyHint : content,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: Color(0xFF666666),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final refreshing = c.isRefreshingForeshadows;
    final thinking = c.foreshadowThinkingText;
    final output = c.foreshadowOutputText;
    final String status;
    if (refreshing) {
      status = '伏笔提炼中...';
    } else if (_starting) {
      status = '准备中...';
    } else if (output.trim().isNotEmpty) {
      status = '已生成（上次结果）';
    } else {
      status = '尚未提炼，可点击下方「开始提炼」';
    }
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'AI 伏笔生成详情',
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
      body: Column(
        children: [
          // 状态条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFFF8F9FF),
            child: Row(
              children: [
                if (refreshing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Color(0xFF4CAF50),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF666666),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_lastResult.isNotEmpty && !refreshing)
                  Flexible(
                    child: Text(
                      _lastResult,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF00897B),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // AI 思考过程（reasoning_content 流式展示）
                _bubble(
                  icon: Icons.psychology_alt,
                  title: 'AI 思考过程',
                  content: thinking,
                  emptyHint: refreshing ? '正在思考中...' : '（暂无思考过程）',
                ),
                const SizedBox(height: 12),
                // 生成结果（伏笔清单流式展示）
                _bubble(
                  icon: Icons.flag_outlined,
                  title: '生成的伏笔清单',
                  content: output,
                  emptyHint: refreshing ? '正在生成中...' : '（暂无输出）',
                  color: const Color(0xFFF1F8E9),
                  borderColor: const Color(0xFFDCEDC8),
                  iconColor: const Color(0xFF558B2F),
                ),
              ],
            ),
          ),
          // 底部操作：开始提炼
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: (refreshing || _starting) ? null : _start,
                  icon: refreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(refreshing ? '提炼中...' : '开始提炼伏笔'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4D6BFE),
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
