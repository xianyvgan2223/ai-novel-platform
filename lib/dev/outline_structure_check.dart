// 临时真机自检入口（用完即删，不参与正式构建）。
//
// 为什么不用 integration_test：它会引入一个 Android 子工程，构建时要联网拉
// AGP（dl.google.com 在这台机器上超时），走不通。改成 `flutter run -t` 这个
// 独立入口，复用主应用已能正常构建的链路。
//
// 只插入一条标题带 [kMarker] 的测试记录，结束前按主键删掉（outline_chapters
// 有 ON DELETE CASCADE），不碰任何真实数据。
//
// 运行：
//   flutter run -t lib/dev/outline_structure_check.dart -d AQQB9X1526W02408
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/db/database_helper.dart';
import '../features/novel_writing/outline_editing/controller/outline_edit_controller.dart';
import '../features/novel_writing/shared/data/outline_chapter_db_helper.dart';
import '../features/novel_writing/shared/data/outline_record_db_helper.dart';
import '../features/novel_writing/shared/domain/outline_chapter.dart';
import '../features/novel_writing/shared/domain/outline_record.dart';
import '../features/novel_writing/shared/outline_chapter_sync.dart';
import '../features/novel_writing/shared/outline_event_parser.dart';

const String kMarker = '[ITCHK]';

/// `--dart-define=CLEAN_ORPHANS=true`：只清理历史自检留下的孤儿章节行，不跑用例。
/// 孤儿行 = outline_id 在 outline_records 里已经不存在（外键级联失效期间的残留）。
const bool kCleanOrphans =
    bool.fromEnvironment('CLEAN_ORPHANS', defaultValue: false);

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

/// 孤儿章节行数量（outline_id 指向已不存在的记录）
Future<int> _orphanCount() async {
  final db = await DatabaseHelper.database;
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS n FROM outline_chapters '
    'WHERE outline_id NOT IN (SELECT id FROM outline_records)',
  );
  final n = rows.isEmpty ? null : rows.first['n'];
  return n is int ? n : 0;
}

/// 外键约束是否真的开启（验证 PRAGMA foreign_keys = ON 生效）
Future<bool> _foreignKeysOn() async {
  final db = await DatabaseHelper.database;
  final rows = await db.rawQuery('PRAGMA foreign_keys');
  return rows.isNotEmpty && (rows.first.values.first as int? ?? 0) == 1;
}

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    debugPrint('[ITCHK] PASS  $name');
  } else {
    _failed++;
    _failures.add('$name${detail == null ? '' : ' → $detail'}');
    debugPrint('[ITCHK] FAIL  $name${detail == null ? '' : ' → $detail'}');
  }
}

void _eq(String name, Object? got, Object? want) =>
    _check(name, '$got' == '$want', 'got=$got want=$want');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Shell());
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Center(child: Text('自检中…'))));
}

Future<void> _run() async {
  final chapters = OutlineChapterDbHelper();
  final records = OutlineRecordDbHelper();
  final rawContent = [
    '══ 大事件1：甲 $kMarker ══',
    '甲的概要',
    '',
    '○ 小事件1：乙 $kMarker',
    '乙的概要',
    '',
    '══ 大事件2：丙 $kMarker ══',
    '丙的概要',
  ].join('\n');

  // ── 只清孤儿行的模式（清掉历史自检残留，不动任何真实数据）──
  if (kCleanOrphans) {
    final db = await DatabaseHelper.database;
    final before = await _orphanCount();
    debugPrint('[ITCHK] 清理前孤儿章节行：$before');
    final removed = await db.delete(
      'outline_chapters',
      where: 'outline_id NOT IN (SELECT id FROM outline_records)',
    );
    final after = await _orphanCount();
    debugPrint('[ITCHK] 已删除 $removed 行，清理后孤儿章节行：$after');
    debugPrint(
      '[ITCHK] 结果：${after == 0 ? 'PASS 孤儿行已清空' : 'FAIL 仍有残留 $after'}',
    );
    debugPrint('[ITCHK] DONE');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(after == 0 ? 0 : 1);
  }

  int? outlineId;
  try {
    final preCount = (await records.getAllSummaries()).length;
    final fkOn = await _foreignKeysOn();
    final orphanBefore = await _orphanCount();
    debugPrint('[ITCHK] 现有大纲记录 $preCount 条（不会被改动）');
    debugPrint('[ITCHK] PRAGMA foreign_keys = ${fkOn ? 1 : 0}'
        '${fkOn ? '' : '（级联删除不会生效！）'}');
    debugPrint('[ITCHK] 跑用例前的孤儿章节行：$orphanBefore');
    _check('0a 外键约束已开启（级联删除才能生效）', fkOn);

    final id = await records.insert(
      OutlineRecord(title: '$kMarker 增删事件往返', content: rawContent).toMap(),
    );
    outlineId = id;
    await reconcileOutlineChapters(outlineId: id, content: rawContent);

    Future<List<OutlineChapter>> loadRows() async =>
        (await chapters.getByOutlineId(id))
            .map(OutlineChapter.fromMap)
            .toList();

    Future<String> currentText() async =>
        (await records.getById(id))?['content'] as String? ?? '';

    Future<List<String>> textTitles() async => parseOutlineEvents(
      await currentText(),
      outlineId: id,
    ).map((c) => c.eventTitle).toList();

    Future<List<String>> rowTitles() async =>
        (await loadRows()).map((c) => c.eventTitle).toList();

    Future<void> reset() async {
      await records.update(id, {'content': rawContent});
      await reconcileOutlineChapters(outlineId: id, content: rawContent);
    }

    Future<OutlineEditController> build() async {
      final row = await records.getById(id);
      final ctrl = OutlineEditController(OutlineRecord.fromMap(row!));
      ctrl.init(await loadRows());
      // _loadContext 是异步的（读全篇章节 + 读记录），等它跑完
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return ctrl;
    }

    // ── 用例 1：中间插入 + 末尾追加 ──────────────────────────────
    await reset();
    var ctrl = await build();
    ctrl.addEvent(index: 1, isMajor: false, title: '夹心一');
    ctrl.addEvent(index: ctrl.drafts.length, isMajor: true, title: '末尾大事件');
    final saved1 = await ctrl.saveAll();
    _check('1a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    _check('1b 保存条数 > 0', saved1 > 0, '$saved1');

    final rows1 = await loadRows();
    _eq('1c 章节行数', rows1.length, 5);
    var seqOk = true;
    var alignOk = true;
    for (var i = 0; i < rows1.length; i++) {
      if (rows1[i].eventIndex != i + 1) seqOk = false;
      if (rows1[i].eventTitle != ctrl.drafts[i].title) alignOk = false;
      final want = ctrl.drafts[i].isMajor ? 'major' : 'minor';
      if (rows1[i].eventType != want) alignOk = false;
    }
    _check('1d event_index 连续 1..N', seqOk);
    _check('1e 库里的行与页面卡片逐条对齐', alignOk);
    _eq('1f 行标题顺序', rows1.map((c) => c.eventTitle).toList(), [
      '甲 $kMarker',
      '夹心一',
      '乙 $kMarker',
      '丙 $kMarker',
      '末尾大事件',
    ]);
    _eq('1g 插入的小事件类型', rows1[1].eventType, 'minor');
    _eq('1h 末尾大事件类型', rows1[4].eventType, 'major');

    final text1 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    _check(
      '1i 正文的第 N 个事件与卡片逐条对齐',
      text1.length == ctrl.drafts.length &&
          List.generate(
            text1.length,
            (i) => text1[i].eventTitle == ctrl.drafts[i].title,
          ).every((e) => e),
      'text=${text1.map((c) => c.eventTitle).toList()}',
    );
    _eq('1j 原有概要未被打散（甲）', text1[0].eventSummary, '甲的概要');
    _eq('1k 原有概要未被打散（乙）', text1[2].eventSummary, '乙的概要');
    _eq('1l 原有概要未被打散（丙）', text1[3].eventSummary, '丙的概要');
    ctrl.dispose();

    // ── 用例 2：保存后重新进页面（重解析）不翻回、不翻倍 ──────────
    final beforeIds = (await loadRows()).map((c) => c.id).toList();
    final reparse = await reconcileOutlineChapters(
      outlineId: outlineId,
      content: await currentText(),
    );
    debugPrint('[ITCHK] 重解析结果：$reparse');
    _eq('2a 重解析后行数不变', (await loadRows()).length, 5);
    _eq('2b 重解析未新增行', reparse.inserted, 0);
    _eq('2c 重解析后顺序不变', await rowTitles(), [
      '甲 $kMarker',
      '夹心一',
      '乙 $kMarker',
      '丙 $kMarker',
      '末尾大事件',
    ]);
    _eq('2d 行 id 原地保留（正文不丢）', (await loadRows()).map((c) => c.id).toList(), beforeIds);

    // ── 用例 3：新事件的标题与概要一起写进正文与库 ────────────────
    await reset();
    ctrl = await build();
    final newId = ctrl.addEvent(index: 3, isMajor: true, title: '待写概要');
    final draft = ctrl.drafts.firstWhere((d) => d.localId == newId);
    draft.titleCtrl.text = '改过的标题';
    draft.summaryCtrl.text = '第一段概要\n第二段概要';
    await ctrl.saveAll();
    _check('3a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();

    final hit = (await loadRows()).firstWhere((c) => c.eventTitle == '改过的标题');
    _eq('3b 库里概要', hit.eventSummary, '第一段概要\n第二段概要');
    _eq('3c 库里序号', hit.eventIndex, 4);
    final text3 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    final t3 = text3.firstWhere((t) => t.eventTitle == '改过的标题');
    _eq('3d 正文里概要', t3.eventSummary, '第一段概要\n第二段概要');
    _eq('3e 正文里类型', t3.eventType, 'major');

    // ── 用例 4：删除小事件 ──────────────────────────────────────
    await reset();
    ctrl = await build();
    ctrl.deleteEvent(ctrl.drafts[1]);
    await ctrl.saveAll();
    _check('4a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();
    _eq('4b 库里剩下的事件', await rowTitles(), ['甲 $kMarker', '丙 $kMarker']);
    _eq('4c 正文里剩下的事件', await textTitles(), ['甲 $kMarker', '丙 $kMarker']);
    final text4 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    _eq('4d 删除后甲概要仍在', text4[0].eventSummary, '甲的概要');
    _eq('4e 删除后丙概要仍在', text4[1].eventSummary, '丙的概要');

    // ── 用例 5：删除大事件，名下小事件不丢 ───────────────────────
    await reset();
    ctrl = await build();
    ctrl.deleteEvent(ctrl.drafts[0]);
    await ctrl.saveAll();
    _check('5a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();
    _eq('5b 库里剩下的事件', await rowTitles(), ['乙 $kMarker', '丙 $kMarker']);
    final text5 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    _eq('5c 小事件乙的概要仍在它名下', text5[0].eventSummary, '乙的概要');
    _eq('5d 库里乙的概要', (await loadRows())[0].eventSummary, '乙的概要');

    // ── 用例 6：删除后撤销再保存 → 该行绝不能被删 ─────────────────
    await reset();
    ctrl = await build();
    final victimId = (await loadRows())[1].id;
    ctrl.deleteEvent(ctrl.drafts[1]);
    ctrl.undo();
    _eq('6a 撤销后卡片恢复', ctrl.drafts.map((d) => d.title).toList(), [
      '甲 $kMarker',
      '乙 $kMarker',
      '丙 $kMarker',
    ]);
    await ctrl.saveAll();
    _check('6b 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();
    final rows6 = await loadRows();
    _eq('6c 行数', rows6.length, 3);
    _check(
      '6d 撤销回来的行没有被 DELETE',
      rows6.any((c) => c.id == victimId),
      'ids=${rows6.map((c) => c.id).toList()} victim=$victimId',
    );
    _eq('6e 顺序未变', rows6.map((c) => c.eventTitle).toList(), [
      '甲 $kMarker',
      '乙 $kMarker',
      '丙 $kMarker',
    ]);

    // ── 用例 7：带正文的事件删除 → 影响面 + 真的删行 ───────────────
    await reset();
    final minorId = (await loadRows())
        .firstWhere((c) => c.eventTitle == '乙 $kMarker')
        .id!;
    await chapters.updateContent(minorId, '这是已经写好的正文内容。');
    ctrl = await build();
    final target = ctrl.drafts.firstWhere((d) => d.chapterId == minorId);
    final impact = ctrl.deleteImpact(target);
    _check('7a 如实报告已写正文', impact.hasContent);
    _check('7b 正文字数 > 0', impact.contentLength > 0, '${impact.contentLength}');
    ctrl.deleteEvent(target);
    await ctrl.saveAll();
    _check('7c 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();
    final rows7 = await loadRows();
    _eq('7d 行数', rows7.length, 2);
    _check('7e 确认过的删除真的删行', !rows7.any((c) => c.id == minorId));

    // ── 用例 8：新增大事件后大事件序号按全篇重编 ──────────────────
    await reset();
    ctrl = await build();
    _eq('8a 初始甲=大事件1', ctrl.majorNumberOfDraft(ctrl.drafts[0]), 1);
    _eq('8b 初始丙=大事件2', ctrl.majorNumberOfDraft(ctrl.drafts[2]), 2);
    ctrl.addEvent(index: 1, isMajor: true, title: '插入的大事件');
    _eq('8c 插入项=大事件2', ctrl.majorNumberOfDraft(ctrl.drafts[1]), 2);
    _eq('8d 丙顺延=大事件3', ctrl.majorNumberOfDraft(ctrl.drafts[3]), 3);
    await ctrl.saveAll();
    ctrl.dispose();
    final text8 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    _eq('8e 正文顺序', text8.map((c) => c.eventTitle).toList(), [
      '甲 $kMarker',
      '插入的大事件',
      '乙 $kMarker',
      '丙 $kMarker',
    ]);
    _eq('8f 插入项类型', text8[1].eventType, 'major');

    // ── 用例 9：空标题新事件不会写出会消失的断行 ──────────────────
    await reset();
    ctrl = await build();
    ctrl.addEvent(index: 1, isMajor: true); // 不给标题
    await ctrl.saveAll();
    _check('9a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    ctrl.dispose();
    final text9 = parseOutlineEvents(await currentText(), outlineId: outlineId);
    _eq('9b 占位标题落进正文', text9[1].eventTitle, kNewEventTitle);
    _eq('9c 行数不丢', text9.length, 4);
    _eq('9d 库里也是占位标题', (await rowTitles())[1], kNewEventTitle);

    // ── 用例 10：连续增删后再重解析，结构必须稳定 ─────────────────
    await reset();
    ctrl = await build();
    ctrl.addEvent(index: 0, isMajor: true, title: '开头大事件');
    ctrl.addEvent(index: 2, isMajor: false, title: '中段小节');
    ctrl.deleteEvent(ctrl.drafts[3]);
    await ctrl.saveAll();
    _check('10a 保存无错误', ctrl.saveError.isEmpty, ctrl.saveError);
    final want10 = ctrl.drafts.map((d) => d.title).toList();
    ctrl.dispose();
    _eq('10b 落库顺序与卡片一致', await rowTitles(), want10);
    await reconcileOutlineChapters(
      outlineId: outlineId,
      content: await currentText(),
    );
    _eq('10c 重解析后仍是同一份结构', await rowTitles(), want10);
    _eq('10d 重解析后正文一致', await textTitles(), want10);
  } catch (e, st) {
    _failed++;
    _failures.add('未捕获异常：$e');
    debugPrint('[ITCHK] EXCEPTION $e\n$st');
  } finally {
    // 清理：删掉测试记录。外键约束已开启时章节行会随之级联删除；
    // 这里先显式删一遍兜底，并打印级联是否真的生效（之前这一步留下了 24 行孤儿）。
    if (outlineId case final id?) {
      final orphanBefore = await _orphanCount();
      await records.delete(id);
      final cascaded = await chapters.getByOutlineId(id);
      if (cascaded.isEmpty) {
        debugPrint('[ITCHK] 级联删除生效：章节行已随记录一起删除');
      } else {
        debugPrint(
          '[ITCHK] 级联删除**未生效**，残留 ${cascaded.length} 行，显式清理',
        );
        await chapters.deleteByOutlineId(id);
      }
      final left = await (await DatabaseHelper.database).query(
        'outline_records',
        where: 'title LIKE ?',
        whereArgs: ['$kMarker%'],
      );
      final leftChapters = await (await DatabaseHelper.database).query(
        'outline_chapters',
        where: 'outline_id = ?',
        whereArgs: [id],
      );
      final orphanAfter = await _orphanCount();
      debugPrint(
        '[ITCHK] 清理完成：残留记录 ${left.length} 条 / 残留章节 '
        '${leftChapters.length} 条 / 孤儿章节 $orphanBefore→$orphanAfter',
      );
      _check(
        '0b 测试数据清理干净（不留孤儿行）',
        left.isEmpty && leftChapters.isEmpty && orphanAfter <= orphanBefore,
        'records=${left.length} chapters=${leftChapters.length} '
            'orphan=$orphanBefore→$orphanAfter',
      );
    }
    debugPrint('[ITCHK] ================ 结果 ================');
    debugPrint('[ITCHK] 通过 $_passed / 失败 $_failed');
    for (final f in _failures) {
      debugPrint('[ITCHK]   ✗ $f');
    }
    debugPrint('[ITCHK] DONE');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(_failed == 0 ? 0 : 1);
  }
}
