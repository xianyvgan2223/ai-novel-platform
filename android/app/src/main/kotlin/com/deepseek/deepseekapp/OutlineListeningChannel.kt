package com.deepseek.deepseekapp

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 「听大纲改名」的后台朗读通道（MethodChannel `deepseek_app/outline_listening` +
 * EventChannel `deepseek_app/outline_listening/events`）。
 *
 * 为什么需要这条通道：朗读的逐事件循环在 Dart 侧，页面退到后台后 Flutter 进程需要
 * 一条「继续跑 + 通知栏可播控」的原生通道；Android 原生只负责两件事：
 * 1) 用前台服务把「正在朗读 + 播控」的通知钉在通知栏（见 [OutlineListenService]）；
 * 2) 用户点通知主体 / 点播控按钮时，把事件传回 Dart —— 已有监听就走 EventChannel，
 *    还没监听（冷启动）时 tap 先存成 pending，等 Dart 调 consumeLaunchTap 取走；
 *    播控按钮没有监听就丢弃（契约如此：没人能处理的动作不排队、避免恢复后突然补放）。
 *
 * Dart 侧契约（已冻结，改名/改参数前先对齐 Dart 实现）：
 * - ensureNotificationPermission -> Bool
 * - start / update {title, content, subText, progress, paused, sentenceOrdinal, sentenceTotal} -> null
 * - finish {title, content, success} -> null
 * - cancel（无参数）-> null
 * - consumeLaunchTap -> Bool
 * - 事件 {event: "tap"}
 *        / {event: "action", action: "prev"|"toggle"|"stop"|"play"|"pause"|"next"|"rewind"|"forward"}
 *        / {event: "seek", progress: 0.0~1.0}
 *
 * 其中 seek / rewind / forward 来自通知**展开态自定义大视图**（点进度条分区 / 退进 3 句）；
 * 「1 句 = 1000ms」的虚拟时间轴仍写入 MediaSession，供 Android 11+ 的 QS 媒体卡片拖动使用。
 *
 * 通道本身不保存朗读内容：每次推进度由 Dart 把文案带过来，原生侧只做展示。
 * 这样 Dart 的朗读循环不需要等原生回调，朗读逻辑也只有一份。
 */
class OutlineListeningChannel(
    private val context: Context,
    private val activity: Activity?,
) {

    /** 本实例注册出来的 sink：dispose / onCancel 时只清自己注册的那个，别把后来者的清掉 */
    private var sinkFromMe: EventChannel.EventSink? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Android 13+ 的通知运行时权限：返回「此刻是否允许通知」。
                // 权限框是异步的，刚弹出来时通常还是 false，Dart 侧回到前台后应再调一次确认
                "ensureNotificationPermission" -> result.success(ensureNotificationPermission())
                "start", "update" -> {
                    OutlineListenService.dispatch(
                        context = context,
                        action = if (call.method == "start") {
                            OutlineListenService.Action.START
                        } else {
                            OutlineListenService.Action.UPDATE
                        },
                        title = call.argument<String>("title") ?: "",
                        content = call.argument<String>("content") ?: "",
                        subText = call.argument<String>("subText") ?: "",
                        progress = (call.argument<Number>("progress")?.toInt() ?: 0)
                            .coerceIn(0, 100),
                        // paused 只影响通知里「暂停/继续」按钮的图标与文案；
                        // 朗读本身的暂停是 Dart 侧停掉逐事件循环，原生不碰音频
                        paused = call.argument<Boolean>("paused") ?: false,
                        // 句序号/总句数（冻结契约新增）：原生据此构造 MediaSession 的虚拟时间轴
                        //（1 句 = 1000ms），供 Android 11+ 的 QS 媒体卡片使用；通知展开大视图的
                        // 进度条也用 progress 字段显示当前句百分比
                        sentenceOrdinal = (call.argument<Number>("sentenceOrdinal")?.toInt() ?: 0)
                            .coerceAtLeast(0),
                        sentenceTotal = (call.argument<Number>("sentenceTotal")?.toInt() ?: 0)
                            .coerceAtLeast(0),
                    )
                    // 启动服务 / 更新通知都不需要 Dart 等结果，立刻回 null，别拖慢朗读循环
                    result.success(null)
                }
                "finish" -> {
                    OutlineListenService.dispatch(
                        context = context,
                        action = OutlineListenService.Action.FINISH,
                        title = call.argument<String>("title") ?: "",
                        content = call.argument<String>("content") ?: "",
                        success = call.argument<Boolean>("success") ?: true,
                    )
                    result.success(null)
                }
                "cancel" -> {
                    OutlineListenService.dispatch(
                        context = context,
                        action = OutlineListenService.Action.CANCEL,
                    )
                    result.success(null)
                }
                // 冷启动时 Dart 问一次「App 是不是被通知点击拉起的」：一次性，问过就清
                "consumeLaunchTap" -> result.success(consumeLaunchTap())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    sinkFromMe = sink
                    eventSink = sink
                    // 注意：这里**不补发** pendingLaunchTap。
                    // 冷启动的点击由 Dart 主动调 consumeLaunchTap 取走（契约就是这么定的），
                    // 若这里再补发一次，Dart 两条路都会收到，页面可能被重复打开。
                }

                override fun onCancel(arguments: Any?) {
                    if (eventSink === sinkFromMe) eventSink = null
                    sinkFromMe = null
                }
            },
        )
    }

    /** 引擎销毁时调用：摘掉事件回调，避免之后还有通知点击/播控往已经不存在的引擎发事件 */
    fun dispose() {
        if (eventSink === sinkFromMe) eventSink = null
        sinkFromMe = null
    }

    /**
     * 通知权限（Android 13 起才有运行时权限）。
     *
     * 契约：API<33 直接返回 true —— 低版本没有这个权限，用户在系统设置里关通知不该拦朗读；
     * API>=33 当前未授权时弹系统权限框，返回「此刻」的 areNotificationsEnabled()
     * （刚弹框时通常仍是 false，Dart 侧需要再确认一次）。
     */
    private fun ensureNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val enabled = notificationsEnabled()
        if (enabled) return true
        val host = activity
        if (host != null) {
            runCatching {
                host.requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_CODE_NOTIFICATIONS,
                )
            }.onFailure { Log.w(TAG, "请求通知权限失败", it) }
        }
        return notificationsEnabled()
    }

    private fun notificationsEnabled(): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return manager?.areNotificationsEnabled() ?: false
    }

    companion object {
        const val METHOD_CHANNEL = "deepseek_app/outline_listening"
        const val EVENT_CHANNEL = "deepseek_app/outline_listening/events"

        /** 通知点击拉起 MainActivity 时带的 extra（见 OutlineListenService 的 PendingIntent） */
        const val EXTRA_OPEN_OUTLINE_LISTENING = "open_outline_listening"

        /** 通知权限请求码：固定值（与生成大纲通道的 7302 错开），Dart 侧不需要知道 */
        private const val REQUEST_CODE_NOTIFICATIONS = 7303

        private const val TAG = "DshOutlineListenChannel"

        /**
         * Dart 侧的事件监听。冷启动时可能还没建好，所以 tap 事件只能「有监听就发、没监听就暂存」。
         * 静态是因为 MainActivity 在 onCreate/onNewIntent 时也是静态调用进来的
         * （那一刻通道实例可能刚建好，也可能还没建）。
         */
        @Volatile private var eventSink: EventChannel.EventSink? = null

        /** 有监听之前收到的通知点击：由 consumeLaunchTap 一次性消费 */
        @Volatile private var pendingLaunchTap = false

        /** 事件统一回主线程发（广播接收器、Activity 生命周期回调都可能在主线程之外被调起） */
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * MainActivity 在 onCreate（冷启动）/ onNewIntent（App 已在运行）时调用：
         * 把「用户点了朗读通知」这件事记下来。
         *
         * 注意：这里只认自己的 extra（open_outline_listening），与生成大纲通道的
         * open_outline_generation 互不影响 —— MainActivity 会分别调用两条通道。
         */
        fun handleLaunchIntent(intent: Intent?) {
            if (intent == null) return
            // 不是通知点击拉起的普通启动：什么都不做
            if (!intent.getBooleanExtra(EXTRA_OPEN_OUTLINE_LISTENING, false)) return
            // 清掉 extra：同一份 Intent 被再次投递（配置变更重建等）时不会被当成新的点击
            intent.removeExtra(EXTRA_OPEN_OUTLINE_LISTENING)
            deliverTap()
        }

        private fun deliverTap() {
            val sink = eventSink
            if (sink == null) {
                // Dart 还没开始监听（冷启动时的常态）：留给 consumeLaunchTap。
                // 这里绝不能丢，否则点通知起来后页面不知道要跳朗读页
                pendingLaunchTap = true
                return
            }
            // 已有监听（App 在后台/前台）：立刻发事件并清 pending。
            // sink.success 必须在平台主线程调用，这里可能来自 Activity 生命周期回调，统一 post
            pendingLaunchTap = false
            mainHandler.post { runCatching { sink.success(mapOf("event" to "tap")) } }
        }

        /**
         * 一次性取走「App 是否被通知点击拉起」：true 只会返回一次。
         * 冷启动时 Dart 在页面初始化里调用它，决定是否跳到「听大纲改名」页。
         */
        fun consumeLaunchTap(): Boolean {
            val pending = pendingLaunchTap
            pendingLaunchTap = false
            return pending
        }

        /**
         * 播控动作入口（通知 action 行 / 展开大视图的退进 3 句走 [OutlineListenActionReceiver]，
         * 系统媒体面板/耳机键走 [OutlineListenService] 的 MediaSession 回调）。
         *
         * 契约：没有 EventChannel 监听时直接丢弃，不排队 —— 暂停/停止这类动作有时效性，
         * 等 App 恢复后再补执行反而会让用户困惑（例如早就点过停止，恢复后又收到一次停止）。
         *
         * 白名单里 play/pause/next 只有系统媒体控制会发，rewind/forward 只有通知展开大视图的
         * 「退/进 3 句」按钮会发（通知栏那三个固定按钮仍是 prev/toggle/stop）；
         * 多认几个值不算破坏契约，Dart 侧按 action 分派即可。
         */
        fun deliverAction(action: String) {
            if (action != OutlineListenService.ACTION_PREV &&
                action != OutlineListenService.ACTION_TOGGLE &&
                action != OutlineListenService.ACTION_STOP &&
                action != OutlineListenService.ACTION_PLAY &&
                action != OutlineListenService.ACTION_PAUSE &&
                action != OutlineListenService.ACTION_NEXT &&
                action != OutlineListenService.ACTION_REWIND &&
                action != OutlineListenService.ACTION_FORWARD
            ) {
                return
            }
            val sink = eventSink ?: return
            mainHandler.post {
                runCatching {
                    sink.success(mapOf("event" to "action", "action" to action))
                }
            }
        }

        /**
         * 「跳到当前事件相对进度」入口，两条来源共用：
         * - 通知**展开大视图**里点进度条的第 i 个分区 → [OutlineListenActionReceiver] 收到 seek_fraction；
         * - Android 11+ 系统媒体卡片拖动 seekbar → [OutlineListenService] 的 MediaSession.onSeekTo。
         *
         * [fraction] 是**当前事件内** 0.0~1.0 的相对位置（虚拟时间轴按「1 句 = 1000ms」换算），
         * Dart 侧再换算成第几句并从那里继续读。
         *
         * 与 action 一样：没有监听就丢弃、不排队 —— 进程刚被广播/会话唤起时没人能处理，
         * 补执行一次「跳到某句」比丢掉更容易让用户困惑。
         */
        fun deliverSeek(fraction: Double) {
            val sink = eventSink ?: return
            // 双保险夹取：调用方已经 clamp 过一次，这里防止异常数值把 Dart 侧算崩
            val value = fraction.coerceIn(0.0, 1.0)
            mainHandler.post {
                runCatching {
                    sink.success(mapOf("event" to "seek", "progress" to value))
                }
            }
        }
    }
}
