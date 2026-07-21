// lib/memo/memo_edit_page.dart
// 备忘录新增/编辑页

import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../services/memo_service.dart';

class MemoEditPage extends StatefulWidget {
  final Memo? memo;
  const MemoEditPage({super.key, this.memo});

  @override
  State<MemoEditPage> createState() => _MemoEditPageState();
}

class _MemoEditPageState extends State<MemoEditPage> {
  late TextEditingController _titleCtrl;
  late TextEditingController _contentCtrl;
  late TextEditingController _categoryCtrl;
  late MemoPriority _priority;

  bool get _isEdit => widget.memo != null;

  @override
  void initState() {
    super.initState();
    final m = widget.memo;
    _titleCtrl = TextEditingController(text: m?.title ?? '');
    _contentCtrl = TextEditingController(text: m?.content ?? '');
    _categoryCtrl = TextEditingController(text: m?.category ?? '');
    _priority = m?.priority ?? MemoPriority.medium;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入标题'), duration: Duration(seconds: 1)),
      );
      return;
    }

    final now = DateTime.now();
    final memo = Memo(
      id: widget.memo?.id,
      title: title,
      content: _contentCtrl.text.trim(),
      isCompleted: widget.memo?.isCompleted ?? false,
      priority: _priority,
      category: _categoryCtrl.text.trim(),
      createdAt: widget.memo?.createdAt ?? now,
      updatedAt: now,
    );

    if (_isEdit) {
      await MemoService.update(memo);
    } else {
      await MemoService.insert(memo);
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    if (!_isEdit || widget.memo?.id == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定删除这条备忘录？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true && widget.memo?.id != null) {
      await MemoService.delete(widget.memo!.id!);
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FE),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF333333), size: 20),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          _isEdit ? '编辑备忘录' : '新建备忘录',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
              onPressed: _delete,
            ),
          TextButton(
            onPressed: _save,
            child: const Text('保存',
                style: TextStyle(
                    color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEEEEEE)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            TextField(
              controller: _titleCtrl,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                hintText: '标题',
                hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                border: InputBorder.none,
                filled: false,
              ),
              textInputAction: TextInputAction.next,
            ),
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            const SizedBox(height: 12),

            // 优先级
            Row(
              children: [
                const Text('优先级',
                    style: TextStyle(fontSize: 13, color: Color(0xFF666666))),
                const SizedBox(width: 12),
                ...MemoPriority.values.map((p) {
                  final selected = _priority == p;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        p.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? Colors.white : const Color(0xFF333333),
                        ),
                      ),
                      selected: selected,
                      selectedColor: p == MemoPriority.high
                          ? Colors.redAccent
                          : p == MemoPriority.medium
                              ? const Color(0xFF6C63FF)
                              : const Color(0xFF4CAF50),
                      backgroundColor: const Color(0xFFF0F0F0),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _priority = p),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 12),

            // 分类
            TextField(
              controller: _categoryCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '分类（如：工作、学习、生活）',
                hintStyle:
                    const TextStyle(fontSize: 13, color: Color(0xFFBBBBBB)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),

            // 内容
            TextField(
              controller: _contentCtrl,
              style: const TextStyle(fontSize: 14, height: 1.6),
              decoration: const InputDecoration(
                hintText: '内容',
                hintStyle: TextStyle(color: Color(0xFFBBBBBB)),
                border: InputBorder.none,
                filled: false,
              ),
              maxLines: 10,
              minLines: 5,
            ),
          ],
        ),
      ),
    );
  }
}
