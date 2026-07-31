import 'package:flutter/material.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/copy_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';

void showCopySettingDialog(BuildContext context, CopyEntity copy) {
  final controller = TextEditingController(text: copy.copyName);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('编辑副本名称'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          hintText: '请输入副本名称',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            // Parent handles the save logic
            Navigator.of(ctx).pop({'copyName': controller.text});
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

void showCharacterSettingDialog(
  BuildContext context,
  CharacterEntity character,
) {
  final controller = TextEditingController(text: character.baseDesc ?? '');
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('编辑人物经历 - ${character.charName}'),
      content: TextField(
        controller: controller,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: '请输入人物经历/背景描述',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            // Parent handles the save logic
            Navigator.of(ctx).pop({'baseDesc': controller.text});
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
