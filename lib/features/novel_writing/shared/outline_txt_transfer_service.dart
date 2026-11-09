import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'data/outline_record_db_helper.dart';
import 'domain/outline_record.dart';
import 'outline_chapter_sync.dart';
import 'outline_txt_transfer.dart';

/// 导出结果：成功 / 用户取消 / 记录没有正文。
///
/// 取消与失败要分开：用户点了系统保存框的「取消」不该弹「导出失败」，
/// 页面才能做到「取消静默」。
enum OutlineTxtExportStatus { exported, cancelled, emptyContent }

class OutlineTxtExportResult {
  final OutlineTxtExportStatus status;

  /// 系统保存框返回的目标路径（部分平台为 content:// URI）；取消时为 null。
  final String? savedPath;

  const OutlineTxtExportResult(this.status, {this.savedPath});
}

/// 用户选中并解析完成的导入草稿（还没落库）。
class OutlineTxtImportDraft {
  /// 用户选的原文件名（确认弹窗里显示「文件：xxx.txt」）
  final String fileName;

  /// 按 v2 书名章节 / 正文书名行 / 文件名推导出来的默认书名（弹窗里可改）
  final String title;

  /// 已去 BOM、统一换行、按事件行规范写法整理过的正文
  final String content;

  /// v2 文件里识别到的小说设定（旧版纯正文 txt 全为空）
  final String genre;
  final String theme;
  final String protagonist;
  final String worldview;
  final String foreshadows;

  /// 人物档案（可直接写库的 JSON；没识别到人物时为空串）
  final String charactersJson;

  final int characterCount;

  /// 是否识别到任何小说设定（弹窗提示用）
  bool get hasSettings =>
      genre.trim().isNotEmpty ||
      theme.trim().isNotEmpty ||
      protagonist.trim().isNotEmpty ||
      worldview.trim().isNotEmpty ||
      foreshadows.trim().isNotEmpty ||
      charactersJson.trim().isNotEmpty;

  /// 弹窗里的设定摘要，如「类型、主题 · 人物档案 2 人」；没有设定时为空串。
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
      if (characterCount > 0) '人物档案 $characterCount 人',
    ];
    return parts.join(' · ');
  }

  const OutlineTxtImportDraft({
    required this.fileName,
    required this.title,
    required this.content,
    this.genre = '',
    this.theme = '',
    this.protagonist = '',
    this.worldview = '',
    this.foreshadows = '',
    this.charactersJson = '',
    this.characterCount = 0,
  });

  /// 字数（按 Unicode 码点算，中文一字算一字）
  int get charCount => content.runes.length;

  /// 识别到的事件数（大事件 + 小事件）
  int get eventCount => countOutlineTxtEvents(content);
}

/// 导入完成结果。
class OutlineTxtImportResult {
  /// 新建的大纲记录（带 id，可直接进「大纲编辑」）
  final OutlineRecord record;

  /// 事件数（按正文解析）
  final int eventCount;

  /// 章节结构解析失败时的错误文案；成功为 null。
  ///
  /// 解析失败不回滚记录：正文已经安全落库，用户仍可进「大纲编辑」重试。
  final String? structureError;

  const OutlineTxtImportResult({
    required this.record,
    required this.eventCount,
    this.structureError,
  });
}

/// 手机端「导出 / 导入大纲 txt」的读写服务。
///
/// 只负责「文件选择器 + 数据库」这两件有副作用的事；纯编解码在
/// `outline_txt_transfer.dart`（可单测）。UI 在
/// `novel_writing_page.dart` + 两个弹层组件里。
class OutlineTxtTransferService {
  final OutlineRecordDbHelper _records;

  OutlineTxtTransferService({OutlineRecordDbHelper? records})
    : _records = records ?? OutlineRecordDbHelper();

  /// 导出弹层用的作品列表（轻字段，**不带正文**）。
  ///
  /// 走 `getAllSummaries()`：Android 的 CursorWindow 只有 2 MB，
  /// 列表若带上 content / skeleton 会整条查询抛
  /// "Row too big to fit into CursorWindow"。
  Future<List<OutlineRecord>> loadNovelSummaries() async {
    final rows = await _records.getAllSummaries();
    return rows.map(OutlineRecord.fromMap).toList();
  }

  /// 把一部作品导出成结构化 txt（正文 + 小说设定 + 人物档案）。
  ///
  /// 正文为空时返回 [OutlineTxtExportStatus.emptyContent]；
  /// 用户在系统保存框取消时返回 [OutlineTxtExportStatus.cancelled]。
  Future<OutlineTxtExportResult> exportOutlineTxt(OutlineRecord summary) async {
    final id = summary.id;
    if (id == null) {
      return const OutlineTxtExportResult(OutlineTxtExportStatus.emptyContent);
    }
    final row = await _records.getById(id);
    final rawContent = (row?['content'] as String?) ?? '';
    if (rawContent.trim().isEmpty) {
      return const OutlineTxtExportResult(OutlineTxtExportStatus.emptyContent);
    }
    // 导出前自动规范事件 / 幕标题的写法与编号（只改标题行，概要原样保留；
    // 数据库里的大纲正文不动）——txt 里不会带着重号 / 跳号出去。
    final content = prepareOutlineTxtExportContent(rawContent);
    final title = ((row?['title'] as String?) ?? summary.title).trim();
    final bytes = encodeOutlineTxtDocumentBytes(
      title: title,
      genre: (row?['genre'] as String?) ?? '',
      theme: (row?['theme'] as String?) ?? '',
      protagonist: (row?['protagonist'] as String?) ?? '',
      worldview: (row?['worldview'] as String?) ?? '',
      foreshadows: (row?['foreshadows'] as String?) ?? '',
      charactersJson: (row?['characters'] as String?) ?? '',
      content: content,
    );
    final savedPath = await FilePicker.saveFile(
      dialogTitle: '导出大纲 txt',
      fileName: outlineTxtFileName(title),
      type: FileType.custom,
      allowedExtensions: const <String>['txt'],
      bytes: bytes,
    );
    if (savedPath == null) {
      return const OutlineTxtExportResult(OutlineTxtExportStatus.cancelled);
    }
    return OutlineTxtExportResult(
      OutlineTxtExportStatus.exported,
      savedPath: savedPath,
    );
  }

  /// 弹文件选择器读一个 txt；用户取消返回 null。
  ///
  /// 解码 / 空文件失败抛 [OutlineTxtImportException]。
  Future<OutlineTxtImportDraft?> pickImportDraft() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择大纲 txt',
      type: FileType.custom,
      allowedExtensions: const <String>['txt'],
      // withData: true 让 Android 直接把内容带回来（SAF 的 content:// 不一定
      // 能按路径读）；个别平台不给 bytes 时再退回按 path 读。
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    Uint8List? bytes = file.bytes;
    final path = file.path;
    if (bytes == null && path != null) {
      try {
        bytes = await File(path).readAsBytes();
      } on FileSystemException {
        throw const OutlineTxtImportException('无法读取所选文件，请重新选择');
      }
    }
    if (bytes == null) {
      throw const OutlineTxtImportException('无法读取所选文件，请重新选择');
    }
    final document = decodeOutlineTxtDocumentBytes(bytes);
    return OutlineTxtImportDraft(
      fileName: file.name,
      title: deriveOutlineTxtTitleForDocument(
        document: document,
        fileName: file.name,
      ),
      content: document.content,
      genre: document.genre,
      theme: document.theme,
      protagonist: document.protagonist,
      worldview: document.worldview,
      foreshadows: document.foreshadows,
      charactersJson: document.charactersJson,
      characterCount: document.characterCount,
    );
  }

  /// 按草稿新建一条大纲记录（含小说设定），并按正文解析事件结构写
  /// `outline_chapters`。
  ///
  /// **只新增，不覆盖任何已有数据**；[title] 为空时用草稿里的默认书名。
  /// 结构解析失败不回滚记录（正文比结构重要），错误放在
  /// [OutlineTxtImportResult.structureError] 里由页面提示。
  Future<OutlineTxtImportResult> createNovelFromDraft(
    OutlineTxtImportDraft draft, {
    required String title,
  }) async {
    final cleanTitle = title.trim().isEmpty ? draft.title : title.trim();
    final record = OutlineRecord(
      title: cleanTitle,
      genre: draft.genre,
      theme: draft.theme,
      protagonist: draft.protagonist,
      worldview: draft.worldview,
      content: draft.content,
      foreshadows: draft.foreshadows,
      characters: draft.charactersJson,
    );
    final id = await _records.insert(record.toMap());
    final created = OutlineRecord(
      id: id,
      title: record.title,
      genre: record.genre,
      theme: record.theme,
      protagonist: record.protagonist,
      worldview: record.worldview,
      content: record.content,
      foreshadows: record.foreshadows,
      characters: record.characters,
      createdAt: record.createdAt,
    );
    String? structureError;
    try {
      await reconcileOutlineChapters(outlineId: id, content: draft.content);
    } catch (e, st) {
      debugPrint('[outline_txt] 导入后解析事件结构失败 id=$id：$e\n$st');
      structureError = e.toString();
    }
    return OutlineTxtImportResult(
      record: created,
      eventCount: countOutlineTxtEvents(draft.content),
      structureError: structureError,
    );
  }
}
