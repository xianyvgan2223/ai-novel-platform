/// 「一键生成大纲」后台进度通知 —— Dart 侧与 Android 原生通道的桥接。
///
/// 生成本体跑在 Dart（Dio 流式请求 + 解析），原生侧只负责两件事：
/// 1. 用一个 foreground service 把进程保住：退到后台 / 锁屏后 Dart 仍在跑，
///    否则系统随时可能把进程回收，几十次 AI 调用的长任务会前功尽弃；
/// 2. 把 [OutlineNotificationContent] 渲染成通知栏里带进度条的通知。
///
/// 通知点击通过 [onTap] 广播给 app 层（main.dart），由它导航回「一键生成大纲」
/// 页面查看当前生成详情；冷启动那次点击用 [consumeLaunchTap] 一次性取走。
///
/// 设计约束：
/// - 只支持 Android；桌面 / Web / 单元测试环境全部静默降级为 no-op，
///   这样控制器和页面不需要到处判断平台；
/// - 所有原生调用都自己吞掉异常：通知只是辅助展示，任何通道问题都不能反过来
///   影响大纲生成（插件没注册、权限被拒、系统禁通知等情况都按「没有通知」处理）；
/// - 更新做节流：流式生成时控制器状态变化很频繁，每次通知更新都是一次 IPC +
///   系统通知重绘，400ms 一次对用户来说已经完全够顺滑。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知展示的内容快照（纯数据、不依赖原生，便于单测）。
enum OutlineNotificationKind { running, paused, finished }

/// 一条通知要显示什么：标题、正文、子文本、进度百分比、完成态是否成功。
///
/// 由 [OutlineController] 的状态换算而来，原生侧只负责按这些字段渲染，
/// 因此文案规则可以完全在 Dart 单测里覆盖。
class OutlineNotificationContent {
  final OutlineNotificationKind kind;
  final String title;
  final String content;
  final String subText;

  /// 0~100，通知栏进度条；完成 / 中断态固定 100（原生侧不画进度条）。
  final int progress;

  /// 仅 [OutlineNotificationKind.finished] 有意义：true = 正常完成，false = 中断/失败。
  final bool success;

  const OutlineNotificationContent({
    required this.kind,
    required this.title,
    required this.content,
    required this.subText,
    required this.progress,
    this.success = true,
  });

  /// 生成中：标题带书名（已生成书名后），正文是当前步骤 / 展开块进度，
  /// 副文本显示最近完成一步的耗时统计（通知下拉展开后可见）。
  factory OutlineNotificationContent.running({
    required String bookTitle,
    required String progressText,
    required int progress,
    String? lastStepSummary,
  }) {
    final title = bookTitle.trim();
    final summary = lastStepSummary?.trim() ?? '';
    final text = progressText.trim();
    return OutlineNotificationContent(
      kind: OutlineNotificationKind.running,
      title: title.isEmpty ? '正在生成大纲' : '正在生成大纲：《$title》',
      content: text.isEmpty ? '正在生成...' : text,
      subText: summary.isEmpty ? '点按查看生成详情' : '最近完成：$summary',
      progress: progress.clamp(0, 100),
    );
  }

  /// 检查点暂停：生成流程停在下述某个检查点，等用户回页面确认或编辑后继续。
  factory OutlineNotificationContent.paused({
    required String bookTitle,
    required String checkpointLabel,
    required int progress,
  }) {
    final title = bookTitle.trim();
    final label = checkpointLabel.trim().isEmpty
        ? '生成内容'
        : checkpointLabel.trim();
    return OutlineNotificationContent(
      kind: OutlineNotificationKind.paused,
      title: title.isEmpty ? '大纲生成已暂停 · 等待确认' : '《$title》生成已暂停',
      content: '$label已生成，等待你确认后继续',
      subText: '点按返回大纲生成页面查看并继续',
      progress: progress.clamp(0, 100),
    );
  }

  /// 完成 / 中断：非 ongoing 通知，点按回到页面查看结果或继续。
  factory OutlineNotificationContent.finished({
    required String bookTitle,
    required bool success,
    String? message,
    int charCount = 0,
  }) {
    final title = bookTitle.trim();
    final rawMessage = message?.trim() ?? '';
    final detail = rawMessage.isEmpty
        ? (success ? '已保存到历史大纲' : '生成中断，可回到页面继续上次进度')
        : _truncate(rawMessage, 60);
    if (success) {
      return OutlineNotificationContent(
        kind: OutlineNotificationKind.finished,
        title: title.isEmpty ? '大纲生成完成' : '《$title》大纲生成完成',
        content: charCount > 0 ? '共约 $charCount 字 · $detail' : detail,
        subText: '点按查看生成详情',
        progress: 100,
        success: true,
      );
    }
    return OutlineNotificationContent(
      kind: OutlineNotificationKind.finished,
      title: title.isEmpty ? '大纲生成中断' : '《$title》生成中断',
      content: detail,
      subText: '点按返回大纲生成页面查看',
      progress: 100,
      success: false,
    );
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  @override
  bool operator ==(Object other) =>
      other is OutlineNotificationContent &&
      other.kind == kind &&
      other.title == title &&
      other.content == content &&
      other.subText == subText &&
      other.progress == progress &&
      other.success == success;

  @override
  int get hashCode =>
      Object.hash(kind, title, content, subText, progress, success);

  @override
  String toString() =>
      'OutlineNotificationContent(${kind.name}, $progress%, '
      '$title | $content | $subText)';
}

/// 与 Android 原生通道通信的单例。
///
/// 方法/事件通道名与 `OutlineBackgroundChannel.kt`、`OutlineGenerationService.kt`
/// 一一对应，改名时两边必须同步。
class OutlineBackgroundNotification {
  OutlineBackgroundNotification({
    bool? supported,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this.debugInvokeOverride,
  }) : _supported = supported ?? _defaultSupported,
       _methodChannel = methodChannel ?? const MethodChannel(_kMethodChannel),
       _eventChannel = eventChannel ?? const EventChannel(_kEventChannel);

  static const String _kMethodChannel = 'deepseek_app/outline_background';
  static const String _kEventChannel = 'deepseek_app/outline_background/events';

  /// 稳定单例：进程内所有生成流程共用同一条通知。
  static final OutlineBackgroundNotification instance =
      OutlineBackgroundNotification();

  /// 与本机平台能力无关的「是否 Android」判断（桌面 / Web / 单测为 false）。
  static bool get _defaultSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const Duration _minUpdateInterval = Duration(milliseconds: 400);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  /// 单元测试注入：替代真实 [MethodChannel.invokeMethod]（不触碰原生）。
  @visibleForTesting
  final Future<Object?> Function(String method, Map<String, dynamic>? args)?
  debugInvokeOverride;

  bool _disabledByError = false;

  final bool _supported;

  StreamController<void>? _tapController;
  StreamSubscription<dynamic>? _tapSubscription;

  OutlineNotificationContent? _pendingContent;
  OutlineNotificationContent? _lastSentContent;
  Timer? _updateTimer;
  DateTime _lastUpdateAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前环境是否真的会显示通知（Android 真机为 true；测试 / 桌面为 false）。
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

  /// 开始一次新的生成通知：立即发出（不节流），原生侧会拉起前台服务。
  Future<void> start(OutlineNotificationContent content) async {
    if (!supported) return;
    _cancelPendingUpdate();
    _lastSentContent = content;
    _lastUpdateAt = DateTime.now();
    await _invoke('start', _contentArgs(content));
  }

  /// 更新进度通知：节流到最多 400ms 一次，连续调用时只保留最新内容。
  /// 返回 void 是有意的——调用方（控制器 notifyListeners）不等待 IPC 完成。
  void update(OutlineNotificationContent content) {
    if (!supported) return;
    if (content == _lastSentContent || content == _pendingContent) return;
    _pendingContent = content;
    if (_updateTimer != null) return; // 已有定时器，最新内容在 _pendingContent 里
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

  /// 生成结束：把通知切成最终态（可点击、可划掉），并停掉前台服务。
  Future<void> finish(
    OutlineNotificationContent content, {
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

  /// 用户主动取消生成：直接移除通知。
  Future<void> cancel() async {
    if (!supported) return;
    _cancelPendingUpdate();
    _lastSentContent = null;
    await _invoke('cancel', null);
  }

  /// 通知点击事件流（app 层订阅后导航回大纲生成页面）。
  Stream<void> get onTap {
    final existing = _tapController;
    if (existing != null) return existing.stream;
    final controller = StreamController<void>.broadcast();
    _tapController = controller;
    if (_supported) {
      _tapSubscription = _eventChannel.receiveBroadcastStream().listen(
        (event) {
          if (event is Map && event['event'] == 'tap') controller.add(null);
        },
        onError: (Object error) {
          debugPrint('[outline-bg] 通知点击事件通道异常：$error');
        },
        cancelOnError: false,
      );
    }
    return controller.stream;
  }

  /// 冷启动兜底：App 被通知点击拉起时，原生会保留一个 pending 标记，
  /// 这里一次性取走（之后返回 false），避免重复导航。
  Future<bool> consumeLaunchTap() async {
    if (!supported) return false;
    try {
      final result = await _invokeRaw('consumeLaunchTap', null);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// 取消通知点击事件订阅（主要给测试 / 热重启清理用；App 生命周期内常驻即可）。
  Future<void> disposeBridge() async {
    await _tapSubscription?.cancel();
    _tapSubscription = null;
    await _tapController?.close();
    _tapController = null;
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

  Map<String, dynamic> _contentArgs(OutlineNotificationContent content) => {
    'title': content.title,
    'content': content.content,
    'subText': content.subText,
    'progress': content.progress,
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
      // 原生侧没注册（单测 / 桌面 / 旧包）：本进程内不再尝试，避免刷屏
      _disabledByError = true;
    } on PlatformException catch (error) {
      debugPrint('[outline-bg] 通知调用失败（$method）：${error.message}');
    } catch (error) {
      // 纯 Dart 单测里 WidgetsBinding 还没初始化时，调用通道会抛 FlutterError
      // （"Binding has not yet been initialized"）；这种环境本来就没有原生宿主，
      // 直接降级即可，不要往测试日志里刷一条吓人的异常。
      if (error is FlutterError) {
        _disabledByError = true;
        return;
      }
      debugPrint('[outline-bg] 通知调用异常（$method）：$error');
    }
  }
}
