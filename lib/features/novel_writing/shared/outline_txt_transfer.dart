import 'dart:convert';
import 'dart:typed_data';

import 'outline_event_syntax.dart';
import 'outline_text_sync.dart';

/// 「一键导出 / 导入大纲 txt」的纯逻辑编解码。
///
/// 这里**只做字节与文本之间的转换**，不碰数据库、不碰文件选择器，
/// 因此可以在纯 Dart 单测里跑（见 `test/outline_txt_transfer_test.dart`）。
/// 行为规格见仓库根目录 `reports/outline-txt-transfer-spec.md`：
///
/// - 导出：UTF-8 + BOM，正文逐字节原样；
/// - 导入：自动识别 UTF-8 BOM / UTF-16LE / UTF-16BE，统一换行后只做
///   [normalizeOutlineText]（只重写事件标题行，其余行逐字节不动）。
///
/// 为什么导出要加 BOM：Windows 记事本遇到无 BOM 的 UTF-8 中文文件会按 GBK
/// 打开，用户看到的是乱码，会以为导出坏了。BOM 对其他编辑器和 App 自身导入
/// 没有影响（导入端会剥掉）。

/// UTF-8 BOM 字节（导出一律带；导入自动剥）。
const List<int> kOutlineTxtUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

/// 导入 txt 失败（文件空、编码不认识……）。
///
/// [message] 直接面向用户，页面原样塞进 SnackBar / 弹窗即可。
class OutlineTxtImportException implements Exception {
  final String message;

  const OutlineTxtImportException(this.message);

  @override
  String toString() => message;
}

/// 导出的 txt 字节：UTF-8（带 BOM），正文**原样**追加在后面。
Uint8List encodeOutlineTxtBytes(String content) {
  final body = utf8.encode(content);
  final bytes = Uint8List(kOutlineTxtUtf8Bom.length + body.length);
  bytes.setRange(0, kOutlineTxtUtf8Bom.length, kOutlineTxtUtf8Bom);
  bytes.setRange(kOutlineTxtUtf8Bom.length, bytes.length, body);
  return bytes;
}

/// 导出文件名：`《书名》大纲.txt`。
///
/// 书名为空用 `未命名大纲.txt`；把文件系统非法字符换成 `_`，
/// 并去掉 Windows 不允许的结尾点 / 空格。
String outlineTxtFileName(String title) {
  final stem = _sanitizeFileStem(title);
  return '《${stem.isEmpty ? '未命名大纲' : stem}》大纲.txt';
}

/// 文件名主干清洗：非法字符 → `_`、去首尾空白与结尾的点、限长 60 字
/// （中文按 UTF-8 每字 3 字节算，60 字 + 书名号与「大纲.txt」远小于
/// Android / Windows 的 255 字节文件名上限）。
String _sanitizeFileStem(String raw) {
  var stem = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (stem.endsWith('.') || stem.endsWith(' ')) {
    stem = stem.substring(0, stem.length - 1);
  }
  if (stem.length > 60) stem = stem.substring(0, 60).trim();
  return stem;
}

/// 导入时的默认书名（弹窗里可改）。
///
/// 优先级与规格一致：
/// 1. 正文前几行里的 `书名：《…》`（本 App 生成 / 导出的大纲通常带这一行）；
/// 2. 文件名去掉 `.txt`、两侧 `《》` 与末尾的「-大纲 / 大纲 / 大纲正文」；
/// 3. 兜底「未命名大纲」。
String deriveOutlineTxtTitle({
  required String fileName,
  required String content,
}) {
  final fromContent = _titleFromBookLine(content);
  if (fromContent.isNotEmpty) return fromContent;

  var stem = fileName.replaceAll('\\', '/');
  final slash = stem.lastIndexOf('/');
  if (slash >= 0) stem = stem.substring(slash + 1);
  stem = stem.trim();
  if (stem.toLowerCase().endsWith('.txt')) {
    stem = stem.substring(0, stem.length - 4);
  }
  stem = stem.trim();
  // 两侧书名号（导出文件名是「《书名》大纲.txt」）
  stem = stem.replaceFirst(RegExp(r'^[《\s\u3000]+'), '');
  stem = stem.replaceFirst(RegExp(r'[》\s\u3000]+$'), '');
  // 末尾的「-大纲 / 大纲 / 大纲正文」是导出时加的后缀，不是书名的一部分
  stem = stem.replaceFirst(RegExp(r'[\s\-_—·]*大纲(正文)?$'), '').trim();
  stem = stem.replaceFirst(RegExp(r'^[《\s\u3000]+'), '');
  stem = stem.replaceFirst(RegExp(r'[》\s\u3000]+$'), '');
  return stem.isEmpty ? '未命名大纲' : stem;
}

/// 正文里的 `书名：《…》`；找不到返回空串。
String _titleFromBookLine(String content) {
  for (final line in content.split('\n').take(3)) {
    final strict = RegExp(r'书名\s*[:：]\s*《\s*([^》]*?)\s*》').firstMatch(line);
    if (strict != null) {
      final title = strict.group(1)!.trim();
      if (title.isNotEmpty) return title;
    }
    // 兼容手写 txt 的「书名：xxx」（没有书名号）
    final loose = RegExp(r'书名\s*[:：]\s*([^《》\n]+)').firstMatch(line);
    if (loose != null) {
      final title = loose.group(1)!.trim();
      if (title.isNotEmpty) return title;
    }
  }
  return '';
}

/// 解码导入的 txt 字节（自动识别 UTF-8 BOM / UTF-16LE / UTF-16BE）。
///
/// 不认识编码时抛 [OutlineTxtImportException]，提示用户另存为 UTF-8；
/// 空文件同样抛异常。返回值可能含 CRLF，统一交给 [prepareOutlineTxtContent]。
String decodeOutlineTxtBytes(List<int> bytes) {
  if (bytes.isEmpty) {
    throw const OutlineTxtImportException('txt 文件是空的');
  }
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (_hasPrefix(data, kOutlineTxtUtf8Bom)) {
    return _decodeUtf8(data, 3);
  }
  if (_hasPrefix(data, const <int>[0xFF, 0xFE])) {
    return _decodeUtf16(data, 2, littleEndian: true);
  }
  if (_hasPrefix(data, const <int>[0xFE, 0xFF])) {
    return _decodeUtf16(data, 2, littleEndian: false);
  }
  return _decodeUtf8(data, 0);
}

/// 导入正文规范化：去残留 BOM 字符、`\r\n`/`\r` → `\n`、去首尾空白，
/// 最后按事件行规范写法统一一次（与「一键生成大纲」落库同一套）。
String prepareOutlineTxtContent(String text) {
  var content = text;
  if (content.startsWith('\uFEFF')) content = content.substring(1);
  content = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (content.isEmpty) {
    throw const OutlineTxtImportException('txt 文件是空的');
  }
  return normalizeOutlineText(content);
}

/// 大纲正文里的事件数（大事件 + 小事件），导入确认弹窗预览用。
int countOutlineTxtEvents(String content) => countOutlineEvents(content);

bool _hasPrefix(Uint8List data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

String _decodeUtf8(Uint8List data, int offset) {
  try {
    return utf8.decode(data.sublist(offset));
  } on FormatException {
    throw const OutlineTxtImportException(
      '文件不是 UTF-8 / UTF-16 编码，请用记事本另存为 UTF-8 后再导入',
    );
  }
}

String _decodeUtf16(Uint8List data, int offset, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = offset; i + 1 < data.length; i += 2) {
    units.add(
      littleEndian
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1],
    );
  }
  return String.fromCharCodes(units);
}
