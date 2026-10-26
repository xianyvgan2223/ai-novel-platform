/// 「听大纲」后台朗读通知 —— Dart 侧与 Android 原生通道的桥接。
///
/// 朗读音频由系统 TTS / App 内置离线语音在原生侧播放，本类只负责两件事：
/// 1. 把「正在读第几个事件、第几句、整篇进度」写进通知栏（前台服务保活，
///    退后台 / 锁屏也继续读）；
/// 2. 把通知上的操作（上一个 / 暂停继续 / 停止）与点击事件回传给 Dart，
///    点击通知由 app 层导航回「听大纲改名」页面。
///
/// 设计约束与「一键生成大纲」的后台通知一致：
/// - 只支持 Android；桌面 / Web / 单元测试环境全部静默降级为 no-op；
/// - 所有原生调用自己吞异常，通知只是辅助能力，不能反过来影响朗读；
/// - 更新节流 500ms：句子推进可能很快（尤其 4 倍速），没必要每句都刷系统通知。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知展示的内容快照（纯数据、不依赖原生，便于单测）。
enum ListenNotificationKind { playing, paused, finished }

/// 一条「听大纲」通知显示什么：播放中 / 已暂停 / 听完。
class OutlineListeningNotificationContent {
  final ListenNotificationKind kind;
  final String title;
  final String content;
  final String subText;

  /// 0~100，通知栏进度条（当前事件内句子进度）
  final int progress;

  /// 当前事件内第几句（1 起；0 = 没有句信息）
  ///
  /// 原生媒体通知用「句序号 / 总句数」映射出可拖动的 seekbar 位置：
  /// 1 句 = 1000ms 的虚拟时间轴，拖动松手后把进度回传给 Dart 换成第几句。
  final int sentenceOrdinal;

  /// 当前事件总句数（0 = 没有句信息，媒体通知不提供拖动）
  final int sentenceTotal;

  /// 仅 [ListenNotificationKind.finished] 有意义
  final bool success;

  const OutlineListeningNotificationContent({
    required this.kind,
    required this.title,
    required this.content,
    required this.subText,
    required this.progress,
    this.sentenceOrdinal = 0,
    this.sentenceTotal = 0,
    this.success = true,
  });

  /// 书名统一包装：标题记录里有的书名自带《》（历史大纲常见），
  /// 再包一层就会出现「《《尸兄》》」，这里两种写法都兼容。
  static String _bookLabel(String title) {
    final t = title.trim();
    if (t.isEmpty) return '大纲';
    if (t.startsWith('《') && t.endsWith('》')) return t;
    return '《$t》';
  }

  /// 通知进度条取「事件内句子进度」：
  ///
  /// 为什么不取全书进度——一本长篇大纲动辄几十上百个事件，全书百分比在一整个
  /// 事件（可能几分钟）里几乎不动，通知栏看起来就是「没有进度条」；而句子级
  /// 进度每读一句就前进一格，用户一眼能看出「正在读、读到哪」。
  /// 事件序号 / 总事件数已经写在正文里，不丢整体位置信息。
  static int _sentenceProgress(int sentenceOrdinal, int sentenceTotal) {
    if (sentenceTotal <= 0) return 0;
    final pct = (sentenceOrdinal / sentenceTotal * 100).round();
    // 正在读的时候至少给 1%：第 1/几十句时进度条不能整条空白
    return pct.clamp(1, 100);
  }

  /// 播放中：标题带书名，正文是「第几个事件 + 事件类型 + 第几句」，
  /// 副文本显示当前正在读的句子（通知下拉展开可见）。
  factory OutlineListeningNotificationContent.playing({
    required String bookTitle,
    required String eventLabel,
    required int eventOrdinal,
    required int eventTotal,
    required int sentenceOrdinal,
    required int sentenceTotal,
    required String sentence,
  }) {
    final title = bookTitle.trim();
    final text = _truncate(sentence.replaceAll(RegExp(r'\s+'), ' ').trim(), 40);
    return OutlineListeningNotificationContent(
      kind: ListenNotificationKind.playing,
      title: title.isEmpty
          ? '正在听大纲'
          : '正在听大纲：${_bookLabel(title)}',
      content: '第$eventOrdinal/$eventTotal个事件 · $eventLabel'
          '${sentenceTotal > 0 ? ' · 第$sentenceOrdinal/$sentenceTotal句' : ''}',
      subText: text.isEmpty ? '点按回到朗读页' : text,
      progress: _sentenceProgress(sentenceOrdinal, sentenceTotal),
      sentenceOrdinal: sentenceOrdinal,
      sentenceTotal: sentenceTotal,
    );
  }

  /// 已暂停：位置保留，点通知回页面可继续。
  factory OutlineListeningNotificationContent.paused({
    required String bookTitle,
    required String eventLabel,
    required int eventOrdinal,
    required int eventTotal,
    required int sentenceOrdinal,
    required int sentenceTotal,
    required String sentence,
    String? errorMessage,
  }) {
    final title = bookTitle.trim();
    final text = _truncate(sentence.replaceAll(RegExp(r'\s+'), ' ').trim(), 40);
    final error = errorMessage?.trim() ?? '';
    return OutlineListeningNotificationContent(
      kind: ListenNotificationKind.paused,
      title: title.isEmpty
          ? '听大纲已暂停'
          : '${_bookLabel(title)}听大纲已暂停',
      content: '停在第$eventOrdinal/$eventTotal个事件 · $eventLabel'
          '${sentenceTotal > 0 ? '（第$sentenceOrdinal/$sentenceTotal句）' : ''}',
      subText: error.isNotEmpty
          ? _truncate(error, 40)
          : (text.isEmpty ? '点按回到朗读页继续' : '当前句：$text'),
      progress: _sentenceProgress(sentenceOrdinal, sentenceTotal),
      sentenceOrdinal: sentenceOrdinal,
      sentenceTotal: sentenceTotal,
    );
  }

  /// 整篇读完：非 ongoing 的提醒，点通知回到朗读页。
  factory OutlineListeningNotificationContent.finished({
    required String bookTitle,
    required int eventCount,
    bool success = true,
  }) {
    final title = bookTitle.trim();
    return OutlineListeningNotificationContent(
      kind: ListenNotificationKind.finished,
      title: title.isEmpty ? '听大纲已读完' : '${_bookLabel(title)}大纲已听完',
      content: '共 $eventCount 个事件 · 点击回到朗读页',
      subText: success ? '点按查看朗读页' : '朗读中断，点按回到朗读页',
      progress: 100,
      success: success,
    );
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  @override
  bool operator ==(Object other) =>
      other is OutlineListeningNotificationContent &&
      other.kind == kind &&
      other.title == title &&
      other.content == content &&
      other.subText == subText &&
      other.progress == progress &&
      other.sentenceOrdinal == sentenceOrdinal &&
      other.sentenceTotal == sentenceTotal &&
      other.success == success;

  @override
  int get hashCode => Object.hash(
    kind,
    title,
    content,
    subText,
    progress,
    sentenceOrdinal,
    sentenceTotal,
    success,
  );

  @override
  String toString() =>
      'OutlineListeningNotificationContent(${kind.name}, $progress%, '
      '$title | $content | $subText)';
}

/// 与 Android 原生通道通信的单例。
///
/// 方法/事件通道名与 `OutlineListeningChannel.kt`、`OutlineListenService.kt`
/// 一一对应，改名时两边必须同步。
class OutlineListeningNotification {
  OutlineListeningNotification({
    bool? supported,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this.debugInvokeOverride,
  }) : _supported = supported ?? _defaultSupported,
       _methodChannel = methodChannel ?? const MethodChannel(_kMethodChannel),
       _eventChannel = eventChannel ?? const EventChannel(_kEventChannel);

  static const String _kMethodChannel = 'deepseek_app/outline_listening';
  static const String _kEventChannel = 'deepseek_app/outline_listening/events';

  static final OutlineListeningNotification instance =
      OutlineListeningNotification();

  static bool get _defaultSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const Duration _minUpdateInterval = Duration(milliseconds: 500);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  /// 单元测试注入：替代真实 [MethodChannel.invokeMethod]（不触碰原生）。
  @visibleForTesting
  final Future<Object?> Function(String method, Map<String, dynamic>? args)?
  debugInvokeOverride;

  final bool _supported;
  bool _disabledByError = false;

  StreamController<void>? _tapController;
  StreamController<String>? _actionController;
  StreamController<double>? _seekController;
  StreamSubscription<dynamic>? _eventSubscription;

  OutlineListeningNotificationContent? _pendingContent;
  OutlineListeningNotificationContent? _lastSentContent;
  Timer? _updateTimer;
  DateTime _lastUpdateAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get supported => _supported && !_disabledByError;

  Future<bool> ensurePermission() async {
    if (!supported) return false;
    try {
      final result = await _invokeRaw('ensureNotificationPermission', null);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// 开始一条朗读通知：立即发出（不节流），原生侧会拉起前台服务。
  Future<void> start(OutlineListeningNotificationContent content) async {
    if (!supported) return;
    _cancelPendingUpdate();
    _lastSentContent = content;
    _lastUpdateAt = DateTime.now();
    await _invoke('start', _contentArgs(content));
  }

  /// 更新通知：节流到最多 500ms 一次，只保留最新内容。
  void update(OutlineListeningNotificationContent content) {
    if (!supported) return;
    if (content == _lastSentContent || content == _pendingContent) return;
    _pendingContent = content;
    if (_updateTimer != null) return;
    final elapsed = DateTime.now().difference(_lastUpdateAt);
    if (elapsed >= _minUpdateInterval) {
      _flushPendingUpdate();
      return;
    }
    _updateTimer = Timer(_minUpdateInterval - elapsed, () {
      _updateTimer = null;
      _flushPendingUpdate();
    });
  }

  /// 朗读结束（听完 / 中断）：切到最终态，可点击、可划掉，并停掉前台服务。
  Future<void> finish(
    OutlineListeningNotificationContent content, {
    required bool success,
  }) async {
    if (!supported) return;
    _cancelPendingUpdate();
    _lastSentContent = content;
    await _invoke('finish', {
      'title': content.title,
      'content': content.content,
      'success': success,
    });
  }

  /// 停止朗读 / 丢弃会话：直接移除通知。
  Future<void> cancel() async {
    if (!supported) return;
    _cancelPendingUpdate();
    _lastSentContent = null;
    await _invoke('cancel', null);
  }

  /// 通知点击事件流（app 层订阅后导航回朗读页）。
  Stream<void> get onTap {
    _ensureEventSubscription();
    _tapController ??= StreamController<void>.broadcast();
    return _tapController!.stream;
  }

  /// 通知操作按钮事件流：`prev` / `toggle` / `stop` / `play` / `pause` / `next`。
  Stream<String> get onAction {
    _ensureEventSubscription();
    _actionController ??= StreamController<String>.broadcast();
    return _actionController!.stream;
  }

  /// 媒体样式通知的**拖动进度条**松手事件：0.0~1.0 表示当前事件内的相对位置。
  ///
  /// 原生侧把 MediaSession 的播放状态映射成「1 句 = 1000ms」的虚拟时间轴，
  /// 系统渲染出的 seekbar 被拖动后回调 `onSeekTo`，换算成比例从这条流发过来；
  /// app 层据此换算成第几句并跳到该句（朗读中从该句继续，暂停中只挪位置）。
  Stream<double> get onSeek {
    _ensureEventSubscription();
    _seekController ??= StreamController<double>.broadcast();
    return _seekController!.stream;
  }

  void _ensureEventSubscription() {
    if (!_supported || _eventSubscription != null) return;
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        switch (event['event']) {
          case 'tap':
            _tapController?.add(null);
            break;
          case 'action':
            final action = event['action'];
            if (action is String && action.isNotEmpty) {
              _actionController?.add(action);
            }
            break;
          case 'seek':
            final progress = event['progress'];
            if (progress is num) {
              _seekController?.add(progress.toDouble().clamp(0.0, 1.0));
            }
            break;
        }
      },
      onError: (Object error) {
        debugPrint('[outline-listen] 通知事件通道异常：$error');
      },
      cancelOnError: false,
    );
  }

  /// 冷启动兜底：App 被通知点击拉起时，原生保留 pending 标记，一次性取走。
  Future<bool> consumeLaunchTap() async {
    if (!supported) return false;
    try {
      final result = await _invokeRaw('consumeLaunchTap', null);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// 取消事件订阅（主要给测试 / 热重启清理用）。
  Future<void> disposeBridge() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _tapController?.close();
    _tapController = null;
    await _actionController?.close();
    _actionController = null;
    await _seekController?.close();
    _seekController = null;
  }

  void _flushPendingUpdate() {
    final content = _pendingContent;
    if (content == null) return;
    _pendingContent = null;
    _lastUpdateAt = DateTime.now();
    _lastSentContent = content;
    unawaited(_invoke('update', _contentArgs(content)));
  }

  void _cancelPendingUpdate() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _pendingContent = null;
  }

  Map<String, dynamic> _contentArgs(OutlineListeningNotificationContent content) =>
      {
        'title': content.title,
        'content': content.content,
        'subText': content.subText,
        'progress': content.progress,
        'paused': content.kind == ListenNotificationKind.paused,
        // 媒体样式通知的 seekbar 位置：原生按 1 句=1000ms 映射
        'sentenceOrdinal': content.sentenceOrdinal,
        'sentenceTotal': content.sentenceTotal,
      };

  Future<Object?> _invokeRaw(String method, Map<String, dynamic>? args) {
    final override = debugInvokeOverride;
    if (override != null) return override(method, args);
    return _methodChannel.invokeMethod<Object?>(method, args);
  }

  Future<void> _invoke(String method, Map<String, dynamic>? args) async {
    try {
      final override = debugInvokeOverride;
      if (override != null) {
        await override(method, args);
        return;
      }
      await _methodChannel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      _disabledByError = true;
    } on PlatformException catch (error) {
      debugPrint('[outline-listen] 通知调用失败（$method）：${error.message}');
    } catch (error) {
      if (error is FlutterError) {
        _disabledByError = true;
        return;
      }
      debugPrint('[outline-listen] 通知调用异常（$method）：$error');
    }
  }
}
