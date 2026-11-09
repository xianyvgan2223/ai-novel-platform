import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_generation/controller/outline_controller.dart';

/// 伏笔只保留「未回收的短线伏笔」：
/// - 已回收 / 已实现的伏笔不再注入后续批次与展开块；
/// - 跨过 5 个大事件仍未回收的伏笔自动从账本里去掉。
void main() {
  OutlineController controller() => OutlineController();

  test('已回收 / 已实现的伏笔不进入账本、不注入', () {
    final c = controller();
    c.debugMergeLedgerForTest([
      {'content': '旧铁条的来历', 'status': '已埋', 'plan': '第二幕'},
      {'content': '欠着的那句话', 'status': '已回收', 'plan': '第二幕'},
      {'content': '续尽则断', 'status': '已实现', 'plan': '第三幕'},
    ], currentMajorIndex: 1);

    final kept = c.debugLedgerForeshadowsForTest;
    expect(kept.length, 1);
    expect(kept.single['content'], '旧铁条的来历');
    expect(c.debugLedgerTextForTest, contains('旧铁条的来历'));
    expect(c.debugLedgerTextForTest, isNot(contains('欠着的那句话')));
    expect(c.debugLedgerTextForTest, isNot(contains('续尽则断')));
    // 落库清单同样不带已实现的伏笔
    expect(c.debugRecordForeshadowsForTest, contains('旧铁条的来历'));
    expect(c.debugRecordForeshadowsForTest, isNot(contains('欠着的那句话')));
  });

  test('同一条伏笔后续被标记已回收时，从账本中删除', () {
    final c = controller();
    c.debugMergeLedgerForTest([
      {'content': '旧铁条', 'status': '已埋', 'plan': '第二幕'},
    ], currentMajorIndex: 2);
    c.debugMergeLedgerForTest([
      {'content': '旧铁条', 'status': '已回收', 'plan': '第二幕'},
    ], currentMajorIndex: 3);

    expect(c.debugLedgerForeshadowsForTest, isEmpty);
    expect(c.debugLedgerTextForTest, '（暂无）');
  });

  test('跨 5 个大事件仍未回收：自动去掉；4 个事件内保留', () {
    final c = controller();
    c.debugMergeLedgerForTest([
      {'content': '没回收的伏笔', 'status': '已埋', 'plan': '第二幕'},
    ], currentMajorIndex: 1);
    // 第 5 个大事件（年龄 4）仍在
    c.debugMergeLedgerForTest(const [], currentMajorIndex: 5);
    expect(c.debugLedgerTextForTest, contains('没回收的伏笔'));
    // 第 6 个大事件（跨过 5 个）自动去掉
    c.debugMergeLedgerForTest(const [], currentMajorIndex: 6);
    expect(c.debugLedgerForeshadowsForTest, isEmpty);
    expect(c.debugLedgerTextForTest, '（暂无）');
  });

  test('同一条伏笔反复出现时年龄从首次埋设算起，不因重新列出而续命', () {
    final c = controller();
    c.debugMergeLedgerForTest([
      {'content': '反复出现的伏笔', 'status': '已埋', 'plan': '第三幕'},
    ], currentMajorIndex: 1);
    c.debugMergeLedgerForTest([
      {'content': '反复出现的伏笔', 'status': '已埋', 'plan': '第三幕'},
    ], currentMajorIndex: 4);
    expect(c.debugLedgerForeshadowsForTest.first['plantedAt'], 1);

    c.debugMergeLedgerForTest([
      {'content': '反复出现的伏笔', 'status': '已埋', 'plan': '第三幕'},
    ], currentMajorIndex: 6);
    expect(c.debugLedgerForeshadowsForTest, isEmpty);
  });

  test('最新一批重新列出的新伏笔按当前进度起算年龄', () {
    final c = controller();
    c.debugMergeLedgerForTest([
      {'content': '新伏笔', 'status': '已埋', 'plan': '第三幕'},
    ], currentMajorIndex: 8);
    expect(c.debugLedgerForeshadowsForTest.first['plantedAt'], 8);
    expect(c.debugLedgerTextForTest, contains('新伏笔'));
  });
}
