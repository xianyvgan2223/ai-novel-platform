import 'dart:convert';
import 'dart:typed_data';

import 'domain/character_profile.dart';
import 'outline_event_syntax.dart';
import 'outline_text_sync.dart';

/// 「一键导出 / 导入大纲 txt」的纯逻辑编解码。
///
/// 这里**只做文本与字节之间的转换**，不碰数据库、不碰文件选择器，
/// 因此可以在纯 Dart 单测里跑（见 `test/outline_txt_transfer_test.dart`）。
/// 行为规格见仓库根目录 `reports/outline-txt-transfer-spec.md`：
///
/// - 导出：UTF-8 + BOM 的结构化 txt（v2 格式），除了大纲正文，还带
///   书名 / 类型 / 主题 / 主角简介 / 世界观 / 伏笔清单 / 人物档案；
/// - 导入：自动识别 UTF-8 BOM / UTF-16LE / UTF-16BE；识别 v2 结构化格式时
///   把设定与人物档案还原成字段，正文做 [normalizeOutlineText]（只重写事件
///   标题行）；没有 v2 文件头的旧版 txt 仍按「纯正文」兼容导入。
///
/// 为什么导出要加 BOM：Windows 记事本遇到无 BOM 的 UTF-8 中文文件会按 GBK
/// 打开，用户看到的是乱码，会以为导出坏了。BOM 对其他编辑器和 App 自身导入
/// 没有影响（导入端会剥掉）。

/// UTF-8 BOM 字节（导出一律带；导入自动剥）。
const List<int> kOutlineTxtUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

/// v2 结构化格式的文件头（第一行非空内容必须与它完全一致才按结构化解析）。
const String kOutlineTxtMagic = '# DeepSeek 大纲导出 v2';

/// v2 的章节名（`## 名称`）。只有这些已知名称会开启新章节，
/// 设定内容里出现的其它 `## 行` 原样保留。
const String kOutlineTxtBodySection = '大纲正文';
const List<String> kOutlineTxtSectionNames = <String>[
  '书名',
  '类型',
  '主题',
  '主角简介',
  '世界观',
  '伏笔清单',
  '人物档案',
  kOutlineTxtBodySection,
];

/// 导入 txt 失败（文件空、编码不认识……）。
///
/// [message] 直接面向用户，页面原样塞进 SnackBar / 弹窗即可。
class OutlineTxtImportException implements Exception {
  final String message;

  const OutlineTxtImportException(this.message);

  @override
  String toString() => message;
}

/// 解析后的一本大纲（正文 + 小说设定 + 人物档案）。
///
/// [structured] 为 false 表示这是旧版「纯正文 txt」（没有 v2 文件头），
/// 此时设定字段为空、书名由文件名 / 正文书名行推导。
class OutlineTxtDocument {
  /// 是否 v2 结构化文件
  final bool structured;

  /// v2 `## 书名` 章节；旧格式为空串
  final String title;

  final String genre;
  final String theme;
  final String protagonist;
  final String worldview;
  final String foreshadows;

  /// 人物档案（v2 `## 人物档案` 章节解析结果）
  final List<CharacterProfile> characters;

  /// 大纲正文（已去 BOM / 统一换行 / 规范化事件标题）
  final String content;

  const OutlineTxtDocument({
    required this.structured,
    this.title = '',
    this.genre = '',
    this.theme = '',
    this.protagonist = '',
    this.worldview = '',
    this.foreshadows = '',
    this.characters = const <CharacterProfile>[],
    this.content = '',
  });

  /// 可直接写入 `outline_records.characters` 的 JSON；没有人物时为**空串**
  /// （与库里「还没提炼过人物档案」的状态一致，不写 `[]` 污染旧数据）。
  String get charactersJson => characters.isEmpty
      ? ''
      : jsonEncode([for (final c in characters) c.toJson()]);

  int get characterCount => characters.length;

  /// 是否识别到任何小说设定（用于导入弹窗提示 / 落库判断）
  bool get hasSettings =>
      genre.trim().isNotEmpty ||
      theme.trim().isNotEmpty ||
      protagonist.trim().isNotEmpty ||
      worldview.trim().isNotEmpty ||
      foreshadows.trim().isNotEmpty ||
      characters.isNotEmpty;

  /// 导入弹窗里的设定摘要：如「类型、主题、人物档案 2 人」。没有任何设定时为空串。
  String get settingsSummary {
    final labels = <String>[
      if (genre.trim().isNotEmpty) '类型',
      if (theme.trim().isNotEmpty) '主题',
      if (protagonist.trim().isNotEmpty) '主角简介',
      if (worldview.trim().isNotEmpty) '世界观',
      if (foreshadows.trim().isNotEmpty) '伏笔清单',
    ];
    final parts = <String>[
      if (labels.isNotEmpty) labels.join('、'),
      if (characters.isNotEmpty) '人物档案 ${characters.length} 人',
    ];
    return parts.join(' · ');
  }
}

/// 导出的 txt 文本（不含 BOM；UTF-8 字节由 [encodeOutlineTxtDocumentBytes] 加）。
///
/// 结构（空字段整节省略）：
/// ```
/// # DeepSeek 大纲导出 v2
///
/// ## 书名
/// 天下第一尸兄世界
///
/// ## 类型
/// 玄幻
///
/// ## 主角简介
/// ...
///
/// ## 人物档案
/// - 姓名：顾泽
///   描述：...
///   能力：...
///   性格：...
///   主角：是
///
/// ## 大纲正文
///
/// <正文原样>
/// ```
String renderOutlineTxtDocument({
  required String title,
  String genre = '',
  String theme = '',
  String protagonist = '',
  String worldview = '',
  String foreshadows = '',
  String charactersJson = '',
  required String content,
}) {
  final out = StringBuffer()
    ..writeln(kOutlineTxtMagic)
    ..writeln();

  void addSection(String name, String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    out
      ..writeln('## $name')
      ..writeln(text)
      ..writeln();
  }

  addSection('书名', title);
  addSection('类型', genre);
  addSection('主题', theme);
  addSection('主角简介', protagonist);
  addSection('世界观', worldview);
  addSection('伏笔清单', foreshadows);
  addSection(
    '人物档案',
    _renderCharacterSection(_parseCharacterProfiles(charactersJson)),
  );

  out.writeln('## $kOutlineTxtBodySection');
  out.writeln();
  out.write(content);
  if (!content.endsWith('\n')) out.writeln();
  return out.toString();
}

/// 导出的 txt 字节：UTF-8（带 BOM）。
Uint8List encodeOutlineTxtDocumentBytes({
  required String title,
  String genre = '',
  String theme = '',
  String protagonist = '',
  String worldview = '',
  String foreshadows = '',
  String charactersJson = '',
  required String content,
}) {
  final body = utf8.encode(
    renderOutlineTxtDocument(
      title: title,
      genre: genre,
      theme: theme,
      protagonist: protagonist,
      worldview: worldview,
      foreshadows: foreshadows,
      charactersJson: charactersJson,
      content: content,
    ),
  );
  final bytes = Uint8List(kOutlineTxtUtf8Bom.length + body.length);
  bytes.setRange(0, kOutlineTxtUtf8Bom.length, kOutlineTxtUtf8Bom);
  bytes.setRange(kOutlineTxtUtf8Bom.length, bytes.length, body);
  return bytes;
}

/// 导出前的正文整理：把识别到的事件 / 幕标题行统一成规范写法并重新编号
/// （大事件全篇连续、小事件在每个大事件内从 1 重新开始）。
///
/// 为什么需要：大纲编辑里新增事件时写入的行号取的是「全文事件序号」，
/// 可能出现重号 / 跳号（例如新增大事件写成「大事件14」、新小事件写成
/// 「小事件6」）。导出前统一一次，txt 里的编号就与真实顺序一致；
/// **只改标题行**，概要与其他正文逐字节保留；数据库原文不动；幂等。
String prepareOutlineTxtExportContent(String content) =>
    normalizeOutlineText(content);

/// 解析导入的 txt 文本（必须是 [decodeOutlineTxtBytes] 解码后的结果）。
///
/// - 第一行非空内容为 [kOutlineTxtMagic] → 按 v2 结构化格式解析；
/// - 否则按旧版「纯正文」兼容处理（设定为空，正文规范化后返回）；
/// - 整份文件为空 / 只有 BOM → 抛 [OutlineTxtImportException]。
OutlineTxtDocument parseOutlineTxtDocument(String text) {
  var raw = text;
  if (raw.startsWith('\uFEFF')) raw = raw.substring(1);
  raw = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = raw.split('\n');
  final firstNonEmpty = lines.indexWhere((line) => line.trim().isNotEmpty);
  if (firstNonEmpty < 0) {
    throw const OutlineTxtImportException('txt 文件是空的');
  }

  // 旧版纯正文：保持和以前完全一致的导入行为
  if (lines[firstNonEmpty].trim() != kOutlineTxtMagic) {
    return OutlineTxtDocument(
      structured: false,
      content: prepareOutlineTxtContent(raw),
    );
  }

  final sections = <String, List<String>>{};
  final bodyLines = <String>[];
  String? current;
  for (var i = firstNonEmpty + 1; i < lines.length; i++) {
    final line = lines[i];
    if (current == kOutlineTxtBodySection) {
      bodyLines.add(line);
      continue;
    }
    final header = RegExp(r'^##\s+(.+?)\s*$').firstMatch(line);
    final name = header?.group(1)?.trim();
    if (name != null && kOutlineTxtSectionNames.contains(name)) {
      current = name;
      sections[name] = <String>[];
      continue;
    }
    if (current != null) sections[current]!.add(line);
  }

  String section(String name) =>
      (sections[name] ?? const <String>[]).join('\n').trim();

  final bodyText = bodyLines.join('\n').trim();
  final document = OutlineTxtDocument(
    structured: true,
    title: _firstNonEmptyLine(section('书名')),
    genre: section('类型'),
    theme: section('主题'),
    protagonist: section('主角简介'),
    worldview: section('世界观'),
    foreshadows: section('伏笔清单'),
    characters: _parseCharacterSection(section('人物档案')),
    content: bodyText.isEmpty ? '' : normalizeOutlineText(bodyText),
  );

  // 结构化文件但一个字都没有：按空文件提示，避免导入一条全空的记录
  if (document.title.isEmpty &&
      !document.hasSettings &&
      document.content.isEmpty) {
    throw const OutlineTxtImportException('txt 文件是空的');
  }
  return document;
}

/// 解码 + 解析一步到位（导入入口用）。
OutlineTxtDocument decodeOutlineTxtDocumentBytes(List<int> bytes) =>
    parseOutlineTxtDocument(decodeOutlineTxtBytes(bytes));

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
///
/// v2 文件优先用 `## 书名` 章节（由 [deriveOutlineTxtTitleForDocument] 处理）。
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

/// 导入时的默认书名（先看 v2 `## 书名`，再回退到正文书名行 / 文件名）。
String deriveOutlineTxtTitleForDocument({
  required OutlineTxtDocument document,
  required String fileName,
}) {
  final fromSection = document.title.trim();
  if (fromSection.isNotEmpty) return fromSection;
  return deriveOutlineTxtTitle(fileName: fileName, content: document.content);
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
/// 空文件同样抛异常。返回值可能含 CRLF，统一交给 [parseOutlineTxtDocument]。
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

/* ───────────────────────── 人物档案的文本化 / 解析 ───────────────────────── */

/// `outline_records.characters` JSON → 人物列表。
///
/// - 空串 → 空列表；
/// - JSON 坏掉 / 结构不对 → 空列表（导出时只丢人物档案这一块，绝不把
///   整本书导不出去；导入时不会用空列表覆盖任何已有数据，因为导入是新建记录）。
List<CharacterProfile> _parseCharacterProfiles(String charactersJson) {
  final text = charactersJson.trim();
  if (text.isEmpty) return const <CharacterProfile>[];
  try {
    final data = jsonDecode(text);
    if (data is! List) return const <CharacterProfile>[];
    return <CharacterProfile>[
      for (final item in data)
        if (item is Map)
          CharacterProfile.fromJson(Map<String, dynamic>.from(item)),
    ];
  } catch (_) {
    return const <CharacterProfile>[];
  }
}

/// 人物列表 → 人类可读段落：
/// ```
/// - 姓名：顾泽
///   描述：第一行
///     第二行
///   能力：...
///   主角：是
/// ```
/// 多行字段的续行统一额外缩进 4 个空格；[CharacterProfile.isProtagonist]
/// 写成「主角：是 / 否」。
String _renderCharacterSection(List<CharacterProfile> characters) {
  final usable = characters
      .where(
        (c) =>
            c.name.trim().isNotEmpty ||
            c.description.trim().isNotEmpty ||
            c.abilities.trim().isNotEmpty ||
            c.personality.trim().isNotEmpty,
      )
      .toList();
  if (usable.isEmpty) return '';

  final out = StringBuffer();
  for (final c in usable) {
    out.writeln('- 姓名：${c.name.trim()}');
    void addField(String label, String value) {
      final text = value.trim();
      if (text.isEmpty) return;
      final lines = text.split('\n');
      out.writeln('  $label：${lines.first}');
      for (final line in lines.skip(1)) {
        out.writeln('    $line');
      }
    }

    addField('描述', c.description);
    addField('能力', c.abilities);
    addField('性格', c.personality);
    out.writeln('  主角：${c.isProtagonist ? '是' : '否'}');
  }
  return out.toString().trim();
}

/// 人物段落 → 人物列表（[renderOutlineTxtDocument] 的逆过程）。
///
/// 容错：字段顺序任意、缺少「主角」当否、缩进不标准时按宽松规则处理；
/// 一条都解析不出来返回空列表。
List<CharacterProfile> _parseCharacterSection(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const <CharacterProfile>[];

  final result = <CharacterProfile>[];
  var name = '';
  var description = '';
  var abilities = '';
  var personality = '';
  var isProtagonist = false;
  String? currentField;

  void flush() {
    final hasAny =
        name.trim().isNotEmpty ||
        description.trim().isNotEmpty ||
        abilities.trim().isNotEmpty ||
        personality.trim().isNotEmpty;
    if (!hasAny) return;
    result.add(
      CharacterProfile(
        name: name.trim(),
        description: description.trim(),
        abilities: abilities.trim(),
        personality: personality.trim(),
        isProtagonist: isProtagonist,
      ),
    );
  }

  void appendToField(String value) {
    switch (currentField) {
      case '描述':
        description = description.isEmpty ? value : '$description\n$value';
      case '能力':
        abilities = abilities.isEmpty ? value : '$abilities\n$value';
      case '性格':
        personality = personality.isEmpty ? value : '$personality\n$value';
      case '姓名':
        name = name.isEmpty ? value : '$name\n$value';
    }
  }

  for (final line in trimmed.split('\n')) {
    final textLine = line.trimRight();
    if (textLine.trim().isEmpty) continue;

    // 新人物：行首 `- 姓名：xxx`
    final newCharacter = RegExp(
      r'^-\s*姓名\s*[:：]\s*(.*)$',
    ).firstMatch(textLine.trim());
    if (newCharacter != null) {
      flush();
      name = newCharacter.group(1)!.trim();
      description = '';
      abilities = '';
      personality = '';
      isProtagonist = false;
      currentField = '姓名';
      continue;
    }

    // 字段行：最多 2 个空格缩进的「描述 / 能力 / 性格 / 主角：」
    final field = RegExp(
      r'^[ \t]{0,2}(描述|能力|性格|主角|姓名)\s*[:：]\s?(.*)$',
    ).firstMatch(textLine);
    if (field != null) {
      final label = field.group(1)!;
      final value = field.group(2)!.trim();
      if (label == '主角') {
        isProtagonist = value == '是' || value.toLowerCase() == 'true';
        currentField = null;
      } else if (label == '姓名') {
        name = value;
        currentField = '姓名';
      } else {
        switch (label) {
          case '描述':
            description = '';
          case '能力':
            abilities = '';
          case '性格':
            personality = '';
        }
        currentField = label;
        appendToField(value);
      }
      continue;
    }

    // 续行：导出的多行字段用 4 个空格缩进，这里去掉 4 个空格后追加
    if (currentField != null && line.startsWith('    ')) {
      appendToField(line.substring(4).trimRight());
    } else if (currentField != null) {
      appendToField(textLine.trim());
    }
  }
  flush();
  return result;
}

String _firstNonEmptyLine(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

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
