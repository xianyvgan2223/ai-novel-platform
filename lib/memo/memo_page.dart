// lib/memo/memo_page.dart
// 备忘录列表页 — 支持分类、排序、状态标记、批量删除

import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../services/memo_service.dart';
import 'memo_edit_page.dart';

class MemoPage extends StatefulWidget {
  const MemoPage({super.key});

  @override
  State<MemoPage> createState() => _MemoPageState();
}

class _MemoPageState extends State<MemoPage> {
  List<Memo> _memos = [];
  final Set<int> _selectedIds = {};
  bool _isLoading = true;
  bool _selectMode = false;

  String? _categoryFilter;
  bool _showCompleted = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final all = await MemoService.getAll();
    setState(() {
      _memos = all;
      _isLoading = false;
    });
  }

  List<Memo> get _filteredMemos {
    var list = _memos;
    if (!_showCompleted) {
      list = list.where((m) => !m.isCompleted).toList();
    }
    if (_categoryFilter != null && _categoryFilter!.isNotEmpty) {
      list = list.where((m) => m.category == _categoryFilter).toList();
    }
    return list;
  }

  Future<void> _toggleComplete(Memo memo) async {
    await MemoService.toggleCompletion(memo.id!, !memo.isCompleted);
    _load();
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除 ${_selectedIds.length} 条备忘录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await MemoService.deleteAll(_selectedIds.toList());
    _selectedIds.clear();
    _selectMode = false;
    _load();
  }

  Future<void> _archiveCompleted() async {
    final completed = _memos.where((m) => m.isCompleted).toList();
    if (completed.isEmpty) return;
    final ids = completed.map((m) => m.id!).toList();
    await MemoService.deleteAll(ids);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredMemos;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FE),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: Color(0xFF333333),
            size: 20,
          ),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          _selectMode ? '已选 ${_selectedIds.length} 项' : '备忘录',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: _selectMode
            ? [
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                  onPressed: _deleteSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    _selectedIds.clear();
                    setState(() => _selectMode = false);
                  },
                ),
              ]
            : [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) {
                    switch (v) {
                      case 'archive':
                        _archiveCompleted();
                        break;
                      case 'toggleShow':
                        setState(() => _showCompleted = !_showCompleted);
                        break;
                    }
                  },
                  itemBuilder: (ctx) => [
                    CheckedPopupMenuItem(
                      checked: _showCompleted,
                      onTap: () =>
                          setState(() => _showCompleted = !_showCompleted),
                      child: const Text('显示已完成'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('归档已完成事项'),
                    ),
                  ],
                ),
              ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: const Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.note_add, size: 60, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  Text(
                    _memos.isEmpty ? '还没有备忘录' : '没有匹配的备忘录',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _buildMemoCard(filtered[i]),
            ),
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton.small(
              onPressed: () => _openEdit(),
              backgroundColor: const Color(0xFF6C63FF),
              child: const Icon(Icons.add, color: Colors.white),
            ),
    );
  }

  Widget _buildMemoCard(Memo memo) {
    final selected = _selectedIds.contains(memo.id);
    return RepaintBoundary(
      child: Dismissible(
        key: ValueKey(memo.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.delete_outline, color: Colors.red.shade300),
        ),
        onDismissed: (_) {
          MemoService.delete(memo.id!);
          _memos.removeWhere((m) => m.id == memo.id);
        },
        child: GestureDetector(
          onLongPress: () {
            if (!_selectMode) {
              _selectedIds.add(memo.id!);
              setState(() => _selectMode = true);
            }
          },
          onTap: _selectMode
              ? () {
                  setState(() {
                    if (selected) {
                      _selectedIds.remove(memo.id);
                      if (_selectedIds.isEmpty) _selectMode = false;
                    } else {
                      _selectedIds.add(memo.id!);
                    }
                  });
                }
              : () => _openEdit(memo),
          child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: selected
                  ? const BorderSide(color: Color(0xFF6C63FF), width: 1.5)
                  : BorderSide.none,
            ),
            elevation: 0,
            color: memo.isCompleted ? const Color(0xFFF5F5F5) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // 勾选
                  GestureDetector(
                    onTap: () => _toggleComplete(memo),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: memo.isCompleted
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFFCCCCCC),
                          width: 1.5,
                        ),
                        color: memo.isCompleted
                            ? const Color(0xFF4CAF50)
                            : Colors.transparent,
                      ),
                      child: memo.isCompleted
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          memo.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: memo.isCompleted
                                ? const Color(0xFF999999)
                                : const Color(0xFF333333),
                            decoration: memo.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (memo.content.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            memo.content,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade400,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (memo.category.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0EDFF),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              memo.category,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFF6C63FF),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (memo.priority == MemoPriority.high)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.redAccent,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(memo.updatedAt),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    return '${dt.month}/${dt.day}';
  }

  Future<void> _openEdit([Memo? memo]) async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => MemoEditPage(memo: memo)));
    if (result == true) _load();
  }
}
