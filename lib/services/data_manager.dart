/// lib/services/data_manager.dart
/// 数据库导入/导出工具

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'database_helper.dart';

class DataManager {
  DataManager._();

  /// 导出数据库文件（系统保存对话框）
  static Future<String?> exportDatabase() async {
    try {
      final srcPath = await DatabaseHelper.databasePath;
      final src = File(srcPath);
      if (!src.existsSync()) return '数据库文件不存在';

      // 读取文件内容
      final bytes = await src.readAsBytes();
      final savedPath = await FilePicker.saveFile(
        fileName: 'deepseek_backup.db',
        type: FileType.custom,
        allowedExtensions: ['db'],
        bytes: bytes,
      );

      if (savedPath == null) return null; // 用户取消

      return null;
    } catch (e) {
      return '导出失败：$e';
    }
  }

  /// 从文件选择器导入数据库文件
  /// 返回 null 表示成功，否则返回错误信息
  static Future<String?> importDatabase() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['db'],
      );

      if (result == null || result.files.isEmpty) {
        return null; // 用户取消
      }

      final selectedPath = result.files.single.path;
      if (selectedPath == null) return '无法读取选择的文件';

      final selected = File(selectedPath);
      if (!selected.existsSync()) return '所选文件不存在';

      // 校验数据库版本
      final versionError = await DatabaseHelper.validateDbFile(selectedPath);
      if (versionError != null) return versionError;

      // 关闭当前数据库连接
      await DatabaseHelper.closeDatabase();

      // 复制用户选择的文件覆盖当前数据库
      final dstPath = await DatabaseHelper.databasePath;
      final dst = File(dstPath);
      if (dst.existsSync()) await dst.delete();
      await selected.copy(dstPath);

      // 重新打开数据库（下一次 get database 时自动重建连接）
      await DatabaseHelper.database;

      return null;
    } catch (e) {
      return '导入失败：$e';
    }
  }
}
