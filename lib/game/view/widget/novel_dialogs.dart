import 'package:flutter/material.dart';

/// 创建副本弹窗
class CreateCopyDialog extends StatefulWidget {
  const CreateCopyDialog({super.key});

  @override
  State<CreateCopyDialog> createState() => _CreateCopyDialogState();
}

class _CreateCopyDialogState extends State<CreateCopyDialog> {
  final _nameCtrl = TextEditingController();
  final _settingCtrl = TextEditingController();
  String _style = '默认';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _settingCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: const Text('新副本', style: TextStyle(fontSize: 13)),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                labelText: '副本名称',
                hintText: '请输入副本名称',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _settingCtrl,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                labelText: '背景设定',
                hintText: '例：修仙世界、末日废土...',
                isDense: true,
                alignLabelWithHint: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
              ),
              maxLines: 3,
              minLines: 2,
            ),
            const SizedBox(height: 6),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '故事风格',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _style,
                  isDense: true,
                  style: const TextStyle(fontSize: 11),
                  items: const [
                    DropdownMenuItem(
                      value: '默认',
                      child: Text('默认', style: TextStyle(fontSize: 10)),
                    ),
                    DropdownMenuItem(
                      value: '热血',
                      child: Text('热血', style: TextStyle(fontSize: 10)),
                    ),
                    DropdownMenuItem(
                      value: '悬疑',
                      child: Text('悬疑', style: TextStyle(fontSize: 10)),
                    ),
                    DropdownMenuItem(
                      value: '幽默',
                      child: Text('幽默', style: TextStyle(fontSize: 10)),
                    ),
                    DropdownMenuItem(
                      value: '深沉',
                      child: Text('深沉', style: TextStyle(fontSize: 10)),
                    ),
                    DropdownMenuItem(
                      value: '浪漫',
                      child: Text('浪漫', style: TextStyle(fontSize: 10)),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _style = v);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontSize: 11)),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isNotEmpty) {
              Navigator.of(context).pop({
                'name': name,
                'setting': _settingCtrl.text.trim(),
                'style': _style,
              });
            }
          },
          child: const Text('创建', style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 创建人物弹窗
class CreateCharacterDialog extends StatefulWidget {
  const CreateCharacterDialog({super.key});

  @override
  State<CreateCharacterDialog> createState() => _CreateCharacterDialogState();
}

class _CreateCharacterDialogState extends State<CreateCharacterDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: const Text('新人物', style: TextStyle(fontSize: 13)),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                labelText: '人物名称',
                hintText: '请输入人物名称',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _descCtrl,
              style: const TextStyle(fontSize: 11),
              decoration: const InputDecoration(
                labelText: '人物描述',
                hintText: '可选',
                isDense: true,
                alignLabelWithHint: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
              ),
              maxLines: 3,
              minLines: 2,
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontSize: 11)),
        ),
        TextButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isNotEmpty) {
              Navigator.of(
                context,
              ).pop({'name': name, 'desc': _descCtrl.text.trim()});
            }
          },
          child: const Text('创建', style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}
