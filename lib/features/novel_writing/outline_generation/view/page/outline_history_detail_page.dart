import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../../shared/dialog_utils.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../shared/outline_load_error_view.dart';
import 'outline_generation_page.dart';

/// 历史生成大纲列表页面
class OutlineHistoryPage extends StatefulWidget {
  const OutlineHistoryPage({super.key});

  @override
  State<OutlineHistoryPage> createState() => _OutlineHistoryPageState();
}

class _OutlineHistoryPageState extends State<OutlineHistoryPage> {
  List<OutlineRecord> _records = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // 列表只取小字段：带 content / skeleton 的 SELECT * 遇到超大行会抛
      // "Row too big to fit into CursorWindow"（Android CursorWindow 仅 2 MB）。
      final rows = await OutlineRecordDbHelper().getAllSummaries();
      _records = rows.map((m) => OutlineRecord.fromMap(m)).toList();
    } catch (e, st) {
      debugPrint('[outline_history] 加载大纲列表失败：$e\n$st');
      _records = [];
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(int id) async {
    await OutlineRecordDbHelper().delete(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '历史大纲',
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
          : _error != null
          ? OutlineLoadErrorView(error: _error!, onRetry: _load)
          : _records.isEmpty
          ? const Center(
              child: Text(
                '暂无大纲记录',
                style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final r = _records[index];
                return _RecordTile(
                  record: r,
                  onTap: () => _showDetail(r),
                  onDelete: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认删除'),
                        content: Text('确定要删除「${r.title}」吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => closeDialogSafely(ctx, result: false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => closeDialogSafely(ctx, result: true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) _delete(r.id!);
                  },
                );
              },
            ),
    );
  }

  /// 列表里只有摘要（不含正文 / 骨架），点开时按 id 取完整记录。
  Future<void> _showDetail(OutlineRecord summary) async {
    final id = summary.id;
    if (id == null) return;
    try {
      final row = await OutlineRecordDbHelper().getById(id);
      if (row == null) {
        _showMessage('这条大纲已不存在，可能已被删除');
        await _load();
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _OutlineEditPage(
            record: OutlineRecord.fromMap(row),
            onSaved: _load,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('[outline_history] 读取大纲 id=$id 失败：$e\n$st');
      _showMessage('读取大纲失败：$e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label：',
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 大纲编辑页面（独立 StatefulWidget，正确管理控制器生命周期）
class _OutlineEditPage extends StatefulWidget {
  final OutlineRecord record;
  final VoidCallback onSaved;

  const _OutlineEditPage({required this.record, required this.onSaved});

  @override
  State<_OutlineEditPage> createState() => _OutlineEditPageState();
}

class _OutlineEditPageState extends State<_OutlineEditPage> {
  // 长文本按行拆分为多个小 TextField：单 TextField 承载几万字内容时，
  // 每次按键都会全量重排整份文本，主线程卡死被系统杀死（表现为输入闪退）。
  // 按行拆分后每次输入只重排当前行（几十字），并利用 ListView 虚拟化。
  late final List<TextEditingController> _lineCtrls;
  final ScrollController _scrollCtrl = ScrollController();
  // 当前处于编辑态的行下标（null = 全部行以轻量 Text 渲染）。
  // 非编辑行用 Text 展示：滚动时每帧重建的是廉价 Text 而非重型的
  // EditableText，大幅降低拖动滚动条/快速滑动时的卡顿；点击行进入编辑。
  int? _editingIndex;
  final FocusNode _editFocusNode = FocusNode(); // 编辑行的焦点（复用，行间切换）
  // 小说设定（类型/主题/主角简介/世界观）：可在详情页编辑，
  // 保存后写入记录，影响局部重新生成与「大纲转章节」的写作提示词
  late final TextEditingController _genreCtrl;
  late final TextEditingController _themeCtrl;
  late final TextEditingController _protagonistCtrl;
  late final TextEditingController _worldviewCtrl;

  @override
  void initState() {
    super.initState();
    _lineCtrls = [
      for (final line in widget.record.content.split('\n'))
        TextEditingController(text: _sanitizeLine(line)),
    ];
    _genreCtrl = TextEditingController(text: widget.record.genre);
    _themeCtrl = TextEditingController(text: widget.record.theme);
    _protagonistCtrl = TextEditingController(text: widget.record.protagonist);
    _worldviewCtrl = TextEditingController(text: widget.record.worldview);
  }

  @override
  void dispose() {
    for (final c in _lineCtrls) {
      c.dispose();
    }
    _genreCtrl.dispose();
    _themeCtrl.dispose();
    _protagonistCtrl.dispose();
    _worldviewCtrl.dispose();
    _editFocusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 编辑小说设定弹窗（类型 / 主题 / 主角简介 / 世界观）。
  /// 确认后写入本地控制器，随「保存」持久化到记录。
  Future<void> _editSettings() async {
    final genreCtrl = TextEditingController(text: _genreCtrl.text);
    final themeCtrl = TextEditingController(text: _themeCtrl.text);
    final protagonistCtrl = TextEditingController(text: _protagonistCtrl.text);
    final worldviewCtrl = TextEditingController(text: _worldviewCtrl.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '编辑小说设定',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: genreCtrl,
                decoration: const InputDecoration(
                  labelText: '类型',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: themeCtrl,
                decoration: const InputDecoration(
                  labelText: '主题',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: protagonistCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '主角简介',
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: worldviewCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '世界观',
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: true),
            child: const Text(
              '确定',
              style: TextStyle(color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _genreCtrl.text = genreCtrl.text.trim();
        _themeCtrl.text = themeCtrl.text.trim();
        _protagonistCtrl.text = protagonistCtrl.text.trim();
        _worldviewCtrl.text = worldviewCtrl.text.trim();
      });
    }
    // 弹窗退场动画结束后再释放临时控制器（退场中释放会触发框架断言）
    scheduleControllerDispose(genreCtrl);
    scheduleControllerDispose(themeCtrl);
    scheduleControllerDispose(protagonistCtrl);
    scheduleControllerDispose(worldviewCtrl);
  }

  /// 编辑区合并文本：各行文本按 \n 重新拼接，与原内容格式完全一致
  String get _mergedContent => _lineCtrls.map((c) => c.text).join('\n');

  /// 点击某行进入编辑态：该行切换为 TextField，下一帧主动聚焦弹出键盘。
  /// 已在编辑态时直接聚焦（同一行二次点击）。
  void _startEditing(int index) {
    if (_editingIndex == index) {
      _editFocusNode.requestFocus();
      return;
    }
    setState(() => _editingIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingIndex == index) {
        _editFocusNode.requestFocus();
      }
    });
  }

  /// 退出编辑态（焦点移出/点击其他行时调用）
  void _stopEditing() {
    if (_editingIndex == null) return;
    setState(() => _editingIndex = null);
  }

  /// 清理可能导致文本编辑崩溃的字符：
  /// - 孤立代理项（unpaired surrogate）：输入法组合/光标定位时触发 RangeError
  /// - C0 控制字符（保留 \t 制表、\n 换行、\r 回车）
  static String _sanitizeLine(String s) {
    if (s.isEmpty) return s;
    final units = s.codeUnits;
    final buf = StringBuffer();
    for (int i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0xD800 && u <= 0xDBFF) {
        // 高位代理：有配对低位则原样保留，否则替换为替换符
        if (i + 1 < units.length &&
            units[i + 1] >= 0xDC00 &&
            units[i + 1] <= 0xDFFF) {
          buf.writeCharCode(u);
          buf.writeCharCode(units[i + 1]);
          i++;
        } else {
          buf.write('\uFFFD');
        }
      } else if (u >= 0xDC00 && u <= 0xDFFF) {
        buf.write('\uFFFD'); // 孤立低位代理
      } else if (u < 0x20 && u != 0x09 && u != 0x0A && u != 0x0D) {
        buf.write(' '); // 其他控制字符 → 空格
      } else if (u == 0x7F) {
        buf.write(' '); // DEL
      } else {
        buf.writeCharCode(u);
      }
    }
    return buf.toString();
  }

  /// 将本记录的小说设定带入「一键生成大纲」页面重新生成：
  /// 不关闭当前历史详情页（历史记录不会被替换），生成的新记录会作为新历史保存。
  Future<void> _regenerate() async {
    if (!await _ensureSavedBeforeProceed()) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(
          initialRecord: _recordWithLatestContent(),
        ),
      ),
    );
    widget.onSaved();
  }

  /// 局部重新生成：进入「编辑粗骨/大事件」检查点，仅重写对应下游内容，
  /// 结果另存为新大纲记录，不覆盖当前原记录。
  Future<void> _reedit(String kind) async {
    if (!await _ensureSavedBeforeProceed()) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(
          initialRecord: _recordWithLatestContent(),
          reeditKind: kind,
        ),
      ),
    );
    widget.onSaved();
  }

  /// 继续生成未完成大纲：从未完成的小事件展开块继续生成，结果另存为新记录。
  Future<void> _continueGeneration() async {
    if (!await _ensureSavedBeforeProceed()) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(
          initialRecord: _recordWithLatestContent(),
          reeditKind: 'continue',
        ),
      ),
    );
    widget.onSaved();
  }

  /// 内容或设定是否有未保存的修改
  bool get _isDirty =>
      _mergedContent != widget.record.content ||
      _genreCtrl.text != widget.record.genre ||
      _themeCtrl.text != widget.record.theme ||
      _protagonistCtrl.text != widget.record.protagonist ||
      _worldviewCtrl.text != widget.record.worldview;

  /// 退出页面确认：有未保存修改时弹窗询问「保存并退出 / 不保存 / 取消」。
  /// AppBar 返回按钮与系统返回（PopScope）统一走此入口。
  Future<void> _confirmExitIfDirty() async {
    if (!_isDirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('大纲内容已修改，要保存后退出吗？'),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'discard'),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'cancel'),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => closeDialogSafely(ctx, result: 'save'),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'save':
        await _save(); // _save 内部保存成功后 pop
        break;
      case 'discard':
        if (mounted) Navigator.of(context).pop();
        break;
      case 'cancel':
        break;
    }
  }

  /// 保存当前编辑内容到记录（不退出页面），返回是否实际写入了修改
  Future<bool> _saveCore() async {
    final newContent = _mergedContent;
    final r = widget.record;
    // 内容或设定任一有修改即写入（设定可单独修改，不能只看内容）
    if (!_isDirty) return false;
    await OutlineRecordDbHelper().update(r.id!, {
      'content': newContent,
      'title': r.title,
      // 设定取编辑后的值（详情页可编辑类型/主题/主角简介/世界观）
      'genre': _genreCtrl.text.trim(),
      'theme': _themeCtrl.text.trim(),
      'protagonist': _protagonistCtrl.text.trim(),
      'worldview': _worldviewCtrl.text.trim(),
    });
    // 注意：不再在保存时自动提炼伏笔清单——改为剧情账本页手动「重新提炼」触发
    widget.onSaved();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('大纲已更新')));
    }
    return true;
  }

  Future<void> _save() async {
    await _saveCore();
    if (mounted) Navigator.of(context).pop();
  }

  /// 带未保存修改进入其他流程（重新生成/编辑粗骨/编辑大事件/继续生成）前确认：
  /// 返回 true 表示可以继续（已按选择保存或无需保存）；false 表示用户取消。
  Future<bool> _ensureSavedBeforeProceed() async {
    if (!_isDirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('大纲内容已修改，要保存后继续吗？'),
        actions: [
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'discard'),
            child: const Text(
              '不保存',
              style: TextStyle(color: Color(0xFF999999)),
            ),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => closeDialogSafely(ctx, result: 'save'),
            child: const Text(
              '保存并继续',
              style: TextStyle(color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
    );
    if (choice == 'cancel' || choice == null) return false;
    if (choice == 'save') await _saveCore();
    return true;
  }

  /// 以最新编辑内容构造记录传给生成页（OutlineRecord 不可变，直接传
  /// widget.record 会丢失刚编辑/保存的内容快照）
  OutlineRecord _recordWithLatestContent() => OutlineRecord(
    id: widget.record.id,
    title: widget.record.title,
    genre: _genreCtrl.text.trim(),
    theme: _themeCtrl.text.trim(),
    protagonist: _protagonistCtrl.text.trim(),
    worldview: _worldviewCtrl.text.trim(),
    content: _mergedContent,
    foreshadows: widget.record.foreshadows,
    storyState: widget.record.storyState,
    characters: widget.record.characters,
    skeleton: widget.record.skeleton,
    createdAt: widget.record.createdAt,
  );


  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    return PopScope(
      // 拦截系统返回（Android 返回键/手势）：有未保存修改时先询问是否保存
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmExitIfDirty();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          r.title.isNotEmpty ? r.title : '大纲详情',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)),
          onPressed: _confirmExitIfDirty,
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              '保存',
              style: TextStyle(fontSize: 14, color: Color(0xFF4D6BFE)),
            ),
          ),
        ],
      ),
      body: CupertinoScrollbar(
        controller: _scrollCtrl,
        thumbVisibility: true,
        thickness: 6,
        radius: const Radius.circular(3),
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          // 默认 250px 的预构建区在行数上千时会显著增加滚动重建量，调小以提速
          cacheExtent: 120,
          itemCount: _lineCtrls.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              // 头部：标题 + 设定信息 + 操作按钮，作为列表首项随正文一起滚动，
              // 主角/世界观设定较长时不会被裁剪，整页均可滑动
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (r.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${r.title}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    _infoRow('类型', _genreCtrl.text),
                    _infoRow('主题', _themeCtrl.text),
                    _infoRow('主角简介', _protagonistCtrl.text),
                    _infoRow('世界观', _worldviewCtrl.text),
                    _infoRow('生成时间', r.formattedDate),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _editSettings,
                        icon: const Icon(Icons.edit_note, size: 18),
                        label: const Text(
                          '编辑设定（类型 / 主题 / 主角简介 / 世界观）',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF4D6BFE),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (r.isIncomplete) ...[
                      SizedBox(
                        width: double.infinity,
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: _continueGeneration,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('继续生成'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4D6BFE),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 40,
                      child: OutlinedButton.icon(
                        onPressed: _regenerate,
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('重新生成大纲'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF4D6BFE),
                          side: const BorderSide(color: Color(0xFF4D6BFE)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _reedit('skeleton'),
                            icon: const Icon(Icons.edit_note, size: 18),
                            label: const Text('编辑粗骨'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF4D6BFE),
                              side: const BorderSide(color: Color(0xFF4D6BFE)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _reedit('events'),
                            icon: const Icon(Icons.edit_note, size: 18),
                            label: const Text('编辑大事件'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF4D6BFE),
                              side: const BorderSide(color: Color(0xFF4D6BFE)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '局部重新生成：编辑粗骨/大事件后仅重写对应下游内容，另存为新大纲',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                  ],
                ),
              );
            }
            // 正文行：非编辑行用轻量 Text 渲染（滚动每帧重建成本低），
            // 点击进入编辑态切换为 TextField；格式与单个 TextField 完全一致
            // （按 \n 拆分、保存时重新 join）
            final lineIndex = index - 1;
            if (lineIndex == _editingIndex) {
              return TextField(
                controller: _lineCtrls[lineIndex],
                focusNode: _editFocusNode,
                maxLines: null,
                minLines: 1,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Color(0xFF444444),
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
                // 点击编辑区外（其他行/空白处）退出编辑态
                onTapOutside: (_) => _stopEditing(),
              );
            }
            final text = _lineCtrls[lineIndex].text;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _startEditing(lineIndex),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 18),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    // 空行显示为最小高度行，保证可点击进入编辑
                    text.isEmpty ? '\u00A0' : text,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Color(0xFF444444),
                    ),
                  ),
                ),
              ),
            );
          },
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label：',
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final OutlineRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RecordTile({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title.isNotEmpty ? record.title : '未命名大纲',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${record.genre} · ${record.protagonist}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.formattedDate,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFBBBBBB),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 20,
                color: Color(0xFFCCCCCC),
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
