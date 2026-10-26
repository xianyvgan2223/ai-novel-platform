package com.deepseek.deepseekapp

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import kotlin.math.roundToInt

/**
 * 「听大纲改名」的后台朗读前台服务：逐事件朗读时把「正在读哪一条 + 进度 + 播控」钉在通知栏，
 * 用户退回桌面、切到别的 App、锁屏后都继续读。
 *
 * 为什么必须是前台服务：朗读的**逐事件循环**（读完一条自动读下一条）在 Dart 侧。
 * 页面一退后台，Flutter 进程随时可能被系统冻结/回收，回调不再推进，听起来就是「读一句就停」。
 * 前台服务是 Android 允许长期留在后台、且**必须**显示一条通知的组件，正好对上
 * 「离开 App 还继续读 + 通知栏能暂停/继续/停止」这个需求。
 *
 * 声音本身由系统 TTS 引擎（独立进程）或内置离线引擎（AudioTrack）发出；这个服务不碰音频，
 * 只负责「保活 + 通知 + 把用户的播控动作转给 Dart」（见 [OutlineListeningChannel]）。
 *
 * 数据流：Dart 调 MethodChannel 的 start/update → 这里更新通知；Dart 调 finish/cancel → 收尾；
 * 用户点通知按钮 → [OutlineListenActionReceiver] → Dart 侧决定怎么读。
 *
 * 通知形态（真机回退后）：**普通进度通知**（标题/正文/副文本/进度条/三个播控按钮），
 * 展开态换成自定义 RemoteViews（[Notification.Builder.setCustomBigContentView]）：
 * 点文字区域回朗读页、进度条上盖 10 个等宽透明分区（点第 i 格跳到约 (i+0.5)/10 处）、
 * 一行「退 3 句 / 进 3 句」、以及一行「上一个 / 暂停-继续 / 停止」播控按钮
 *（真机 EMUI 把自定义大视图当完整展开内容，不再渲染通知自带的 action 行，所以要自带一份）。
 * 为什么不用 MediaStyle：实测 Android 10 / EMUI 的 SystemUI 媒体通知模板不渲染系统 seekbar，
 * 还会把原先可见的进度条盖掉。
 *
 * MediaSession 仍然保留并把「当前事件第几句 / 总句数」映射成 1 句=1000ms 的虚拟时间轴写进
 * PlaybackState：Android 11+ 的快捷设置媒体卡片/锁屏播控仍从它取状态，拖动则经 onSeekTo
 * 换算成 0~1 的相对进度回传 Dart（只是不再把 MediaStyle 挂到通知上）。
 *
 * 状态同步约定：同进程内由 Dart 保证 start → update… → finish/cancel 的顺序，
 * 所以「服务是否在跑」用一个静态标志（[running]）就够，不做跨进程持久化。
 */
class OutlineListenService : Service() {

    /** 是否已经调用过 startForeground：决定后续 update 是「notify 刷新」还是「先升级为前台」 */
    @Volatile private var foregroundActive = false

    private var notificationManager: NotificationManager? = null

    /** 朗读期间持有的 CPU 锁（见 [acquireWakeLock]）；finish / cancel / 各种销毁路径都必须释放 */
    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * 媒体会话：系统播控（Android 11+ 快捷设置媒体卡片 / 锁屏 / 耳机键）靠它。
     *
     * 为什么用平台 MediaSession 而不是 androidx.media：本项目不引 androidx，平台类
     * API 21 起就有，minSdk 24 完全够用。通知本身已不再挂 MediaStyle（兼容性原因见类注释），
     * 但媒体卡片/锁屏播控仍从 active MediaSession 的 PlaybackState 读取播放状态与位置。
     */
    private var mediaSession: MediaSession? = null

    /** 当前事件内第几句（1 起，0 = 没有句信息）—— 系统媒体卡片/锁屏播控的虚拟时间轴：1 句 = 1000ms */
    private var sentenceOrdinal = 0

    /** 当前事件总句数（0 = 没有句信息，此时 duration=0、不提供拖动） */
    private var sentenceTotal = 0

    /** 最近一次 update 的标题/正文：系统媒体面板（Android 13+ 快捷设置的播放器卡片）靠 MediaMetadata 显示 */
    private var mediaTitle = ""
    private var mediaText = ""

    /** 最近一次 update 的暂停态：onSeekTo 回传后重建 PlaybackState 时要保持这个状态不变 */
    private var paused = false

    /**
     * onSeekTo 之后、Dart 下一次 update 之前的临时播放位置（毫秒）；-1 = 用句序换算出的真实位置。
     *
     * 为什么要这个：用户拖动 seekbar 松手后（Android 11+ 的 QS 媒体卡片），系统会立刻按
     * 「它认为的位置」重绘进度条；如果这里不把 PlaybackState 挪到拖动位置，进度条会先弹回
     * 旧句、等 Dart 处理完再跳一次。先落在拖动位置，Dart 的 update 回来后再用真实句序覆盖，
     * 视觉上就不会回弹。
     */
    private var seekPreviewMs = -1L

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        // 渠道必须在本服务的第一次 notify / startForeground 之前建好，
        // 否则 API 26+ 上通知会被系统直接丢掉（Android 8 起通知必须归属某个渠道）
        ensureNotificationChannel(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // 没有具体命令（理论上只有系统重启服务才会这样）：直接收尾，别空跑一个前台服务
            stopSelf()
            return Service.START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_UPDATE_NOTIFICATION -> showOrUpdate(
                title = intent.getStringExtra(EXTRA_TITLE) ?: DEFAULT_PROGRESS_TITLE,
                content = intent.getStringExtra(EXTRA_CONTENT) ?: "",
                subText = intent.getStringExtra(EXTRA_SUBTEXT) ?: "",
                progress = intent.getIntExtra(EXTRA_PROGRESS, 0),
                paused = intent.getBooleanExtra(EXTRA_PAUSED, false),
                sentenceOrdinal = intent.getIntExtra(EXTRA_SENTENCE_ORDINAL, 0),
                sentenceTotal = intent.getIntExtra(EXTRA_SENTENCE_TOTAL, 0),
            )
            ACTION_FINISH -> finishWithNotification(
                title = intent.getStringExtra(EXTRA_TITLE) ?: DEFAULT_FINISH_TITLE,
                content = intent.getStringExtra(EXTRA_CONTENT) ?: "",
                success = intent.getBooleanExtra(EXTRA_SUCCESS, true),
            )
            ACTION_CANCEL -> cancelAndStop()
            ACTION_ACTIVITY_DESTROYED -> handleHostActivityDestroyed()
            else -> Log.w(TAG, "收到未知命令：${intent.action}")
        }
        // 不用 START_STICKY：进度与播放状态完全由 Dart 侧驱动，进程被系统杀掉后
        // 没人会接着推进度，系统重新拉起服务只会留下一条永远不动的「正在朗读」假通知
        return Service.START_NOT_STICKY
    }

    // ---- 命令处理 ----

    /** Dart 侧的命令（冻结契约里的 start/update/finish/cancel），内部再映射成 Intent action */
    enum class Action { START, UPDATE, FINISH, CANCEL }

    /** START / UPDATE：第一次先升级为前台服务，之后都是同 id 静默刷新通知 */
    private fun showOrUpdate(
        title: String,
        content: String,
        subText: String,
        progress: Int,
        paused: Boolean,
        sentenceOrdinal: Int,
        sentenceTotal: Int,
    ) {
        running = true
        // 记下句序号/总句数：它们决定 MediaSession 虚拟时间轴的长度与当前位置（1 句 = 1000ms），
        // 供 Android 11+ 的 QS 媒体卡片/锁屏播控使用
        this.mediaTitle = title
        this.mediaText = content
        this.sentenceOrdinal = sentenceOrdinal.coerceAtLeast(0)
        this.sentenceTotal = sentenceTotal.coerceAtLeast(0)
        this.paused = paused
        // 新内容从 Dart 回来：清掉拖动预览，位置重新由句序换算
        seekPreviewMs = -1L
        // 只有「正在读」才需要 CPU 锁：锁屏后没有它，进程可能被挂起，Dart 的
        // 「读完自动读下一条」回调就断了；暂停时没有解码/播放，持锁只会白白耗电，
        // 所以按 paused 动态 acquire / release（继续播放时再拿回来）
        if (paused) {
            releaseWakeLock()
        } else {
            acquireWakeLock()
        }
        // 保留 MediaSession 的状态更新（metadata/PlaybackState）：Android 11+ 的 QS 媒体卡片
        // 与锁屏播控仍从它取状态；但**不再**把 MediaStyle 挂到通知上（EMUI 媒体模板不渲染
        // seekbar、还会盖掉普通进度条，真机实测不可用）
        ensureMediaSession()
        applyMediaSessionState()
        // 句序号/总句数一并传下去：展开视图的滑块圆点要按当前句位算档位
        val notification = buildProgressNotification(
            this,
            title,
            content,
            subText,
            progress,
            paused,
            this.sentenceOrdinal,
            this.sentenceTotal,
        )
        if (foregroundActive) {
            // 同 id notify 就是「原地替换」：不响铃、不闪、不重复弹（配合 setOnlyAlertOnce）
            notificationManager?.notify(NOTIFICATION_ID, notification)
            return
        }
        try {
            startForegroundCompat(notification)
            foregroundActive = true
            Log.i(TAG, "朗读前台服务已启动：$title（$progress%，第$sentenceOrdinal/${sentenceTotal}句）")
        } catch (t: Throwable) {
            // 极少数 ROM / 服务配额场景下 startForeground 会抛异常；不能让 App 直接崩，
            // 退化成普通通知更新（Dart 侧朗读照跑，只是失去前台服务保活）
            Log.e(TAG, "startForeground 失败，退化为普通通知", t)
            notificationManager?.notify(NOTIFICATION_ID, notification)
        }
    }

    /** FINISH：通知改成最终态并保留在通知栏，然后退出前台、释放资源 */
    private fun finishWithNotification(title: String, content: String, success: Boolean) {
        // 先把同 id 通知替换成最终态，再从「前台通知」降级为普通通知（DETACH 会保留它），
        // 这样用户还能点通知回朗读页看结果
        notificationManager?.notify(NOTIFICATION_ID, buildFinalNotification(this, title, content, success))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        // 终态通知已经不带播控/进度了，会话没有继续存在的意义：释放掉，
        // 否则系统媒体控制面板里会一直留着一个「已读完但仍可暂停」的僵尸会话
        releaseMediaSession()
        running = false
        stopSelf()
        Log.i(TAG, "朗读结束：$title（success=$success）")
    }

    /** CANCEL：用户主动停止朗读，通知要立刻消失（不能像 finish 那样留着） */
    private fun cancelAndStop() {
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            foregroundActive = false
        }
        notificationManager?.cancel(NOTIFICATION_ID)
        releaseWakeLock()
        releaseMediaSession()
        running = false
        stopSelf()
        Log.i(TAG, "朗读已取消，通知与服务都已移除")
    }

    // ---- 生命周期兜底 ----

    /**
     * Activity 真正销毁（返回键退出 App 等，由 [hostActivityDestroyed] 转投递进来）：
     * Flutter 引擎已经跟着 Activity 销毁，Dart 侧的逐事件循环停了，服务不能再挂着「正在朗读」。
     *
     * 幂等：`onTaskRemoved` 可能已经先收尾过一轮（running 已置 false），此时只把可能被重新拉起的
     * 空实例停掉，绝不重复贴通知。
     */
    private fun handleHostActivityDestroyed() {
        if (!running) {
            stopSelf()
            return
        }
        notificationManager?.notify(NOTIFICATION_ID, buildInterruptedNotification(this, INTERRUPTED_CONTENT))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        // 中断收尾：通知已换成「已停止」终态，媒体会话一并释放，别在系统播控面板里留僵尸
        releaseMediaSession()
        running = false
        stopSelf()
        Log.i(TAG, "Activity 已销毁（退出 App），朗读按「已停止」收尾")
    }

    /**
     * 用户从最近任务里划掉 App：Flutter 引擎随 Activity 一起销毁，Dart 的逐事件循环不会再有后续。
     *
     * 如果不管，服务仍停在前台，通知栏就会永远挂着一条「正在朗读」的假通知（点开发现没在读）。
     * 所以这里把通知改成「已停止」提示（非 ongoing、可点、可划掉），并主动释放前台身份与 CPU 锁。
     * 幂等：Activity onDestroy 可能已经先收尾过（running=false），那就只停掉残留实例。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!running) {
            stopSelf()
            super.onTaskRemoved(rootIntent)
            return
        }
        notificationManager?.notify(NOTIFICATION_ID, buildInterruptedNotification(this, INTERRUPTED_CONTENT))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        // 中断收尾：通知已换成「已停止」终态，媒体会话一并释放，别在系统播控面板里留僵尸
        releaseMediaSession()
        running = false
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /**
     * API 35+：前台服务累计跑满系统允许的时长后，系统会回调这里。
     * 不处理的默认行为是直接停服务，通知栏却还留着「正在朗读」，因此和划掉任务一样按
     * 「已停止」收尾；反正 Dart 的朗读循环也停不下来了（超时回调意味着系统要收走服务）。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (!running) {
            stopSelf(startId)
            return
        }
        Log.w(TAG, "前台服务超时（fgsType=$fgsType），按朗读已停止收尾")
        notificationManager?.notify(NOTIFICATION_ID, buildInterruptedNotification(this, TIMEOUT_CONTENT))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        releaseMediaSession()
        running = false
        stopSelf(startId)
    }

    override fun onDestroy() {
        // 走到这里还没释放，说明服务是被系统意外销毁的（内存紧张 / 被强停）：
        // 兜底释放 CPU 锁，绝不能让它泄漏（锁屏后一直亮着 CPU 会明显耗电）
        if (foregroundActive) {
            // 非正常结束：把「正在朗读」通知撤掉，避免留下一条永远不动的假进度
            runCatching { stopForeground(Service.STOP_FOREGROUND_REMOVE) }
            foregroundActive = false
        }
        releaseWakeLock()
        // 服务没了，MediaSession 必须释放：会话属于进程级资源，不 release 会让
        // 系统播控面板/媒体按键继续指向一个已经不存在的朗读任务
        releaseMediaSession()
        running = false
        notificationManager = null
        super.onDestroy()
    }

    // ---- 前台服务 / CPU 锁 ----

    /** API 29+ 的 startForeground 要显式带上前台服务类型（与清单里的 mediaPlayback 保持一致） */
    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * 拿一把 PARTIAL_WAKE_LOCK：只保 CPU 不休眠、不亮屏。
     *
     * 为什么需要它：用户很可能按下电源键把手机放兜里继续「听大纲」；没有这把锁，
     * 屏幕一灭 CPU 很快休眠，Dart 的逐事件回调与系统 TTS 的完成回调都可能被延迟，
     * 听感就是「读到一半卡住」。finish / cancel / onTaskRemoved / onTimeout / onDestroy 都会释放。
     */
    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        // 旧锁如果还在但已失效，先清掉再重建，避免持有两个引用
        releaseWakeLock()
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val lock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        // 不用引用计数：整个服务只持有这一把，正常路径一次释放即可；
        // 开了引用计数反而容易因为重复 acquire / 少一次 release 泄漏
        lock.setReferenceCounted(false)
        runCatching { lock.acquire() }.onFailure { Log.w(TAG, "获取 wakelock 失败", it) }
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        runCatching {
            if (lock.isHeld) lock.release()
        }
    }

    // ---- 媒体会话（Android 11+ 系统媒体卡片 / 锁屏播控） ----

    /**
     * 懒创建并持有 MediaSession（由主线程的 onStartCommand 调到，满足「主线程创建」）。
     *
     * 保留它的原因：Android 11+ 的快捷设置「媒体播放器」卡片 / 锁屏播控是从 active MediaSession
     * 的 PlaybackState（state/position/duration/actions）取状态的，没有会话就看不到系统播控。
     * 注意：通知**不再**绑定 MediaStyle（真机实测 EMUI 的媒体通知模板不渲染系统 seekbar、
     * 还会盖掉普通进度条）；可拖动的跳句改由通知展开态的自定义大视图提供。
     *
     * 回调里只做「转发」：真正的播放/暂停/跳句由 Dart 的朗读循环决定（原生不碰音频），
     * 拖动则先本地更新位置防回弹，再把 0~1 相对进度交给 Dart 换算。
     */
    private fun ensureMediaSession(): MediaSession? {
        mediaSession?.let { return it }
        return try {
            val session = MediaSession(this, MEDIA_SESSION_TAG)
            @Suppress("DEPRECATION")
            run {
                // API 26+ 默认就处理媒体按键/播控，这两个 flag 是给 API 24/25 用的；
                // 声明了 `android:foregroundServiceType=mediaPlayback` 的服务才「名正言顺」持有会话
                session.setFlags(
                    MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                        MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
                )
            }
            session.setCallback(object : MediaSession.Callback() {
                // 系统媒体面板/耳机键按下的动作原样回传给 Dart，由 Dart 判断是否真的播放/暂停
                override fun onPlay() {
                    OutlineListeningChannel.deliverAction(ACTION_PLAY)
                }

                override fun onPause() {
                    OutlineListeningChannel.deliverAction(ACTION_PAUSE)
                }

                override fun onSkipToPrevious() {
                    OutlineListeningChannel.deliverAction(ACTION_PREV)
                }

                override fun onSkipToNext() {
                    OutlineListeningChannel.deliverAction(ACTION_NEXT)
                }

                override fun onStop() {
                    OutlineListeningChannel.deliverAction(ACTION_STOP)
                }

                override fun onSeekTo(pos: Long) {
                    // 拖动松手（来自 Android 11+ 的 QS 媒体卡片/锁屏播控）：先把会话位置挪到
                    // 目标值（进度条不回弹），再把 0~1 的相对进度交给 Dart 换算成「第几句」；
                    // Dart 下一次 update 会带着真实句序把位置覆盖回来
                    val duration = mediaDurationMs()
                    val clamped = pos.coerceIn(0L, duration)
                    seekPreviewMs = clamped
                    runCatching {
                        mediaSession?.setPlaybackState(buildPlaybackState(duration, clamped))
                    }
                    val fraction = if (duration > 0) {
                        clamped.toDouble() / duration.toDouble()
                    } else {
                        0.0
                    }
                    OutlineListeningChannel.deliverSeek(fraction)
                }
            })
            // 点系统媒体控制卡片 = 回朗读页：复用通知主体的 PendingIntent（同一个
            // open_outline_listening extra，MainActivity 那边不用为媒体卡片再开一条路）
            runCatching { session.setSessionActivity(contentIntent(this)) }
            session.isActive = true
            mediaSession = session
            Log.i(TAG, "MediaSession 已创建并激活")
            session
        } catch (t: Throwable) {
            // 个别 ROM 的 MediaSession 实现会抛异常；失败就退回普通通知（三个播控按钮仍在），
            // 不能因为一个「体验升级」把朗读本身搞崩
            Log.w(TAG, "创建 MediaSession 失败，通知退回普通样式", t)
            null
        }
    }

    /**
     * 把最近一次 update 的标题/句序号/暂停态写进 MediaSession：
     * 这是 Android 11+ 系统媒体卡片 / 锁屏播控的数据源（通知本身用自定义大视图的进度条）。
     */
    private fun applyMediaSessionState() {
        val session = mediaSession ?: return
        val duration = mediaDurationMs()
        // Android 13+ 的快捷设置媒体播放器卡片会显示 MediaMetadata 的标题/副标题；
        // 不设置的话卡片是一片空白，只剩一个播放键。通知本身仍用自己的 title/content。
        //
        // ⚠️ METADATA_KEY_DURATION 必须写：系统媒体通知/锁屏的 seekbar 是拿
        // 「Metadata.duration + PlaybackState.position」算位置的；只给 PlaybackState
        // 的 position 而不给 metadata 的 duration，SystemUI 会认为「没有时长」，
        // 直接不画可拖动的 seekbar（真机上表现为媒体通知只有按钮、没有进度条）。
        runCatching {
            session.setMetadata(
                MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, mediaTitle)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, mediaText)
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, duration)
                    .build(),
            )
        }
        val rawPosition = if (seekPreviewMs >= 0L) seekPreviewMs else mediaPositionMs()
        val position = rawPosition.coerceIn(0L, duration)
        runCatching { session.setPlaybackState(buildPlaybackState(duration, position)) }
    }

    /**
     * 按「1 句 = 1000ms」的虚拟时间轴构造 PlaybackState。
     *
     * 为什么用虚拟时间轴：系统 seekbar 只认毫秒，而朗读的「可拖动单位」是一句；
     * 把每句固定映射成 1000ms 后，拖动位置 / 1000 再四舍五入就是第几句，
     * 既能拖动又不用等 TTS 合成出真实音频时长（真实时长依赖语速、引擎，拿不到也不稳定）。
     *
     * 注意：sentenceTotal=0（该事件没有句信息）时 duration=0，并且**不声明 SEEK_TO**，
     * 系统就不会显示一条拖不动的空进度条；此时仍保留原有通知进度条与按钮。
     */
    private fun buildPlaybackState(durationMs: Long, positionMs: Long): PlaybackState {
        var actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_STOP
        if (durationMs > 0) actions = actions or PlaybackState.ACTION_SEEK_TO
        return PlaybackState.Builder()
            .setActions(actions)
            .setState(
                // 暂停时状态必须是 STATE_PAUSED（而不是 STOPPED）：系统在 PAUSED 下
                // 仍允许拖动 seekbar，正好对上「暂停也能拖到别处、继续时从那里读」
                if (paused) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING,
                positionMs,
                // speed = 0.0：这里的「1 句 = 1000ms」是**虚拟轴**，不是真实音频时长
                // （真实一句可能要读 2~5 秒）。如果给 1.0，系统会按「1 秒/句」的速率自己
                // 外推进度条，句内跑得比真实朗读快、下一次 update 又跳回句首，观感是回跳/抖动。
                // 给 0.0 后系统只认我们 update 推来的 position，进度条随句子稳步前进；
                // 拖动 seekbar 不受影响（拖动回调 position 是用户给的值，不依赖外推速率）。
                0.0f,
            )
            .build()
    }

    /** 虚拟时间轴总长度：每句 1000ms；没有句信息时为 0（不可拖） */
    private fun mediaDurationMs(): Long = sentenceTotal.coerceAtLeast(0) * 1000L

    /** 虚拟时间轴当前位置：第 N 句 ⇒ (N-1)*1000ms；句子序号异常时夹到 0 */
    private fun mediaPositionMs(): Long = (sentenceOrdinal - 1).coerceAtLeast(0) * 1000L

    /** 释放媒体会话（幂等）：先停用再 release，别把系统播控/媒体按键继续指向已结束的朗读 */
    private fun releaseMediaSession() {
        val session = mediaSession ?: return
        mediaSession = null
        seekPreviewMs = -1L
        runCatching { session.setActive(false) }
        runCatching { session.release() }
        Log.i(TAG, "MediaSession 已释放")
    }

    companion object {
        /** 通知渠道 id（固定值：渠道一旦建好，用户改过的重要性会被系统记住，不能随意换 id） */
        const val CHANNEL_ID = "outline_listening_progress"

        /** 固定通知 id：进度、终态、中断都用这一条，Dart 侧不需要知道它 */
        const val NOTIFICATION_ID = 7302

        /** wakelock tag：真机排查时 `adb shell dumpsys power | findstr outline` 能看到 */
        private const val WAKE_LOCK_TAG = "deepseekapp:outline_listening"

        private const val ACTION_UPDATE_NOTIFICATION = "com.deepseek.deepseekapp.outline.LISTEN_SHOW"
        private const val ACTION_FINISH = "com.deepseek.deepseekapp.outline.LISTEN_FINISH"
        private const val ACTION_CANCEL = "com.deepseek.deepseekapp.outline.LISTEN_CANCEL"

        /** Activity 真正退出（非划掉任务）时由 MainActivity.onDestroy 投递，用来把「正在朗读」通知收尾 */
        private const val ACTION_ACTIVITY_DESTROYED =
            "com.deepseek.deepseekapp.outline.LISTEN_ACTIVITY_DESTROYED"

        /**
         * 通知三个播控按钮的广播 action（冻结契约）。
         * 必须与 AndroidManifest.xml 里 [OutlineListenActionReceiver] 的 intent-filter 逐字一致，
         * 否则按钮点下去没有接收器，表现为「点了没反应」。
         */
        const val ACTION_LISTEN = "com.deepseek.deepseekapp.outline.LISTEN_ACTION"

        /** 按钮动作 extra 名（冻结契约：prev / toggle / stop） */
        const val EXTRA_ACTION = "action"

        const val ACTION_PREV = "prev"
        const val ACTION_TOGGLE = "toggle"
        const val ACTION_STOP = "stop"

        /**
         * 系统媒体控制（锁屏/媒体面板/耳机键）回调出的细粒度动作（冻结契约）。
         *
         * 为什么单独有 play/pause：系统媒体面板自己会按当前状态给「播放」或「暂停」按钮，
         * 它不知道 Dart 侧此刻能不能播，所以原生只把动作原样回传，由 Dart 判断是否真的播放/暂停；
         * toggle 仍保留给通知栏那三个固定按钮。
         */
        const val ACTION_PLAY = "play"
        const val ACTION_PAUSE = "pause"
        const val ACTION_NEXT = "next"

        /**
         * 通知展开大视图里的动作（自定义 RemoteViews，非系统 action 行）：
         * - seek_fraction：点了进度条上的第 i 个分区，extra [EXTRA_FRACTION] 带 0~1 的比例；
         * - rewind / forward：退 3 句 / 进 3 句，与 action 事件同一条回传链路。
         * 都由 [OutlineListenActionReceiver] 收到后转给 [OutlineListeningChannel]。
         */
        const val ACTION_SEEK_FRACTION = "seek_fraction"
        const val ACTION_REWIND = "rewind"
        const val ACTION_FORWARD = "forward"

        /** seek_fraction 广播里的比例 extra（Double，0.0~1.0） */
        const val EXTRA_FRACTION = "fraction"

        /** MediaSession 的调试 tag（`adb shell dumpsys media_session | findstr DshOutline` 能看到） */
        private const val MEDIA_SESSION_TAG = "DshOutlineListen"

        /** 展开大视图里进度条上盖的分区数：10 格 = 每格 10%，点第 i 格取 (i+0.5)/10 的比例 */
        private const val SEEK_ZONE_COUNT = 10

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CONTENT = "content"
        private const val EXTRA_SUBTEXT = "subText"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_PAUSED = "paused"
        private const val EXTRA_SUCCESS = "success"

        /** 当前事件内第几句 / 总句数（冻结契约新增）：MediaSession 虚拟时间轴的数据源 */
        private const val EXTRA_SENTENCE_ORDINAL = "sentenceOrdinal"
        private const val EXTRA_SENTENCE_TOTAL = "sentenceTotal"

        private const val DEFAULT_PROGRESS_TITLE = "正在朗读大纲"
        private const val DEFAULT_FINISH_TITLE = "大纲朗读结束"

        /** 划掉 App 时显示：写明为什么停了，点一下还能回朗读页 */
        private const val INTERRUPTED_CONTENT =
            "朗读已停止（应用已关闭），点按重新打开后可重新开始"

        /** 前台服务超时时显示：措辞上和应用被关掉区分开，方便排查 */
        private const val TIMEOUT_CONTENT =
            "朗读已停止（后台运行超时），点按重新打开后可重新开始"

        private const val TAG = "DshOutlineListen"

        /**
         * 通知按钮的请求码：PendingIntent 的身份由「requestCode + Intent.filterEquals」决定，
         * 而 filterEquals **不比较 extras** —— 三个按钮的 Intent 只有 extra 不同，
         * 共用同一个 requestCode 会互相覆盖，导致点哪个按钮都触发同一个动作。
         */
        private const val REQUEST_CODE_ACTION_PREV = 730201
        private const val REQUEST_CODE_ACTION_TOGGLE = 730202
        private const val REQUEST_CODE_ACTION_STOP = 730203

        /**
         * 展开大视图里 10 个进度分区的请求码（730210..730219）与退/进 3 句的请求码。
         *
         * 为什么每个分区都要独立 requestCode + data：PendingIntent 的身份由
         * 「requestCode + Intent.filterEquals」决定，而 filterEquals **不比较 extras**；
         * 10 个分区的 Intent 只有 fraction extra 不同，共用 requestCode 会互相覆盖，
         * 点哪一格都跳同一个位置。这里 requestCode 不同、data URI 也不同（双保险），
         * 即使以后有人复制代码改错一处也不会串。
         */
        private const val REQUEST_CODE_SEEK_ZONE_BASE = 730210
        private const val REQUEST_CODE_REWIND = 730220
        private const val REQUEST_CODE_FORWARD = 730221

        /**
         * 展开大视图里自带的播控按钮请求码（EMUI 展开自定义大视图后不渲染通知 action 行，
         * 所以「上一个/暂停继续/停止」也要画进 RemoteViews）。同样每个按钮独立
         * requestCode + data URI，避免 PendingIntent 互相覆盖。
         */
        private const val REQUEST_CODE_EXPANDED_PREV = 730222
        private const val REQUEST_CODE_EXPANDED_TOGGLE = 730223
        private const val REQUEST_CODE_EXPANDED_STOP = 730224

        /** 分区广播的 data URI 前缀：deepseekapp://listen/seek/0 ... /9 */
        private const val SEEK_DATA_URI_PREFIX = "deepseekapp://listen/seek/"

        /** 退/进 3 句广播的 data URI（与系统 action 行用同一接收器，靠 data 区分身份） */
        private const val REWIND_DATA_URI = "deepseekapp://listen/action/rewind"
        private const val FORWARD_DATA_URI = "deepseekapp://listen/action/forward"

        /** 展开大视图播控按钮的 data URI（prev/toggle/stop 的语义与通知 action 行一致） */
        private const val EXPANDED_PREV_DATA_URI = "deepseekapp://listen/action/prev"
        private const val EXPANDED_TOGGLE_DATA_URI = "deepseekapp://listen/action/toggle"
        private const val EXPANDED_STOP_DATA_URI = "deepseekapp://listen/action/stop"

        /** 展开大视图中 10 个透明的进度分区 id（与 notification_listen_expanded.xml 一一对应） */
        private val SEEK_ZONE_IDS = intArrayOf(
            R.id.listen_seek_0,
            R.id.listen_seek_1,
            R.id.listen_seek_2,
            R.id.listen_seek_3,
            R.id.listen_seek_4,
            R.id.listen_seek_5,
            R.id.listen_seek_6,
            R.id.listen_seek_7,
            R.id.listen_seek_8,
            R.id.listen_seek_9,
        )

        /** 10 个分区里的滑块圆点 id（同序对应 SEEK_ZONE_IDS；圆点不接点击，点击穿透给父分区） */
        private val KNOB_IDS = intArrayOf(
            R.id.listen_knob_0,
            R.id.listen_knob_1,
            R.id.listen_knob_2,
            R.id.listen_knob_3,
            R.id.listen_knob_4,
            R.id.listen_knob_5,
            R.id.listen_knob_6,
            R.id.listen_knob_7,
            R.id.listen_knob_8,
            R.id.listen_knob_9,
        )

        /**
         * 计算进度条滑块圆点所在的档位（0..9，与 10 个点击分区同序）。
         *
         * 优先用「当前事件第几句 / 总句数」把句子线性等分到 10 档：第 1 句 = 0 档、
         * 最后一句 = 9 档（14 句时第 8 句 ≈ 5 档，9 句时第 5 句 = 5 档）；
         * 没有句信息（total <= 0）时退回通知的 progress 百分比（0~100 → 0~9 档）。
         * 用 round() 让「落在两档中间」的句子取最近的分区中心，视觉上更贴近真实位置。
         * 调用方还会用 `(bucket + 1) * 10` 作为展开视图进度条的填充值，让蓝条终点与
         * 圆点所在档位的右缘重合（滑块不再被进度条穿过）。
         */
        private fun expandedKnobBucket(
            sentenceOrdinal: Int,
            sentenceTotal: Int,
            progress: Int,
        ): Int {
            val bucket = when {
                sentenceTotal <= 0 -> {
                    // 没有句信息：用百分比兜底（100% → 9 档，50% → 5 档）
                    (progress.coerceIn(0, 100) / 100.0 * (SEEK_ZONE_COUNT - 1)).roundToInt()
                }
                sentenceTotal <= 1 -> 0
                else -> {
                    // 句子序号 1 起：先夹到 [1, total]，再映射成「第几句 / 总句数 → 0..9 档」
                    val ordinal = sentenceOrdinal.coerceIn(1, sentenceTotal)
                    ((ordinal - 1) * (SEEK_ZONE_COUNT - 1).toDouble() / (sentenceTotal - 1))
                        .roundToInt()
                }
            }
            // 双保险：任何异常输入都不至于去索引越界（10 个 knob 只有 0..9）
            return bucket.coerceIn(0, SEEK_ZONE_COUNT - 1)
        }

        /**
         * 服务是否在跑。只用于决定「startForegroundService 还是普通 startService」：
         * 同进程内由 Dart 侧保证调用顺序，够用；跨进程重建时进程内静态状态本来就归零。
         */
        @Volatile private var running = false

        /**
         * MainActivity 真正销毁（`isFinishing` 且非配置变更）时调用，见 [handleHostActivityDestroyed]。
         *
         * 为什么需要它：在本 App 里 Flutter 引擎是跟 Activity 同生共死的，Activity 一销毁，
         * Dart 的逐事件朗读循环就停了；但前台服务还在的话通知栏会永远停在「正在朗读」，
         * 用户以为后台还在读，实际上早就不会再有下一段了。
         *
         * 幂等：服务已经收过尾（running=false）就直接返回，finish/cancel 的终态通知不该被改坏。
         */
        fun hostActivityDestroyed(context: Context) {
            val app = context.applicationContext
            if (!running) return
            val intent = Intent(app, OutlineListenService::class.java).apply {
                action = ACTION_ACTIVITY_DESTROYED
            }
            try {
                // 服务此时正在前台，直接投递命令即可（App 有前台服务在跑，不受后台启动服务限制）；
                // 交给服务实例处理才能拿到它自己持有的 wakelock / foregroundActive 状态
                app.startService(intent)
            } catch (t: Throwable) {
                // 极端情况下命令投递不进去：至少把通知改成「已停止」，不能让「正在朗读」一直挂着
                Log.w(TAG, "Activity 销毁时投递服务命令失败，直接改通知", t)
                running = false
                postNotification(app, buildInterruptedNotification(app, INTERRUPTED_CONTENT))
            }
        }

        /**
         * 把 Dart 侧的通道调用转成服务命令（由 [OutlineListeningChannel] 调用）。
         *
         * 为什么按「服务在不在」分流：
         * - start / update 必须保证服务起来（通知要常驻），服务没跑就走 startForegroundService；
         * - finish / cancel 时如果服务已经不在（例如进程曾被回收），再拉一个服务毫无意义，
         *   还容易撞上「后台不允许启动服务」，直接操作通知即可，结果一样。
         */
        fun dispatch(
            context: Context,
            action: Action,
            title: String = "",
            content: String = "",
            subText: String = "",
            progress: Int = 0,
            paused: Boolean = false,
            success: Boolean = true,
            sentenceOrdinal: Int = 0,
            sentenceTotal: Int = 0,
        ) {
            val app = context.applicationContext
            val active = running
            if (action == Action.FINISH && !active) {
                postNotification(
                    app,
                    buildFinalNotification(app, title.ifBlank { DEFAULT_FINISH_TITLE }, content, success),
                )
                return
            }
            if (action == Action.CANCEL && !active) {
                notificationManager(app)?.cancel(NOTIFICATION_ID)
                return
            }
            val intent = Intent(app, OutlineListenService::class.java).apply {
                this.action = when (action) {
                    Action.START, Action.UPDATE -> ACTION_UPDATE_NOTIFICATION
                    Action.FINISH -> ACTION_FINISH
                    Action.CANCEL -> ACTION_CANCEL
                }
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CONTENT, content)
                putExtra(EXTRA_SUBTEXT, subText)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_PAUSED, paused)
                putExtra(EXTRA_SUCCESS, success)
                // start/update 才有句序信息；finish/cancel 传 0 也无所谓（服务不读）
                putExtra(EXTRA_SENTENCE_ORDINAL, sentenceOrdinal)
                putExtra(EXTRA_SENTENCE_TOTAL, sentenceTotal)
            }
            try {
                if (active) {
                    // 服务正在前台：直接投递新命令即可
                    app.startService(intent)
                } else {
                    // 乐观标记「服务要起来了」：紧接着到来的 cancel/finish 才会走 startService
                    // 按顺序投递给同一个服务，避免「刚取消，排队的 show 又把假通知挂上去」
                    running = true
                    startForegroundServiceCompat(app, intent)
                }
            } catch (t: Throwable) {
                // API 31+ 在后台启动前台服务会被系统拒绝（ForegroundServiceStartNotAllowedException），
                // 个别 ROM 还有服务配额限制。异常不能让 Dart 侧收到 PlatformException：
                // 朗读逻辑在 Flutter 那边照跑，最差退化成「只更新通知、没有前台服务保活」。
                Log.w(TAG, "启动朗读前台服务失败，退化为直接更新通知", t)
                running = false
                when (action) {
                    Action.START, Action.UPDATE -> postNotification(
                        app,
                        // 退化成普通通知：没有服务、没有 MediaSession，但通知内容/按钮/自定义大视图都在
                        buildProgressNotification(
                            app,
                            title.ifBlank { DEFAULT_PROGRESS_TITLE },
                            content,
                            subText,
                            progress,
                            paused,
                            sentenceOrdinal,
                            sentenceTotal,
                        ),
                    )
                    Action.FINISH -> postNotification(
                        app,
                        buildFinalNotification(app, title.ifBlank { DEFAULT_FINISH_TITLE }, content, success),
                    )
                    Action.CANCEL -> notificationManager(app)?.cancel(NOTIFICATION_ID)
                }
            }
        }

        private fun startForegroundServiceCompat(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                // API 24/25 没有 startForegroundService：
                // 普通 startService 之后在 onStartCommand 里立刻 startForeground 即可
                context.startService(intent)
            }
        }

        private fun notificationManager(context: Context): NotificationManager? =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

        private fun postNotification(context: Context, notification: Notification) {
            ensureNotificationChannel(context)
            notificationManager(context)?.notify(NOTIFICATION_ID, notification)
        }

        /** 通知渠道（API 26+）：低重要性 = 无提示音、不振动、不亮灯，只安静地显示朗读进度与播控 */
        private fun ensureNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            createChannelOnO(context)
        }

        @TargetApi(Build.VERSION_CODES.O)
        private fun createChannelOnO(context: Context) {
            val manager = notificationManager(context) ?: return
            // 已存在就别重复 create：重复建不会改用户改过的重要性，但白跑一次也没意义
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听大纲朗读",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "后台朗读大纲时显示朗读进度与播放控制"
                setShowBadge(false) // 朗读是持续状态，不该在桌面图标上冒角标
                enableVibration(false)
                enableLights(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        /**
         * 朗读中：**普通进度通知**（collapsed 由系统标准模板渲染）+ 自定义展开大视图
         * （[Notification.Builder.setCustomBigContentView]）+ 三个固定播控按钮。
         *
         * 为什么从 MediaStyle 退回普通样式：真机实测（Android 10 / EMUI）媒体通知模板不渲染
         * 系统 seekbar——MediaSession 的 state/position/duration 都正确，但通知媒体布局里根本没有
         * SeekBar；而且 MediaStyle 连普通 setProgress 的进度条也一起盖掉了（用户完全看不到进度）。
         * 所以 collapsed 恢复成「标题/正文/副文本/进度条/三个按钮」，展开态用自定义 RemoteViews
         * 提供「点进度条分区跳句 + 退/进 3 句」。
         *
         * 用 CATEGORY_TRANSPORT（播放/暂停类）而不是 PROGRESS：PROGRESS 在系统语义里是
         * 「下载/任务进度」，TRANSPORT 才贴合「媒体播放控制」，锁屏与通知栏更可能把它当播控处理。
         */
        private fun buildProgressNotification(
            context: Context,
            title: String,
            content: String,
            subText: String,
            progress: Int,
            paused: Boolean,
            sentenceOrdinal: Int,
            sentenceTotal: Int,
        ): Notification {
            // 暂停时把「暂停」按钮换成「继续」：图标与文案跟着 Dart 传进来的 paused 走，
            // 原生不自己猜播放状态，避免两边状态不一致时按钮显示错的图标
            val toggleIcon = if (paused) {
                android.R.drawable.ic_media_play
            } else {
                android.R.drawable.ic_media_pause
            }
            val toggleLabel = if (paused) "继续朗读" else "暂停"
            val builder = newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_listen)
                .setContentTitle(title)
                .setContentText(content)
                .setSubText(subText)
                // 普通通知的系统进度条：collapsed / 展开头部的标准模板都会显示它
                .setProgress(100, progress.coerceIn(0, 100), false)
                // ongoing：朗读没结束前不让用户划掉，否则容易让人以为朗读被顺手取消了
                .setOngoing(true)
                .setOnlyAlertOnce(true) // 每读一条都推一次进度，不能每次响/弹
                .setShowWhen(false) // 进度通知上显示「刚刚」没有意义
                .setCategory(Notification.CATEGORY_TRANSPORT)
                // 锁屏/媒体面板上要能完整看到朗读信息（不隐藏敏感内容，朗读内容本来就不敏感）
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setContentIntent(contentIntent(context))
                .setAutoCancel(false)
                .addAction(
                    buildNotificationAction(
                        context,
                        ACTION_PREV,
                        android.R.drawable.ic_media_previous,
                        "上一个事件",
                        REQUEST_CODE_ACTION_PREV,
                    ),
                )
                .addAction(
                    buildNotificationAction(
                        context,
                        ACTION_TOGGLE,
                        toggleIcon,
                        toggleLabel,
                        REQUEST_CODE_ACTION_TOGGLE,
                    ),
                )
                .addAction(
                    buildNotificationAction(
                        context,
                        ACTION_STOP,
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "停止",
                        REQUEST_CODE_ACTION_STOP,
                    ),
                )
            // 展开态：自定义大视图（标题/正文/副文本/进度条+滑块圆点 + 10 个透明点击分区
            // + 退/进 3 句 + 上一个/暂停继续/停止）。只设置 bigContentView，collapsed 仍走
            // 系统标准模板；EMUI 展开自定义视图后不再渲染系统 action 行，所以播控按钮自带一份。
            builder.setCustomBigContentView(
                buildExpandedRemoteViews(
                    context,
                    title,
                    content,
                    subText,
                    progress,
                    paused,
                    sentenceOrdinal,
                    sentenceTotal,
                ),
            )
            return builder.build()
        }

        /**
         * 构建展开态的自定义大视图（RemoteViews）。
         *
         * 为什么用 RemoteViews 而不是普通布局：通知由 SystemUI 进程渲染，只能通过 RemoteViews
         * 远程操作；布局里只能用系统白名单 View（见 notification_listen_expanded.xml 注释）。
         *
         * 展开视图里自带完整的交互：点标题/正文回朗读页、进度条 10 分区跳句 + 随句序移动的
         * 滑块圆点（视觉像可拖 slider，实际 Android 通知不支持真 SeekBar 拖动）、
         * 退/进 3 句、以及「上一个/暂停继续/停止」——真机（EMUI）把自定义大视图当完整展开内容，
         * 不会再渲染通知自带的 action 行，所以播控按钮必须在这里补一份。
         *
         * 每次 start/update 都重建一份：标题/正文/副文本/进度/暂停态/圆点档位都是动态的，
         * RemoteViews 是序列化后跨进程传输的，必须带着最新状态一起刷新（不能只构建一次）。
         */
        private fun buildExpandedRemoteViews(
            context: Context,
            title: String,
            content: String,
            subText: String,
            progress: Int,
            paused: Boolean,
            sentenceOrdinal: Int,
            sentenceTotal: Int,
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.notification_listen_expanded)
            views.setTextViewText(R.id.listen_expanded_title, title)
            views.setTextViewText(R.id.listen_expanded_content, content)
            views.setTextViewText(R.id.listen_expanded_subtext, subText)
            // 点标题/正文区域 = 回朗读页：复用通知主体那个「打开朗读页」的 PendingIntent
            //（同一个 open_outline_listening extra，MainActivity 不用为远程视图再开一条路）
            views.setOnClickPendingIntent(R.id.listen_expanded_text_area, contentIntent(context))
            // 滑块圆点（视觉 thumb）：RemoteViews 不支持真 SeekBar 拖动，用圆点表示「当前读到哪」。
            // 档位 0..9 与下方 10 个点击分区一一对应；每次 start/update（含暂停/继续）都重算，
            // 先全部 GONE 再只显示当前档位，避免上一次的圆点残留。
            val knobBucket = expandedKnobBucket(sentenceOrdinal, sentenceTotal, progress)
            for (index in 0 until SEEK_ZONE_COUNT) {
                views.setViewVisibility(
                    KNOB_IDS[index],
                    if (index == knobBucket) View.VISIBLE else View.GONE,
                )
            }
            // 展开视图的进度填充**按档位取整**（bucket 0..9 → 10%,20%,…,100%），
            // 与圆点「右边缘贴着分区右缘」的位置重合：蓝条终点正好落在圆点中心/右缘，
            // 不再出现「精确百分比越过滑块、蓝线穿过圆点」的观感。
            // 注意：collapsed 通知仍用精确 progress（见 buildProgressNotification 里的 setProgress），
            // 两处是分开的，不能共用同一个值。
            views.setProgressBar(
                R.id.listen_expanded_progress,
                100,
                (knobBucket + 1) * (100 / SEEK_ZONE_COUNT),
                false,
            )
            // 10 个等宽透明分区覆盖在进度条上：点第 i 格 = 跳到当前事件约 (i+0.5)/10 处。
            // 每个分区独立 PendingIntent（requestCode + data URI 都不同，见 REQUEST_CODE_SEEK_ZONE_BASE）
            for (index in 0 until SEEK_ZONE_COUNT) {
                val fraction = (index + 0.5) / SEEK_ZONE_COUNT
                views.setOnClickPendingIntent(
                    SEEK_ZONE_IDS[index],
                    seekFractionPendingIntent(context, index, fraction),
                )
                // 无障碍朗读也能知道点这一格会跳到哪（10 格各 10%）
                views.setContentDescription(
                    SEEK_ZONE_IDS[index],
                    "跳到约 ${(fraction * 100).toInt()}% 位置",
                )
            }
            views.setOnClickPendingIntent(
                R.id.listen_expanded_rewind,
                receiverPendingIntent(context, ACTION_REWIND, REWIND_DATA_URI, REQUEST_CODE_REWIND),
            )
            views.setOnClickPendingIntent(
                R.id.listen_expanded_forward,
                receiverPendingIntent(context, ACTION_FORWARD, FORWARD_DATA_URI, REQUEST_CODE_FORWARD),
            )
            // 展开视图自带的播控行（EMUI 展开后看不到系统 action 行）：
            // 中间按钮文字跟着 Dart 传来的 paused 联动（暂停中显示「继续」，播放中显示「暂停」），
            // 和 collapsed 通知中间那枚 action 的图标/文案语义一致。
            views.setTextViewText(
                R.id.listen_expanded_toggle,
                if (paused) "继续" else "暂停",
            )
            views.setOnClickPendingIntent(
                R.id.listen_expanded_prev,
                receiverPendingIntent(
                    context,
                    ACTION_PREV,
                    EXPANDED_PREV_DATA_URI,
                    REQUEST_CODE_EXPANDED_PREV,
                ),
            )
            views.setOnClickPendingIntent(
                R.id.listen_expanded_toggle,
                receiverPendingIntent(
                    context,
                    ACTION_TOGGLE,
                    EXPANDED_TOGGLE_DATA_URI,
                    REQUEST_CODE_EXPANDED_TOGGLE,
                ),
            )
            views.setOnClickPendingIntent(
                R.id.listen_expanded_stop,
                receiverPendingIntent(
                    context,
                    ACTION_STOP,
                    EXPANDED_STOP_DATA_URI,
                    REQUEST_CODE_EXPANDED_STOP,
                ),
            )
            return views
        }

        /** 单个进度分区的广播 PendingIntent：action=seek_fraction，extra fraction=(i+0.5)/10 */
        private fun seekFractionPendingIntent(
            context: Context,
            index: Int,
            fraction: Double,
        ): PendingIntent {
            val intent = Intent(context, OutlineListenActionReceiver::class.java).apply {
                action = ACTION_LISTEN
                putExtra(EXTRA_ACTION, ACTION_SEEK_FRACTION)
                putExtra(EXTRA_FRACTION, fraction)
                // data 让 filterEquals 把 10 个分区区分开（extras 不参与身份判定）
                data = Uri.parse("$SEEK_DATA_URI_PREFIX$index")
            }
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE_SEEK_ZONE_BASE + index,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        /** 展开大视图里「退 3 句 / 进 3 句」的广播 PendingIntent（action=rewind/forward） */
        private fun receiverPendingIntent(
            context: Context,
            actionValue: String,
            dataUri: String,
            requestCode: Int,
        ): PendingIntent {
            val intent = Intent(context, OutlineListenActionReceiver::class.java).apply {
                action = ACTION_LISTEN
                putExtra(EXTRA_ACTION, actionValue)
                data = Uri.parse(dataUri)
            }
            return PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        /** 朗读结束（读完 / 失败）：去掉进度条与播控按钮，可点回朗读页、可划掉 */
        private fun buildFinalNotification(
            context: Context,
            title: String,
            content: String,
            success: Boolean,
        ): Notification =
            newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_listen)
                .setContentTitle(title)
                .setContentText(content)
                .setShowWhen(false)
                // 成功用 STATUS、失败用 ERROR：系统在勿扰/锁屏等场景下对失败类通知更愿意提醒
                .setCategory(
                    if (success) Notification.CATEGORY_STATUS else Notification.CATEGORY_ERROR,
                )
                .setOngoing(false)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent(context))
                .build()

        /**
         * 朗读被中断（划掉 App / 前台服务超时 / Activity 退出）：
         * 保留一条可划掉的终态通知而不是直接移除 —— 用户从后台回来看到一条
         * 「朗读已停止」比「通知凭空消失」更清楚发生了什么，点它也能直接回朗读页重新开始。
         */
        private fun buildInterruptedNotification(context: Context, content: String): Notification =
            newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_listen)
                .setContentTitle("听大纲已停止")
                .setContentText(content)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_STATUS)
                .setOngoing(false)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent(context))
                .build()

        /**
         * 通知按钮：显式广播（组件固定指向 [OutlineListenActionReceiver]）+ 动作 extra。
         *
         * 这里用平台已标记 @Deprecated 的 `Builder(int icon, ...)` 重载而不是 Icon 版：
         * 三个按钮的图标来自 `android.R.drawable`（系统包），int 重载会按空包名解析，
         * 正好落在系统资源包里；换成 `Icon.createWithResource(context, ...)` 反而会让
         * 图标带上 App 包名，个别 ROM 上找不到资源、按钮图标变空白。
         */
        @Suppress("DEPRECATION")
        private fun buildNotificationAction(
            context: Context,
            action: String,
            iconRes: Int,
            title: String,
            requestCode: Int,
        ): Notification.Action {
            val intent = Intent(context, OutlineListenActionReceiver::class.java).apply {
                // action 与清单 intent-filter 逐字一致；组件已显式指定（exported=false 也能收到）
                this.action = ACTION_LISTEN
                putExtra(EXTRA_ACTION, action)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                // UPDATE_CURRENT：extra 取最新值；IMMUTABLE：Android 12+ 必须显式声明可变性
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return Notification.Action.Builder(iconRes, title, pendingIntent).build()
        }

        private fun newBuilder(context: Context): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                newBuilderOnO(context)
            } else {
                newBuilderLegacy(context)
            }

        /**
         * API 26+：带渠道的 Builder。
         *
         * 注意：平台 `Notification.Builder` 的「静音」由通知渠道保证：
         * IMPORTANCE_LOW + 渠道没设声音 + enableVibration(false)，再配合
         * setOnlyAlertOnce(true)，进度频繁更新时不会响铃、不振动、不重复弹提示。
         */
        @TargetApi(Build.VERSION_CODES.O)
        private fun newBuilderOnO(context: Context): Notification.Builder =
            Notification.Builder(context, CHANNEL_ID)

        /**
         * API 24/25：没有通知渠道，只能靠低优先级 + 显式清空声音来保持安静
         * （setSound(null) 是平台 Builder 的 API，保证这条通知本身不发声、不振动）
         */
        @Suppress("DEPRECATION")
        private fun newBuilderLegacy(context: Context): Notification.Builder =
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_LOW)
                .setSound(null)

        /**
         * 点通知主体 = 回「听大纲改名」页：拉起 MainActivity 并带一个一次性的 extra。
         * MainActivity 侧在 onCreate/onNewIntent 里把它转成 EventChannel 的 tap 事件
         * 或 pending 状态，交给 Dart 决定怎么跳页。
         */
        private fun contentIntent(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                // SINGLE_TOP：MainActivity 在栈顶时走 onNewIntent，不重建页面（朗读中的页面状态不会被重置）
                // CLEAR_TOP：栈里还压着别的页面时先清到 MainActivity，保证回来的是朗读页
                // NEW_TASK：从通知系统（非 Activity 上下文）启动时的标准写法；
                // 没有它，个别 ROM/场景下可能开出一个新的任务栈副本，点了通知却回不到原来的页面状态
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK
                putExtra(OutlineListeningChannel.EXTRA_OPEN_OUTLINE_LISTENING, true)
            }
            return PendingIntent.getActivity(
                context,
                // requestCode 用固定通知 id（=7302，契约固定值）：点通知主体永远复用同一个 PendingIntent，
                // 不会因为反复重建通知而堆出一串只响一次的 PendingIntent
                NOTIFICATION_ID,
                intent,
                // UPDATE_CURRENT：extra 取最新值；IMMUTABLE：Android 12+ 必须显式声明可变性
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
