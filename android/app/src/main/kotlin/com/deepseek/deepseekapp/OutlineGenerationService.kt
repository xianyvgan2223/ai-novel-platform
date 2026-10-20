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
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * 「一键生成大纲」的后台前台服务：生成过程钉在通知栏显示实时进度，点通知回到大纲页。
 *
 * 为什么必须是前台服务：生成逻辑仍然在 Dart 侧（网络流式请求、解析都在那边），但页面一关、
 * 或用户切到后台再锁屏，普通后台线程随时会被系统挂起，进度就会「停在 37% 再也不动」。
 * 前台服务是 Android 允许在后台长期运行、并且**必须**显示一条通知的组件，正好对应
 * 「离开 App 也继续生成 + 通知栏实时进度」这个需求。
 *
 * 数据流：Dart 每次推进度调 MethodChannel（见 [OutlineBackgroundChannel]）→ 这里只负责
 * 更新 / 收尾通知，不关心生成内容是怎么来的；生成结束（成功或失败）由 Dart 调 finish。
 *
 * 状态同步约定：同进程内由 Dart 侧保证 start → update… → finish/cancel 的顺序，
 * 所以「服务是否在跑」用一个静态标志（[running]）就够，不做跨进程持久化。
 */
class OutlineGenerationService : Service() {

    /** 是否已经调用过 startForeground：决定后续 update 是「notify 刷新」还是「先升级为前台」 */
    @Volatile private var foregroundActive = false

    private var notificationManager: NotificationManager? = null

    /** 生成期间持有的 CPU 锁（见 [acquireWakeLock]）；finish / cancel / 销毁时必须释放 */
    private var wakeLock: PowerManager.WakeLock? = null

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
            ACTION_SHOW -> showOrUpdate(
                title = intent.getStringExtra(EXTRA_TITLE) ?: DEFAULT_PROGRESS_TITLE,
                content = intent.getStringExtra(EXTRA_CONTENT) ?: "",
                subText = intent.getStringExtra(EXTRA_SUBTEXT) ?: "",
                progress = intent.getIntExtra(EXTRA_PROGRESS, 0),
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
        // 不用 START_STICKY：进度完全由 Dart 侧驱动，进程被系统杀掉后没人会接着推进度，
        // 系统重新拉起服务只会留下一条永远不动的「生成中」通知
        return Service.START_NOT_STICKY
    }

    // ---- 命令处理 ----

    /** Dart 侧的命令（冻结契约里的 start/update/finish/cancel），内部再映射成 Intent action */
    enum class Action { START, UPDATE, FINISH, CANCEL }

    /** START / UPDATE：第一次先升级为前台服务，之后都是同 id 静默刷新通知 */
    private fun showOrUpdate(title: String, content: String, subText: String, progress: Int) {
        running = true
        // 先拿到 CPU 锁：锁屏后没有它，Dart 那条流式请求可能被系统挂起
        acquireWakeLock()
        val notification = buildProgressNotification(this, title, content, subText, progress)
        if (foregroundActive) {
            // 同 id notify 就是「原地替换」：不响铃、不闪、不重复弹出（配合 setOnlyAlertOnce）
            notificationManager?.notify(NOTIFICATION_ID, notification)
            return
        }
        try {
            startForegroundCompat(notification)
            foregroundActive = true
            Log.i(TAG, "前台服务已启动：$title（$progress%）")
        } catch (t: Throwable) {
            // 极少数 ROM / 服务配额场景下 startForeground 会抛异常；不能让 App 直接崩，
            // 退化成普通通知更新（Dart 侧生成照跑，只是失去前台服务保活）
            Log.e(TAG, "startForeground 失败，退化为普通通知", t)
            notificationManager?.notify(NOTIFICATION_ID, notification)
        }
    }

    /** FINISH：通知改成最终态并保留在通知栏，然后退出前台、释放资源 */
    private fun finishWithNotification(title: String, content: String, success: Boolean) {
        // 先把同 id 通知替换成最终态，再从「前台通知」降级为普通通知（DETACH 会保留它），
        // 这样用户还能点通知回页面看详情
        notificationManager?.notify(NOTIFICATION_ID, buildFinalNotification(this, title, content, success))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        running = false
        stopSelf()
        Log.i(TAG, "生成结束：$title（success=$success）")
    }

    /** CANCEL：用户主动取消生成，通知要立刻消失（不能像 finish 那样留着） */
    private fun cancelAndStop() {
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            foregroundActive = false
        }
        notificationManager?.cancel(NOTIFICATION_ID)
        releaseWakeLock()
        running = false
        stopSelf()
        Log.i(TAG, "生成已取消，通知与服务都已移除")
    }

    // ---- 生命周期兜底 ----

    /**
     * Activity 真正销毁（返回键退出 App 等，由 [hostActivityDestroyed] 转投递进来）：
     * Flutter 引擎已经跟着 Activity 销毁，Dart 侧的生成循环停了，服务不能再挂着「生成中」。
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
        running = false
        stopSelf()
        Log.i(TAG, "Activity 已销毁（退出 App），生成按「已中断」收尾")
    }

    /**
     * 用户从最近任务里划掉 App：Flutter 引擎随 Activity 一起销毁，Dart 侧的生成循环不会再有后续。
     *
     * 如果不管，服务仍停在前台，通知栏就会永远挂着一条「正在生成」的假通知（用户点开发现没在生成）。
     * 所以这里把通知改成「已中断」提示（非 ongoing、可点、可划掉），并主动释放前台身份与 CPU 锁。
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
        running = false
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /**
     * API 35+：dataSync 类型的前台服务累计跑满系统允许的时长后，系统会回调这里（超时上限由系统定，
     * 目前约 6 小时 / 24 小时）。不处理的默认行为是直接停服务，通知栏却还留着「生成中」，
     * 因此和划掉任务一样按「已中断」收尾；反正生成也不会再继续了。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (!running) {
            stopSelf(startId)
            return
        }
        Log.w(TAG, "前台服务超时（fgsType=$fgsType），按生成已中断收尾")
        notificationManager?.notify(NOTIFICATION_ID, buildInterruptedNotification(this, TIMEOUT_CONTENT))
        if (foregroundActive) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
            foregroundActive = false
        }
        releaseWakeLock()
        running = false
        stopSelf(startId)
    }

    override fun onDestroy() {
        // 走到这里还没释放，说明服务是被系统意外销毁的（内存紧张 / 被强停）：
        // 兜底释放 CPU 锁，绝不能让它泄漏（锁屏后一直亮着 CPU 会明显耗电）
        if (foregroundActive) {
            // 非正常结束：把「生成中」通知撤掉，避免留下一条永远不动的假进度
            runCatching { stopForeground(Service.STOP_FOREGROUND_REMOVE) }
            foregroundActive = false
        }
        releaseWakeLock()
        running = false
        notificationManager = null
        super.onDestroy()
    }

    // ---- 前台服务 / CPU 锁 ----

    /** API 29+ 的 startForeground 要显式带上前台服务类型（与清单里的 dataSync 保持一致） */
    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * 拿一把 PARTIAL_WAKE_LOCK：只保 CPU 不休眠、不亮屏。
     *
     * 为什么需要它：生成是「网络流式请求 + 解析」，用户很可能按下电源键把手机放兜里；
     * 没有这把锁，屏幕一灭 CPU 很快休眠，流式连接会被挂住甚至断掉，表现就是进度卡住不动。
     * finish / cancel / onTaskRemoved / onTimeout / onDestroy 都会释放。
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

    companion object {
        /** 通知渠道 id（固定值：渠道一旦建好，用户改过的重要性会被系统记住，不能随意换 id） */
        const val CHANNEL_ID = "outline_generation_progress"

        /** 固定通知 id：进度、完成、中断都用这一条，Dart 侧不需要知道它 */
        const val NOTIFICATION_ID = 7301

        /** wakelock tag：真机排查时 `adb shell dumpsys power | findstr outline` 能看到 */
        private const val WAKE_LOCK_TAG = "deepseekapp:outline_generation"

        private const val ACTION_SHOW = "com.deepseek.deepseekapp.outline.SHOW"
        private const val ACTION_FINISH = "com.deepseek.deepseekapp.outline.FINISH"
        private const val ACTION_CANCEL = "com.deepseek.deepseekapp.outline.CANCEL"

        /** Activity 真正退出（非划掉任务）时由 MainActivity.onDestroy 投递，用来把「生成中」通知收尾 */
        private const val ACTION_ACTIVITY_DESTROYED = "com.deepseek.deepseekapp.outline.ACTIVITY_DESTROYED"

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CONTENT = "content"
        private const val EXTRA_SUBTEXT = "subText"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_SUCCESS = "success"

        private const val DEFAULT_PROGRESS_TITLE = "正在生成大纲"
        private const val DEFAULT_FINISH_TITLE = "大纲生成完成"

        /** 划掉 App 时显示：告诉用户任务没完成，但重新打开还能续上 */
        private const val INTERRUPTED_CONTENT =
            "生成已中断（应用已关闭），点按重新打开后可从「继续上次」恢复"

        /** 前台服务超时时显示：措辞上和应用被关掉区分开，方便排查 */
        private const val TIMEOUT_CONTENT =
            "生成已中断（后台运行超时），点按重新打开后可从「继续上次」恢复"

        private const val TAG = "DshOutlineService"

        /**
         * 服务是否在跑。只用于决定「startForegroundService 还是普通 startService」：
         * 同进程内由 Dart 侧保证调用顺序，够用；跨进程重建时进程内静态状态本来就归零。
         */
        @Volatile private var running = false

        /**
         * MainActivity 真正销毁（`isFinishing` 且非配置变更）时调用，见 [handleHostActivityDestroyed]。
         *
         * 为什么需要它：在本 App 里 Flutter 引擎是跟 Activity 同生共死的，Activity 一销毁，
         * Dart 侧的生成循环就停了；但前台服务还在的话通知栏会永远停在「生成中」，
         * 用户以为后台还在跑，实际上早就不会再有进度了。
         *
         * 幂等：服务已经收过尾（running=false）就直接返回，finish/cancel 的终态通知不该被改坏。
         */
        fun hostActivityDestroyed(context: Context) {
            val app = context.applicationContext
            if (!running) return
            val intent = Intent(app, OutlineGenerationService::class.java).apply {
                action = ACTION_ACTIVITY_DESTROYED
            }
            try {
                // 服务此时正在前台，直接投递命令即可（App 处于前台服务状态，不受后台启动服务限制）；
                // 交给服务实例处理才能拿到它自己持有的 wakelock / foregroundActive 状态
                app.startService(intent)
            } catch (t: Throwable) {
                // 极端情况下命令投递不进去：至少把通知改成「已中断」，不能让「生成中」一直挂着
                Log.w(TAG, "Activity 销毁时投递服务命令失败，直接改通知", t)
                running = false
                postNotification(app, buildInterruptedNotification(app, INTERRUPTED_CONTENT))
            }
        }

        /**
         * 把 Dart 侧的通道调用转成服务命令（由 [OutlineBackgroundChannel] 调用）。
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
            success: Boolean = false,
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
            val intent = Intent(app, OutlineGenerationService::class.java).apply {
                this.action = when (action) {
                    Action.START, Action.UPDATE -> ACTION_SHOW
                    Action.FINISH -> ACTION_FINISH
                    Action.CANCEL -> ACTION_CANCEL
                }
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CONTENT, content)
                putExtra(EXTRA_SUBTEXT, subText)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_SUCCESS, success)
            }
            try {
                if (active) {
                    // 服务正在前台：直接投递新命令即可（App 处于前台服务状态，不受后台启动限制）
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
                // 生成逻辑在 Flutter 那边照跑，最差退化成「只更新通知、没有前台服务保活」。
                Log.w(TAG, "启动大纲生成前台服务失败，退化为直接更新通知", t)
                running = false
                when (action) {
                    Action.START, Action.UPDATE -> postNotification(
                        app,
                        buildProgressNotification(
                            app,
                            title.ifBlank { DEFAULT_PROGRESS_TITLE },
                            content,
                            subText,
                            progress,
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

        /** 通知渠道（API 26+）：低重要性 = 无提示音、不振动、不亮灯，只安静地显示进度 */
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
                "大纲生成进度",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "后台生成大纲时显示实时进度"
                setShowBadge(false) // 进度是持续状态，不该在桌面图标上冒角标
                enableVibration(false)
                enableLights(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        /** 生成中：不可划掉、只响一次、带进度条 */
        private fun buildProgressNotification(
            context: Context,
            title: String,
            content: String,
            subText: String,
            progress: Int,
        ): Notification =
            newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_outline)
                .setContentTitle(title)
                .setContentText(content)
                .setSubText(subText)
                // indeterminate=false：这是「已生成百分比」，不是转圈动画
                .setProgress(100, progress.coerceIn(0, 100), false)
                // ongoing：生成没结束前不让用户划掉，否则容易让人以为生成被取消了
                .setOngoing(true)
                .setOnlyAlertOnce(true) // 每秒都推一次进度，不能每次响/弹
                .setShowWhen(false) // 进度通知上显示「刚刚」没有意义
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setContentIntent(contentIntent(context))
                .setAutoCancel(false)
                .build()

        /** 生成结束（成功/失败）：去掉进度条，可点详情、可划掉 */
        private fun buildFinalNotification(
            context: Context,
            title: String,
            content: String,
            success: Boolean,
        ): Notification =
            newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_outline)
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

        /** 生成被中断（划掉 App / 前台服务超时）：告诉用户还能从「继续上次」恢复 */
        private fun buildInterruptedNotification(context: Context, content: String): Notification =
            newBuilder(context)
                .setSmallIcon(R.drawable.ic_stat_outline)
                .setContentTitle("大纲生成已中断")
                .setContentText(content)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_STATUS)
                .setOngoing(false)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent(context))
                .build()

        private fun newBuilder(context: Context): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                newBuilderOnO(context)
            } else {
                newBuilderLegacy(context)
            }

        /**
         * API 26+：带渠道的 Builder。
         *
         * 注意：平台 `Notification.Builder` **没有** setSilent 方法（那是 androidx 的
         * NotificationCompat.Builder 才有的，本项目不引入 androidx.core），
         * 这里的「静音」由通知渠道保证：IMPORTANCE_LOW + 渠道没设声音 + enableVibration(false)，
         * 再配合 setOnlyAlertOnce(true)，进度频繁更新时不会响铃、不振动、不重复弹提示。
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
         * 点通知 = 回「一键生成大纲」页：拉起 MainActivity 并带一个一次性的 extra。
         * MainActivity 侧在 onCreate/onNewIntent 里把它转成 EventChannel 的 tap 事件
         * 或 pending 状态，交给 Dart 决定怎么跳页。
         */
        private fun contentIntent(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                // SINGLE_TOP：MainActivity 在栈顶时走 onNewIntent，不重建页面（生成中的页面状态不会被重置）
                // CLEAR_TOP：栈里还压着别的页面时先清到 MainActivity，保证回来的是大纲页
                // NEW_TASK：从通知系统（非 Activity 上下文）启动时的标准写法；
                // 没有它，个别 ROM/场景下可能开出一个新的任务栈副本，点了通知却回不到原来的页面状态
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK
                putExtra(OutlineBackgroundChannel.EXTRA_OPEN_OUTLINE_GENERATION, true)
            }
            return PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                intent,
                // UPDATE_CURRENT：extra 取最新值；IMMUTABLE：Android 12+ 必须显式声明可变性
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
