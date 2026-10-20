/// 小说游戏的两个编辑弹窗（编辑副本名称 / 编辑人物经历）。
///
/// v2 风格（与主设置页 / kit 的大编辑弹窗同一套语言）：
/// - 白底 20dp 圆角弹窗，标题 16sp w600 [kSettingsTitle]；
/// - 输入框填充 [kSettingsFieldBg]、12dp 圆角、静态描边 [kSettingsFieldBorder]，
///   聚焦时 1.2dp 主色描边；
/// - 底部「取消」文字按钮（[kSettingsValue]）+「保存」主色胶囊
///   （[SettingsSaveButton]，高 34dp）。
///
/// **返回值结构必须保持不变**（调用方按 key 取值）：
/// - 编辑副本名称 → `{'copyName': String}`
/// - 编辑人物经历 → `{'baseDesc': String}`
/// 取消 / 点遮罩关闭时 pop null，不改动任何数据。
///
/// 临时 TextEditingController 用 shared/dialog_utils 的方式：关闭后延迟释放，
/// 避免退场动画期间仍挂载的 TextField 使用已释放的 controller。
library;

import 'package:flutter/material.dart';

import 'package:deepseekapp/core/widgets/settings_kit.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/character_entity.dart';
import 'package:deepseekapp/features/game/novel_game/model/entity/copy_entity.dart';
import 'package:deepseekapp/features/novel_writing/shared/dialog_utils.dart';

/// 编辑副本名称。保存时 pop `{'copyName': ...}`。
void showCopySettingDialog(BuildContext context, CopyEntity copy) {
  _showEditDialog(
    context,
    title: '编辑副本名称',
    initialText: copy.copyName,
    hintText: '请输入副本名称',
    minLines: 1,
    maxLines: 1,
    resultKey: 'copyName',
  );
}

/// 编辑人物经历（背景描述）。保存时 pop `{'baseDesc': ...}`。
void showCharacterSettingDialog(
  BuildContext context,
  CharacterEntity character,
) {
  _showEditDialog(
    context,
    title: '编辑人物经历 - ${character.charName}',
    initialText: character.baseDesc ?? '',
    hintText: '请输入人物经历/背景描述',
    minLines: 5,
    maxLines: 5,
    resultKey: 'baseDesc',
  );
}

/// 两个弹窗共用的 v2 编辑弹窗骨架。
///
/// [resultKey] 决定 pop 出去的 Map 键名，两个入口各自固定一个 key，
/// 保证调用方按原结构取值（行为清单 §4.7「弹窗返回值结构不变」）。
void _showEditDialog(
  BuildContext context, {
  required String title,
  required String initialText,
  required String hintText,
  required int minLines,
  required int maxLines,
  required String resultKey,
}) {
  final controller = TextEditingController(text: initialText);

  showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: kSettingsTitle,
                ),
              ),
              const SizedBox(height: 14),
              // 输入框
              TextField(
                controller: controller,
                minLines: minLines,
                maxLines: maxLines,
                // 单行（副本名）保持文本键盘 + 完成键；多行（人物经历）用多行键盘，
                // 与改造前的输入语义一致。
                keyboardType: maxLines > 1
                    ? TextInputType.multiline
                    : TextInputType.text,
                textInputAction: maxLines > 1
                    ? TextInputAction.newline
                    : TextInputAction.done,
                cursorColor: kSettingsPrimary,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: kSettingsValue,
                ),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: const TextStyle(
                    fontSize: 12.5,
                    color: kSettingsHint,
                  ),
                  filled: true,
                  fillColor: kSettingsFieldBg,
                  isDense: true,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kSettingsFieldBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kSettingsFieldBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: kSettingsPrimary,
                      width: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 底部按钮：取消文字按钮 + 保存主色胶囊
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      if (!closeDialogSafely(ctx)) return;
                      scheduleControllerDispose(controller);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: kSettingsValue,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SettingsSaveButton(
                    onPressed: () {
                      if (!closeDialogSafely(
                        ctx,
                        result: {resultKey: controller.text},
                      )) {
                        return;
                      }
                      scheduleControllerDispose(controller);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
