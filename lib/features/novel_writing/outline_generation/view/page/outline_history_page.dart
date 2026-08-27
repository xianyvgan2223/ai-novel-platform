import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../../shared/domain/outline_record.dart';
import '../../../shared/data/outline_record_db_helper.dart';
import '../../../outline_format/service/outline_format_service.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await OutlineRecordDbHelper().getAll();
      _records = rows.map((m) => OutlineRecord.fromMap(m)).toList();
    } catch (_) {}
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
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
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

  void _showDetail(OutlineRecord r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _OutlineEditPage(record: r, onSaved: _load),
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

  @override
  void initState() {
    super.initState();
    _lineCtrls = [
      for (final line in widget.record.content.split('\n'))
        TextEditingController(text: _sanitizeLine(line)),
    ];
  }

  @override
  void dispose() {
    for (final c in _lineCtrls) {
      c.dispose();
    }
    _editFocusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(initialRecord: widget.record),
      ),
    );
    widget.onSaved();
  }

  /// 局部重新生成：进入「编辑粗骨/大事件」检查点，仅重写对应下游内容，
  /// 结果另存为新大纲记录，不覆盖当前原记录。
  Future<void> _reedit(String kind) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(
          initialRecord: widget.record,
          reeditKind: kind,
        ),
      ),
    );
    widget.onSaved();
  }

  /// 继续生成未完成大纲：从未完成的小事件展开块继续生成，结果另存为新记录。
  Future<void> _continueGeneration() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutlineGenerationPage(
          initialRecord: widget.record,
          reeditKind: 'continue',
        ),
      ),
    );
    widget.onSaved();
  }

  /// 内容是否有未保存的修改
  bool get _isDirty => _mergedContent != widget.record.content;

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
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
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

  Future<void> _save() async {
    final newContent = _mergedContent;
    final r = widget.record;
    if (newContent != r.content) {
      await OutlineRecordDbHelper().update(r.id!, {
        'content': newContent,
        'title': r.title,
        'genre': r.genre,
        'theme': r.theme,
        'protagonist': r.protagonist,
        'worldview': r.worldview,
      });
      // 大纲内容被修改，后台重新提炼伏笔清单，避免注入过期信息
      unawaited(_refreshForeshadows(r.id!, newContent));
      widget.onSaved();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('大纲已更新')));
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// 后台重新提炼伏笔清单（不阻塞、失败静默）
  Future<void> _refreshForeshadows(int id, String content) async {
    try {
      final service = OutlineFormatService();
      final settings = await service.loadSettings();
      if (settings.apiKey.isEmpty) return;
      final foreshadows = await service.extractForeshadows(
        apiKey: settings.apiKey,
        apiParams: {
          'model': settings.outlineSetting.model,
          'temperature': 0.3,
          'max_tokens': settings.outlineSetting.maxTokens,
        },
        outlineContent: content,
      );
      if (foreshadows.isNotEmpty) {
        await OutlineRecordDbHelper().update(id, {'foreshadows': foreshadows});
      }
    } catch (_) {}
  }

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
                    _infoRow('类型', r.genre),
                    _infoRow('主题', r.theme),
                    _infoRow('主角', r.protagonist),
                    _infoRow('世界观', r.worldview),
                    _infoRow('生成时间', r.formattedDate),
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
