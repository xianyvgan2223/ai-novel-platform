import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/novel_writing/outline_listening/background/outline_listening_notification.dart';

/// 「听大纲」后台朗读通知的纯 Dart 层测试（不触碰 Android 原生通道）。
///
/// 分两层：
/// 1. 通知文案工厂（[OutlineListeningNotificationContent]）是纯数据，直接断言
///    「播放中 / 暂停 / 听完」的标题、正文、副文本与进度规则；
/// 2. 通知桥（[OutlineListeningNotification]）的节流 / 去重 / 立即发送行为，
///    用 `debugInvokeOverride` 记录「发往原生」的调用，用 widget 测试的假时钟
///    推进 500ms 窗口，不需要真的 MethodChannel。
///
/// 进度条语义（V4.10 起）：通知栏取**事件内句子进度**（第 n/N 句 → n/N），
/// 不再是整篇事件进度——长篇大纲里整篇百分比几十分钟不动，通知看起来像没进度；
/// 句子级每读一句就前进一格。事件序号 / 总事件数仍写在正文里，整体位置不丢。
///
/// 为什么这些行为要测：朗读时句子推进很快（4 倍速下每句可能不到一秒），通知
/// 若每句都刷一次 IPC 会明显卡顿；但 start / finish / cancel 又必须立即发出，
/// 否则用户退后台看到的仍是上一状态。
void main() {
  group('通知文案 · 播放中', () {
    test('标题带书名，正文写「第几个事件 · 事件类型 · 第几句」', () {
      final content = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 2,
        eventTotal: 5,
        sentenceOrdinal: 3,
        sentenceTotal: 8,
        sentence: '李云飞走进青阳城。',
      );

      expect(content.kind, ListenNotificationKind.playing);
      expect(content.title, '正在听大纲：《测试书》');
      expect(content.content, '第2/5个事件 · 大事件1 · 第3/8句');
      expect(content.subText, '李云飞走进青阳城。');
      // 事件内句子进度：3/8 → 37.5% → 38
      expect(content.progress, 38);
      // 媒体通知 seekbar 用的句序号 / 总句数（原生按 1 句 = 1000ms 映射）
      expect(content.sentenceOrdinal, 3);
      expect(content.sentenceTotal, 8);
      expect(content.success, isTrue);
    });

    test('书名自带《》时不重复包一层（避免《《尸兄》》）', () {
      final content = OutlineListeningNotificationContent.playing(
        bookTitle: '《尸兄》',
        eventLabel: '小事件2',
        eventOrdinal: 1,
        eventTotal: 3,
        sentenceOrdinal: 1,
        sentenceTotal: 2,
        sentence: '开场。',
      );

      expect(content.title, '正在听大纲：《尸兄》');
      expect(content.title, isNot(contains('《《')));
      expect(content.progress, 50);
    });

    test('空书名 / 空句子都有兜底文案', () {
      final content = OutlineListeningNotificationContent.playing(
        bookTitle: '   ',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 1,
        sentenceOrdinal: 1,
        sentenceTotal: 3,
        sentence: '   ',
      );

      expect(content.title, '正在听大纲');
      expect(content.subText, '点按回到朗读页');
      expect(content.progress, 33);
    });

    test('句数为 0 时不写「第 x/0 句」，进度也为 0', () {
      final content = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 2,
        eventTotal: 5,
        sentenceOrdinal: 0,
        sentenceTotal: 0,
        sentence: '',
      );

      expect(content.content, '第2/5个事件 · 大事件1');
      expect(content.content, isNot(contains('句')));
      expect(content.progress, 0);
      // 没有句信息：原生媒体通知据此不提供可拖动 seekbar
      expect(content.sentenceOrdinal, 0);
      expect(content.sentenceTotal, 0);
    });

    test('副文本长句截断到 40 字加省略号，并把换行压成空格', () {
      final long = '${'甲' * 60}\n${'乙' * 10}';
      final content = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 1,
        sentenceOrdinal: 1,
        sentenceTotal: 1,
        sentence: '  第一行\n第二行 ${'丙' * 50}  ',
      );

      expect(content.subText.endsWith('…'), isTrue);
      expect(content.subText.length, 41); // 40 字 + 省略号
      expect(content.subText, isNot(contains('\n')));
      // 长句用普通句子的截断规则也一样
      final longContent = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 1,
        sentenceOrdinal: 1,
        sentenceTotal: 1,
        sentence: long,
      );
      expect(longContent.subText.length, 41);
    });

    test('通知进度 = 事件内句子进度（第 1/14 句 → 7；最后一句 → 100；句数 0 → 0）', () {
      OutlineListeningNotificationContent at({
        required int ordinal,
        required int total,
      }) =>
          OutlineListeningNotificationContent.playing(
            bookTitle: '测试书',
            eventLabel: '大事件1',
            eventOrdinal: 1,
            eventTotal: 2,
            sentenceOrdinal: ordinal,
            sentenceTotal: total,
            sentence: '句子。',
          );

      expect(at(ordinal: 1, total: 14).progress, 7);
      expect(at(ordinal: 2, total: 14).progress, 14);
      expect(at(ordinal: 7, total: 14).progress, 50);
      expect(at(ordinal: 13, total: 14).progress, 93);
      expect(at(ordinal: 14, total: 14).progress, 100);
      expect(at(ordinal: 0, total: 0).progress, 0);
      // 第 1/1000 句四舍五入是 0：进度条不能整条空白，至少给 1
      expect(at(ordinal: 1, total: 1000).progress, 1);
      // 句数 > 0 但当前句序号是 0（事件刚读完 / 还没定到句）时同样保底 1
      expect(at(ordinal: 0, total: 14).progress, 1);
    });
  });

  group('通知文案 · 已暂停', () {
    test('标题 / 正文写「停在第几个事件第几句」，副文本带当前句', () {
      final content = OutlineListeningNotificationContent.paused(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 2,
        eventTotal: 5,
        sentenceOrdinal: 3,
        sentenceTotal: 8,
        sentence: '李云飞走进青阳城。',
      );

      expect(content.kind, ListenNotificationKind.paused);
      expect(content.title, '《测试书》听大纲已暂停');
      expect(content.content, '停在第2/5个事件 · 大事件1（第3/8句）');
      expect(content.subText, '当前句：李云飞走进青阳城。');
      // 与播放中同一套句子进度规则：3/8 → 38
      expect(content.progress, 38);
      // 暂停态也带句序号 / 总句数：媒体通知 seekbar 要能显示并拖动到暂停位置
      expect(content.sentenceOrdinal, 3);
      expect(content.sentenceTotal, 8);
    });

    test('空书名兜底；没有当前句时提示点回页面继续，进度同样按句子算', () {
      final content = OutlineListeningNotificationContent.paused(
        bookTitle: '',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 1,
        sentenceOrdinal: 0,
        sentenceTotal: 0,
        sentence: '',
      );

      expect(content.title, '听大纲已暂停');
      expect(content.content, '停在第1/1个事件 · 大事件1');
      expect(content.subText, '点按回到朗读页继续');
      expect(content.progress, 0);

      // 句数 > 0 时暂停进度与播放中同规则
      final pausedMid = OutlineListeningNotificationContent.paused(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 2,
        sentenceOrdinal: 14,
        sentenceTotal: 14,
        sentence: '最后一句。',
      );
      expect(pausedMid.progress, 100);
    });

    test('有错误原因时副文本显示原因（优先于当前句），长原因截断', () {
      const reason =
          '本机语音引擎缺少中文语音数据，请到系统设置里下载中文语音包后再试一次，然后回到 App 点重试';
      final content = OutlineListeningNotificationContent.paused(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 2,
        sentenceOrdinal: 1,
        sentenceTotal: 3,
        sentence: '正在读的句子。',
        errorMessage: reason,
      );

      expect(content.subText, startsWith('本机语音引擎缺少中文语音数据'));
      expect(content.subText.length, 41);
      expect(content.subText, endsWith('…'));
      expect(content.subText, isNot(contains('正在读的句子')));

      // 空白错误原因不算「有原因」：退回当前句
      final blank = OutlineListeningNotificationContent.paused(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 2,
        sentenceOrdinal: 1,
        sentenceTotal: 3,
        sentence: '正在读的句子。',
        errorMessage: '   ',
      );
      expect(blank.subText, '当前句：正在读的句子。');
    });
  });

  group('通知文案 · 听完', () {
    test('成功听完：标题写「已听完」，正文带事件数，进度 100', () {
      final content = OutlineListeningNotificationContent.finished(
        bookTitle: '测试书',
        eventCount: 5,
      );

      expect(content.kind, ListenNotificationKind.finished);
      expect(content.title, '《测试书》大纲已听完');
      expect(content.content, '共 5 个事件 · 点击回到朗读页');
      expect(content.subText, '点按查看朗读页');
      expect(content.progress, 100);
      // 终态没有「当前句」：句序号 / 总句数为 0（原生不再给 seekbar）
      expect(content.sentenceOrdinal, 0);
      expect(content.sentenceTotal, 0);
      expect(content.success, isTrue);
    });

    test('空书名兜底；中断态副文本说明「朗读中断」', () {
      final content = OutlineListeningNotificationContent.finished(
        bookTitle: '  ',
        eventCount: 1,
        success: false,
      );

      expect(content.title, '听大纲已读完');
      expect(content.success, isFalse);
      expect(content.subText, '朗读中断，点按回到朗读页');
      expect(content.progress, 100);
    });
  });

  group('通知内容 · 相等性 / 去重含句进度字段', () {
    /// 直接构造内容（绕开工厂），只让句序号 / 总句数变化，progress 与文案保持一致，
    /// 这样能单独验「媒体 seekbar 位置变化算不算不同内容」。
    OutlineListeningNotificationContent raw({
      required int ordinal,
      required int total,
    }) =>
        OutlineListeningNotificationContent(
          kind: ListenNotificationKind.playing,
          title: '正在听大纲：《测试书》',
          content: '第1/2个事件 · 大事件1',
          subText: '当前句',
          progress: 50,
          sentenceOrdinal: ordinal,
          sentenceTotal: total,
        );

    test('只有句序号 / 总句数不同也算不同内容（seekbar 位置要能刷新）', () {
      expect(raw(ordinal: 1, total: 2) == raw(ordinal: 1, total: 2), isTrue);
      expect(raw(ordinal: 2, total: 2) == raw(ordinal: 1, total: 2), isFalse);
      expect(raw(ordinal: 1, total: 4) == raw(ordinal: 1, total: 2), isFalse);
    });

    testWidgets('去重：仅 seekbar 位置变化的内容仍会 update；完全相同不重发', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(raw(ordinal: 1, total: 2));
      // progress / 标题 / 正文全都一样，只有句序号与总句数变了
      notification.update(raw(ordinal: 2, total: 4));
      await tester.pump(const Duration(milliseconds: 600));

      expect(recorder.methods, ['start', 'update']);
      expect(recorder.calls.last.$2!['sentenceOrdinal'], 2);
      expect(recorder.calls.last.$2!['sentenceTotal'], 4);

      // 完全相同的内容仍然不重发
      notification.update(raw(ordinal: 2, total: 4));
      await tester.pump(const Duration(milliseconds: 600));
      expect(recorder.methods, ['start', 'update']);
    });
  });

  group('通知桥 · 节流 / 去重 / 立即发送', () {
    /// 用 `ordinal/100` 当句子进度：参数就是「发往原生的 progress」，
    /// 既方便断言，也能让不同调用生成不同内容（去重用例靠内容区分）。
    OutlineListeningNotificationContent playing(String sentence, int ordinal) =>
        OutlineListeningNotificationContent.playing(
          bookTitle: '测试书',
          eventLabel: '大事件1',
          eventOrdinal: 1,
          eventTotal: 2,
          sentenceOrdinal: ordinal,
          sentenceTotal: 100,
          sentence: sentence,
        );

    OutlineListeningNotificationContent paused(String sentence) =>
        OutlineListeningNotificationContent.paused(
          bookTitle: '测试书',
          eventLabel: '大事件1',
          eventOrdinal: 1,
          eventTotal: 2,
          sentenceOrdinal: 1,
          sentenceTotal: 3,
          sentence: sentence,
        );

    testWidgets('start 立即发出，不进入节流窗口', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('第一句', 5));

      expect(recorder.methods, ['start']);
      final args = recorder.calls.single.$2!;
      expect(args['title'], contains('测试书'));
      expect(args['content'], contains('第1/2个事件'));
      expect(args['subText'], '第一句');
      expect(args['progress'], 5);
      expect(args['paused'], isFalse);
      // _contentArgs 必须把媒体 seekbar 的位置一起发给原生
      expect(args['sentenceOrdinal'], 5);
      expect(args['sentenceTotal'], 100);
    });

    testWidgets('start / update 参数带句序号、总句数，progress 与句进度一致', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      final first = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 2,
        sentenceOrdinal: 3,
        sentenceTotal: 14,
        sentence: '第三句。',
      );
      await notification.start(first);

      var args = recorder.calls.single.$2!;
      expect(args['sentenceOrdinal'], 3);
      expect(args['sentenceTotal'], 14);
      expect(args['progress'], first.progress, reason: 'progress 与句进度一致');
      expect(args['progress'], (3 / 14 * 100).round());

      final second = OutlineListeningNotificationContent.playing(
        bookTitle: '测试书',
        eventLabel: '大事件1',
        eventOrdinal: 1,
        eventTotal: 2,
        sentenceOrdinal: 14,
        sentenceTotal: 14,
        sentence: '最后一句。',
      );
      notification.update(second);
      await tester.pump(const Duration(milliseconds: 600));

      expect(recorder.methods, ['start', 'update']);
      args = recorder.calls.last.$2!;
      expect(args['sentenceOrdinal'], 14);
      expect(args['sentenceTotal'], 14);
      expect(args['progress'], 100);
    });

    testWidgets('500ms 内连续 update 只发一次，且发的是最后那份内容', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('启动', 1));
      notification.update(playing('第二句', 10));
      notification.update(playing('第三句', 20));
      notification.update(playing('第四句', 30));

      // 窗口内先攒着，不逐句刷 IPC
      expect(recorder.methods, ['start']);

      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.methods, ['start'], reason: '500ms 窗口内不应发出 update');

      await tester.pump(const Duration(milliseconds: 600));
      expect(recorder.methods, ['start', 'update'], reason: '窗口结束后只补发一次');
      expect(
        recorder.calls.last.$2!['subText'],
        '第四句',
        reason: '被合并的中间进度要丢掉，只发最新内容',
      );
      expect(recorder.calls.last.$2!['content'], contains('第1/2个事件'));
      expect(recorder.calls.last.$2!['progress'], 30);

      // 定时器只触发一次，不会重复补发
      await tester.pump(const Duration(seconds: 2));
      expect(recorder.methods.length, 2);
    });

    testWidgets('相同内容去重：与已发 / 待发内容相同都不重复发', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      final same = playing('同一句', 50);
      await notification.start(same);
      // 与刚 start 的内容相同 → 完全不入队
      notification.update(same);
      await tester.pump(const Duration(milliseconds: 600));
      expect(recorder.methods, ['start']);

      // 内容变化才发一次；同一内容排队两次也只发一次
      final changed = playing('新一句', 60);
      notification.update(changed);
      notification.update(changed);
      await tester.pump(const Duration(milliseconds: 600));
      expect(recorder.methods, ['start', 'update']);
      expect(recorder.calls.last.$2!['subText'], '新一句');

      // 已经发出去的内容再次 update，仍然不重发
      notification.update(changed);
      await tester.pump(const Duration(milliseconds: 600));
      expect(recorder.methods, ['start', 'update']);
    });

    testWidgets('finish 立即发出，并丢弃尚未发出的 pending update', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('启动', 5));
      notification.update(playing('待发进度', 40)); // 进了节流窗口
      await notification.finish(
        OutlineListeningNotificationContent.finished(
          bookTitle: '测试书',
          eventCount: 2,
        ),
        success: true,
      );

      expect(recorder.methods, ['start', 'finish']);
      expect(recorder.calls.last.$2!['success'], isTrue);
      expect(recorder.calls.last.$2!, isNot(contains('subText')));

      // 终态之后，之前攒的进度 update 不能再冒出来覆盖它
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.methods, ['start', 'finish']);
    });

    testWidgets('cancel 立即发出，并清掉 pending update', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('启动', 5));
      notification.update(playing('待发进度', 40));
      await notification.cancel();

      expect(recorder.methods, ['start', 'cancel']);
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.methods, ['start', 'cancel']);
    });

    testWidgets('暂停态在参数里用 paused: true 标记（原生据此去掉进度动画）', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('播放中', 10));
      await tester.pump(const Duration(milliseconds: 600));
      notification.update(paused('暂停了'));
      await tester.pump(const Duration(milliseconds: 600));

      expect(recorder.calls.last.$2!['paused'], isTrue);
      // 暂停时进度仍是句子进度（1/3 → 33），不是整篇百分比
      expect(recorder.calls.last.$2!['progress'], 33);
      // 暂停态也要把 seekbar 位置（句序号 / 总句数）带给原生
      expect(recorder.calls.last.$2!['sentenceOrdinal'], 1);
      expect(recorder.calls.last.$2!['sentenceTotal'], 3);
    });

    testWidgets('非 Android / 原生不可用：全部 no-op，不触碰通道', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final recorder = _InvokeRecorder();
      final notification = OutlineListeningNotification(
        supported: false,
        debugInvokeOverride: recorder.handle,
      );

      await notification.start(playing('启动', 5));
      notification.update(playing('进度', 10));
      await notification.finish(
        OutlineListeningNotificationContent.finished(
          bookTitle: '测试书',
          eventCount: 2,
        ),
        success: true,
      );
      await notification.cancel();

      expect(notification.supported, isFalse);
      expect(recorder.calls, isEmpty);
    });
  });

  group('通知桥 · 权限 / 冷启动点击', () {
    test('supported 时把两个查询转给原生并按返回值回答', () async {
      final recorder = _InvokeRecorder(answer: (_) => true);
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      expect(await notification.ensurePermission(), isTrue);
      expect(await notification.consumeLaunchTap(), isTrue);
      expect(recorder.methods, [
        'ensureNotificationPermission',
        'consumeLaunchTap',
      ]);
    });

    test('原生说没有 / 不支持时返回 false', () async {
      final recorder = _InvokeRecorder(answer: (_) => false);
      final notification = OutlineListeningNotification(
        supported: true,
        debugInvokeOverride: recorder.handle,
      );

      expect(await notification.ensurePermission(), isFalse);
      expect(await notification.consumeLaunchTap(), isFalse);
    });

    test('非 Android 时两个查询直接 false，不碰通道', () async {
      final recorder = _InvokeRecorder(answer: (_) => true);
      final notification = OutlineListeningNotification(
        supported: false,
        debugInvokeOverride: recorder.handle,
      );

      expect(await notification.ensurePermission(), isFalse);
      expect(await notification.consumeLaunchTap(), isFalse);
      expect(recorder.calls, isEmpty);
    });
  });
}

/// 记录「发往原生」的方法名与参数，替代真实 MethodChannel。
class _InvokeRecorder {
  _InvokeRecorder({this.answer});

  /// 自定义返回值（默认 null，与「原生什么都没回」一致）
  final Object? Function(String method)? answer;

  final List<(String, Map<String, dynamic>?)> calls = [];

  Future<Object?> handle(String method, Map<String, dynamic>? args) async {
    calls.add((method, args));
    return answer?.call(method);
  }

  List<String> get methods => [for (final call in calls) call.$1];
}
