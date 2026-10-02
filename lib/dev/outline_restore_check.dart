import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:deepseekapp/core/db/database_helper.dart';
import 'package:deepseekapp/features/novel_writing/shared/data/outline_record_db_helper.dart';
import 'package:deepseekapp/features/novel_writing/shared/outline_event_parser.dart';

/// 大纲被误覆盖后的**只读**诊断 / 找回入口（独立入口，真机跑）。
///
/// 背景：大纲正文是整段写回的，历史上「添加事件时按草稿下标当全局序号」把新增的
/// 大事件插到了整篇大纲的最前面，把大事件1 / 大事件2 顶掉；用户看到的正文与章节表
/// 都可能已经不是原样。这个入口把「还有哪些东西能用来找回」全部摊开：
///
/// - 先**整库复制**一份到外部存储（连 SQLite 的空闲页一起，能 adb pull 出来慢慢查）
/// - 当前正文、**上一版正文备份**（content_backup）、章节行（标题 / 概要 / 正文长度）
/// - 骨架 `skeleton` 里精写后的大事件（生成时的原始标题 + 概要）
/// - 生成进度草稿 `outline_progress.json` 里的前文与检查点文本
///
/// 用法（设备上跑，跑完把导出目录里的文件 pull 出来）：
/// ```
/// flutter run -t lib/dev/outline_restore_check.dart -d <设备> \
///   --dart-define=OUTLINE_KEYWORD=尸兄
/// ```
/// `OUTLINE_KEYWORD` 省略时把每条大纲都列一遍（只列标题与长度）。
///
/// **只读**：唯一的写操作是把库文件复制出去 / 写报告文本，绝不改数据库，
/// 也不碰任何记录。
const String _keyword = String.fromEnvironment('OUTLINE_KEYWORD');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _RestoreCheckApp());
}

class _RestoreCheckApp extends StatelessWidget {
  const _RestoreCheckApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: _RestoreCheckPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _RestoreCheckPage extends StatefulWidget {
  const _RestoreCheckPage();

  @override
  State<_RestoreCheckPage> createState() => _RestoreCheckPageState();
}

class _RestoreCheckPageState extends State<_RestoreCheckPage> {
  final List<String> _lines = [];
  bool _running = false;

  void _log(String line) {
    debugPrint('[restore_check] $line');
    if (mounted) setState(() => _lines.add(line));
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _lines.clear();
    });
    try {
      await _check(_log);
      _log('完成。把导出目录里的文件 pull 出来即可。');
    } catch (e, st) {
      _log('失败：$e');
      debugPrint('$st');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('大纲找回自检（只读）')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _running ? null : _run,
                  child: Text(_running ? '正在检查…' : '开始检查'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _keyword.isEmpty
                        ? '未指定 OUTLINE_KEYWORD：只列标题与长度'
                        : '目标关键词：$_keyword',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SelectableText(
                  _lines[i],
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _check(void Function(String) log) async {
  final db = await DatabaseHelper.database;
  final dir = await _exportDir();
  log('导出目录：${dir.path}');

  // 1) 整库复制：连空闲页一起留档，必要时还能从旧页里翻出被覆盖的正文
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .substring(0, 19);
  final dbFile = File(await DatabaseHelper.databasePath);
  final copy = File(p.join(dir.path, 'deepseek_backup_$stamp.db'));
  if (await dbFile.exists()) {
    await dbFile.copy(copy.path);
    log('整库已备份：${p.basename(copy.path)}（${await copy.length()} 字节）');
  } else {
    log('警告：库文件不存在 ${dbFile.path}');
  }

  // 2) 列出所有大纲（含长度与备份时间）
  final records = await db.rawQuery(
    'SELECT id, title, LENGTH(content) AS n, '
    "SUBSTR(content_backup_at, 1, 19) AS backup_at, "
    'LENGTH(content_backup) AS backup_n, LENGTH(skeleton) AS sk_n '
    'FROM outline_records ORDER BY id DESC',
  );
  log('共 ${records.length} 条大纲');
  for (final r in records) {
    log(
      '  #${r['id']} ${r['title']} · 正文 ${r['n']} 字 · '
      '备份 ${r['backup_n']} 字${(r['backup_at'] as String?)?.isNotEmpty == true ? '（${r['backup_at']}）' : ''} · '
      '骨架 ${r['sk_n']} 字',
    );
  }

  final targets = records.where((r) {
    if (_keyword.isEmpty) return false;
    final title = (r['title'] as String?) ?? '';
    return title.contains(_keyword);
  }).toList();
  if (_keyword.isEmpty) {
    log('提示：加 --dart-define=OUTLINE_KEYWORD=关键词 可导出某条大纲的详细内容');
    return;
  }
  if (targets.isEmpty) {
    log('没有标题包含「$_keyword」的大纲');
    return;
  }

  // 3) 逐条导出细节
  final report = StringBuffer();
  for (final r in targets) {
    final id = (r['id'] as num).toInt();
    final title = (r['title'] as String?) ?? '';
    log('—— 导出 #$id $title ——');
    report
      ..writeln('=' * 70)
      ..writeln('大纲 #$id  $title')
      ..writeln('=' * 70);
    await _dumpOutline(db, id, title, report, log);
  }

  final out = File(p.join(dir.path, 'outline_restore_$stamp.txt'));
  await out.writeAsString(report.toString(), flush: true);
  log('详细报告：${out.path}');
}

Future<void> _dumpOutline(
  Database db,
  int id,
  String title,
  StringBuffer report,
  void Function(String) log,
) async {
  Future<String> column(String name) async {
    final rows = await db.query(
      'outline_records',
      columns: <String>[name],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return (rows.first[name] as String?) ?? '';
  }

  // 当前正文
  final content = await column('content');
  _writeEvents(report, '【当前正文】', content, log);

  // 上一版正文备份
  final backup = await OutlineRecordDbHelper().getContentBackup(id);
  if (backup.content.isEmpty) {
    log('  上一版正文备份：无（这版之前没覆盖过，或备份列为空）');
    report.writeln('\n【上一版正文备份】无');
  } else {
    report.writeln('\n【上一版正文备份】时间 ${backup.savedAt}');
    _writeEvents(report, '上一版正文', backup.content, log);
  }

  // 章节行：标题 / 概要 / 正文长度（正文一个字都没丢的话都在这里）
  final chapters = await db.query(
    'outline_chapters',
    columns: <String>[
      'id',
      'event_index',
      'event_type',
      'event_title',
      'event_summary',
      'LENGTH(content) AS content_n',
      'status',
    ],
    where: 'outline_id = ?',
    whereArgs: <Object?>[id],
    orderBy: 'event_index ASC',
  );
  report.writeln('\n【章节行 outline_chapters】共 ${chapters.length} 行');
  log('  章节行：${chapters.length} 行');
  for (final c in chapters) {
    report.writeln(
      '  #${c['id']} idx=${c['event_index']} ${c['event_type']} '
      '${c['event_title']} | 概要 ${_clip((c['event_summary'] as String?) ?? '')} '
      '| 正文 ${c['content_n']} 字 | ${c['status']}',
    );
  }

  // 骨架里的大事件（生成时的原始标题 + 概要）
  final skeleton = await column('skeleton');
  final skeletonEvents = _skeletonMajorEvents(skeleton);
  report.writeln('\n【骨架 skeleton 里的大事件】共 ${skeletonEvents.length} 条');
  log('  骨架里的大事件：${skeletonEvents.length} 条');
  for (var i = 0; i < skeletonEvents.length; i++) {
    report.writeln('  ${i + 1}. ${skeletonEvents[i]}');
  }

  // 生成进度草稿（可能还留着整份生成文本）
  final draft = await _progressDraft();
  if (draft == null) {
    report.writeln('\n【生成进度草稿 outline_progress.json】无');
  } else {
    report.writeln('\n【生成进度草稿 outline_progress.json】');
    final raw = (draft['rawText'] as String?) ?? '';
    report.writeln('  书名：${draft['title']} · rawText ${raw.length} 字');
    _writeEvents(report, '  草稿 rawText', raw, log);
    final checkpoint = draft['checkpoint'];
    if (checkpoint is Map) {
      final text = (checkpoint['text'] as String?) ?? '';
      final original = (checkpoint['originalText'] as String?) ?? '';
      report
        ..writeln('  检查点 kind=${checkpoint['kind']} edited=${checkpoint['edited']} '
            'fromMinor=${checkpoint['fromMinor']}')
        ..writeln('  --- 检查点文本（${text.length} 字）---')
        ..writeln(text)
        ..writeln('  --- 检查点原始文本（${original.length} 字）---')
        ..writeln(original);
    }
  }
}

/// 把一份大纲正文的事件表写进报告（标题 / 类型 / 概要前 80 字）
void _writeEvents(
  StringBuffer report,
  String label,
  String content,
  void Function(String) log,
) {
  final events = parseOutlineEvents(content, outlineId: 0);
  report.writeln('\n【$label】共 ${events.length} 个事件，${content.length} 字');
  for (final e in events) {
    report.writeln(
      '  ${e.eventIndex}. [${e.isMajor ? '大' : '小'}] ${e.eventTitle}'
      ' | ${_clip(e.eventSummary)}',
    );
  }
  log('  $label：${events.length} 个事件');
}

String _clip(String text, {int max = 80}) {
  final flat = text.replaceAll('\n', ' / ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

/// 解析骨架 JSON 里「精写后的大事件」（act → events[title, summary]）
List<String> _skeletonMajorEvents(String skeleton) {
  if (skeleton.trim().isEmpty) return const [];
  try {
    final data = jsonDecode(skeleton);
    if (data is! Map) return const [];
    final step2 = data['step2'];
    if (step2 is! Map) return const [];
    final acts = step2['acts'];
    if (acts is! List) return const [];
    final out = <String>[];
    for (final act in acts) {
      if (act is! Map) continue;
      final name = (act['act'] as String?) ?? '';
      final events = act['events'];
      if (events is! List) continue;
      for (final e in events) {
        if (e is! Map) continue;
        out.add(
          '$name | ${e['title']} | ${_clip((e['summary'] as String?) ?? '')}',
        );
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 读生成进度草稿（应用文档目录下的 outline_progress.json），没有则 null
Future<Map<String, dynamic>?> _progressDraft() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'outline_progress.json'));
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString());
    return data is Map<String, dynamic> ? data : null;
  } catch (_) {
    return null;
  }
}

/// 导出目录：优先外部存储（adb pull 得到），失败退回应用文档目录
Future<Directory> _exportDir() async {
  Directory base;
  try {
    base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  } catch (_) {
    base = await getApplicationDocumentsDirectory();
  }
  final dir = Directory(p.join(base.path, 'outline_restore'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
