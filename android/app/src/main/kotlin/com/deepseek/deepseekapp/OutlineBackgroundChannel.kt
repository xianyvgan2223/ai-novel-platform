package com.deepseek.deepseekapp

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 「一键生成大纲」的后台进度通道（MethodChannel `deepseek_app/outline_background` +
 * EventChannel `deepseek_app/outline_background/events`）。
 *
 * 为什么需要这条通道：生成大纲原本是页面驱动的，页面一销毁 / Dart 侧一停就没进度了。
 * 改造后「生成」仍然留在 Dart 侧（网络、解析都在那边），Android 原生只负责两件事：
 * 1) 用前台服务把「正在生成」的通知钉在通知栏（离开 App 也在、锁屏也不掉进度）；
 * 2) 用户点通知时，把「回到大纲页」这件事传回 Dart —— 已有监听就走 EventChannel 的 tap 事件，
 *    冷启动（Dart 还没监听）就先存成 pending，等 Dart 调 consumeLaunchTap 取走。
 *
 * Dart 侧契约（已冻结，改名/改参数前先对齐 Dart 实现）：
 * - ensureNotificationPermission -> Bool
 * - start / update {title, content, subText, progress} -> null
 * - finish {title, content, success} -> null
 * - cancel（无参数）-> null
 * - consumeLaunchTap -> Bool
 *
 * 通道本身不保存生成内容：每次推进度由 Dart 把文案带过来，原生侧只做展示。
 * 这样 Dart 的生成循环不需要等原生回调，生成逻辑也只有一份。
 */
class OutlineBackgroundChannel(
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
                    OutlineGenerationService.dispatch(
                        context = context,
                        action = if (call.method == "start") {
                            OutlineGenerationService.Action.START
                        } else {
                            OutlineGenerationService.Action.UPDATE
                        },
                        title = call.argument<String>("title") ?: "",
                        content = call.argument<String>("content") ?: "",
                        subText = call.argument<String>("subText") ?: "",
                        progress = (call.argument<Number>("progress")?.toInt() ?: 0)
                            .coerceIn(0, 100),
                    )
                    // 启动服务 / 更新通知都不需要 Dart 等结果，立刻回 null，别拖慢生成循环
                    result.success(null)
                }
                "finish" -> {
                    OutlineGenerationService.dispatch(
                        context = context,
                        action = OutlineGenerationService.Action.FINISH,
                        title = call.argument<String>("title") ?: "",
                        content = call.argument<String>("content") ?: "",
                        success = call.argument<Boolean>("success") ?: false,
                    )
                    result.success(null)
                }
                "cancel" -> {
                    OutlineGenerationService.dispatch(
                        context = context,
                        action = OutlineGenerationService.Action.CANCEL,
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

    /** 引擎销毁时调用：摘掉事件回调，避免之后还有通知点击往已经不存在的引擎发事件 */
    fun dispose() {
        if (eventSink === sinkFromMe) eventSink = null
        sinkFromMe = null
    }

    /**
     * 通知权限（Android 13 起才有运行时权限）。
     *
     * 契约：API<33 直接返回 true —— 低版本没有这个权限，用户在系统设置里关通知不该拦生成；
     * API>=33 当前未授权时弹系统权限框（requestCode 7302），返回「此刻」的
     * areNotificationsEnabled()（刚弹框时通常仍是 false，Dart 侧需要再确认一次）。
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
        const val METHOD_CHANNEL = "deepseek_app/outline_background"
        const val EVENT_CHANNEL = "deepseek_app/outline_background/events"

        /** 通知点击拉起 MainActivity 时带的 extra（见 OutlineGenerationService 的 PendingIntent） */
        const val EXTRA_OPEN_OUTLINE_GENERATION = "open_outline_generation"

        /** 通知权限请求码：固定值，Dart 侧不需要知道（不处理结果，靠再次调用本通道确认） */
        private const val REQUEST_CODE_NOTIFICATIONS = 7302

        private const val TAG = "DshOutlineChannel"

        /**
         * Dart 侧的事件监听。冷启动时可能还没建好，所以 tap 事件只能「有监听就发、没监听就暂存」。
         * 静态是因为 MainActivity 在 onCreate/onNewIntent 时也是静态调用进来的
         * （那一刻通道实例可能刚建好，也可能还没建）。
         */
        @Volatile private var eventSink: EventChannel.EventSink? = null

        /** 有监听之前收到的通知点击：由 consumeLaunchTap 一次性消费 */
        @Volatile private var pendingLaunchTap = false

        /**
         * MainActivity 在 onCreate（冷启动）/ onNewIntent（App 已在运行）时调用：
         * 把「用户点了大纲生成进度通知」这件事记下来。
         */
        fun handleLaunchIntent(intent: Intent?) {
            if (intent == null) return
            // 不是通知点击拉起的普通启动：什么都不做
            if (!intent.getBooleanExtra(EXTRA_OPEN_OUTLINE_GENERATION, false)) return
            // 清掉 extra：同一份 Intent 被再次投递（配置变更重建等）时不会被当成新的点击
            intent.removeExtra(EXTRA_OPEN_OUTLINE_GENERATION)
            deliverTap()
        }

        private fun deliverTap() {
            val sink = eventSink
            if (sink == null) {
                // Dart 还没开始监听（冷启动时的常态）：留给 consumeLaunchTap。
                // 这里绝不能丢，否则点通知起来后页面不知道要跳大纲页
                pendingLaunchTap = true
                return
            }
            // 已有监听（App 在后台/前台）：立刻发事件并清 pending。
            // 调用方在 Activity 生命周期里，本来就是主线程，sink.success 可以直接调
            pendingLaunchTap = false
            runCatching { sink.success(mapOf("event" to "tap")) }
        }

        /**
         * 一次性取走「App 是否被通知点击拉起」：true 只会返回一次。
         * 冷启动时 Dart 在页面初始化里调用它，决定是否跳到「一键生成大纲」页。
         */
        fun consumeLaunchTap(): Boolean {
            val pending = pendingLaunchTap
            pendingLaunchTap = false
            return pending
        }
    }
}
