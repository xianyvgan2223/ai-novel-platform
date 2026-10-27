package com.deepseek.deepseekapp

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/**
 * 「听大纲改名」的离线朗读通道（纯系统 TTS，不依赖任何第三方插件 / 网络）。
 *
 * Flutter 侧只用到三件事：把一段文本读出来（speak）、立刻停下（stop）、
 * 当前是否正在读（isSpeaking）。读完 / 出错通过 [EventChannel]
 * （`deepseek_app/tts/events`）回一条 {event: "done"|"error"} ——
 * Dart 侧据此自动读下一条，所以这里**必须**保证每条 utterance 都有回音，
 * 否则播放会在中途「卡住不动」。
 *
 * 为什么不用 flutter_tts 之类的插件：本项目只依赖 sqflite / dio / riverpod 等，
 * 引一个带原生实现的新插件要动 Android 构建配置；而系统 TTS 的用法就这么点，
 * 自己写一个通道的维护面反而更小。
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "deepseek_app/tts"
    private val eventChannelName = "deepseek_app/tts/events"

    private var tts: TextToSpeech? = null

    /** 引擎状态：0 = 未建 / 失败可重建，1 = 正在初始化，2 = 已就绪 */
    @Volatile private var state = 0

    /** 当前绑定的是哪个引擎包名（null = 跟随系统默认）；设置里换引擎时用来判断要不要重建 */
    @Volatile private var boundEngine: String? = null

    private val initHandler = Handler(Looper.getMainLooper())

    /** 初始化超时兜底：个别设备/引擎既不回 SUCCESS 也不回 ERROR，
     *  没有它 Dart 侧的 `await init()` 会永远挂着（页面点播放毫无反应） */
    private var initTimeout: Runnable? = null

    private companion object {
        const val STATE_IDLE = 0
        const val STATE_INITIALIZING = 1
        const val STATE_READY = 2

        /** 等 onInit 的上限：真机上初始化是百毫秒级，8 秒足够 */
        const val INIT_TIMEOUT_MS = 8000L
    }

    /** 初始化结果：null = 还没结束（请求排队等待），true/false = 已就绪 / 失败 */
    private var initOk: Boolean? = null
    private val pendingInit = mutableListOf<MethodChannel.Result>()

    private var events: EventChannel.EventSink? = null

    /** 每条朗读请求一个自增 id：停止后到达的旧回调据此丢弃，不再冒泡成 done */
    private val utteranceSeq = AtomicInteger(0)

    /** 当前有效的 utterance id；stop / 新请求都会让旧的失效 */
    @Volatile private var activeUtteranceId: String? = null

    /** 内置离线朗读（sherpa-onnx）：系统没有 TTS 引擎时兜底，见 LocalTtsChannel */
    private var localTts: LocalTtsChannel? = null

    /** 应用内更新：读取 versionCode、调起 APK 安装器，见 AppUpdateChannel */
    private var appUpdate: AppUpdateChannel? = null

    /** 「一键生成大纲」的后台进度通道（前台服务 + 通知点击回传），见 OutlineBackgroundChannel */
    private var outlineBackground: OutlineBackgroundChannel? = null

    /** 「听大纲」的后台朗读通道（前台服务 + 通知播控 + 通知点击回传），见 OutlineListeningChannel */
    private var outlineListening: OutlineListeningChannel? = null

    /**
     * 退到后台后是否允许系统 TTS 继续朗读。
     *
     * 由 Dart 侧在读大纲播放/暂停时通过 TTS 通道的 `setBackgroundPlayback` 设置：
     * 播放中置 true，前台服务负责保活；暂停/退出页面置 false，恢复原来「退后台就停」的行为。
     * 其它页面不设置，保持默认 false，不会出现「退出大纲页还在念」的意外。
     */
    @Volatile private var backgroundPlayback = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 内置离线朗读通道：事件与系统通道共用同一条 EventChannel，
        // Dart 侧一套回调就能同时接住系统引擎与内置引擎的「读完了」
        localTts = LocalTtsChannel(applicationContext)
        localTts?.register(flutterEngine.dartExecutor.binaryMessenger)

        // 应用内更新通道：读 versionCode / 检查安装权限 / 调起安装器
        appUpdate = AppUpdateChannel(applicationContext)
        appUpdate?.register(flutterEngine.dartExecutor.binaryMessenger)

        // 大纲生成的后台通道：生成离开页面后继续跑、通知栏显示进度、点通知回到大纲页。
        // 和 TTS 通道一样挂在引擎上：引擎销毁时通道一起失效（Dart 侧也不可能再有生成回调）。
        outlineBackground = OutlineBackgroundChannel(this, this)
        outlineBackground?.register(flutterEngine.dartExecutor.binaryMessenger)

        // 「听大纲」后台朗读通道：朗读时把进度与播控钉在通知栏，退后台/锁屏后继续逐事件朗读。
        // 注册位置放在既有 TTS / generation 通道之后，不改动它们的任何行为。
        outlineListening = OutlineListeningChannel(this, this)
        outlineListening?.register(flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 设置面板里选的引擎（包名）会一起传进来；不传 = 跟随系统默认
                    "init" -> ensureInit(result, call.argument<String>("engine"))
                    "speak" -> speak(
                        call.argument<String>("text") ?: "",
                        call.argument<String>("language") ?: "zh-CN",
                        (call.argument<Double>("rate") ?: 1.0).toFloat(),
                        (call.argument<Double>("pitch") ?: 1.0).toFloat(),
                        result,
                    )
                    "stop" -> {
                        stopSpeaking()
                        result.success(true)
                    }
                    // 「听大纲」播放中由 Dart 置 true：退到后台时 onStop 不再停 TTS，
                    // 由 OutlineListenService 前台服务负责保活、通知栏提供暂停/继续/停止。
                    // 参数兼容「直接传 bool」与「传 {enabled: bool}」两种形态，
                    // 避免 Dart 侧写法不同就静默失效（这是跨语言契约里最容易踩的坑）。
                    "setBackgroundPlayback" -> {
                        backgroundPlayback = readBackgroundPlayback(call.arguments)
                        result.success(true)
                    }
                    "isSpeaking" -> result.success(tts?.isSpeaking == true)
                    // 换过系统「文字转语音」设置（装引擎 / 换发音人）后由页面调用：
                    // 先把旧引擎实例销毁，下一次 init 会重建，否则换了也听不出来
                    "reset" -> {
                        resetEngine()
                        result.success(true)
                    }
                    // 失败原因排查用：本机有几个引擎、默认引擎是谁、中文支持到什么程度
                    "diagnose" -> result.success(diagnose())
                    // 设置面板「朗读用哪个引擎」用：列出系统里装着的 TTS 引擎
                    "listEngines" -> result.success(systemEngines())
                    "defaultEngine" -> result.success(defaultEnginePackage())
                    // 直达系统「文字转语音」设置页（page 上的「去系统设置」按钮）
                    "openTtsSettings" -> result.success(
                        openSystemPage("com.android.settings.TTS_SETTINGS"),
                    )
                    // 拉起引擎自己的「下载语音数据」页：只在已有引擎但缺语音包时才有得解析
                    "installTtsData" -> result.success(
                        openSystemPage(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA),
                    )
                    // 本机根本没有语音引擎时（魅族这类精简 ROM 常见）：
                    // 手机上一键去应用商店搜「语音引擎」，装完回来重试。
                    // query 可覆盖搜索词，默认「语音引擎」
                    "openVoiceEngineStore" -> result.success(
                        openStoreSearch(call.argument<String>("query") ?: "语音引擎"),
                    )
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                    // 内置引擎的「读完了」也从这条通道回，Dart 侧不用再接第二条
                    localTts?.setEventSink(sink)
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                    localTts?.setEventSink(null)
                }
            })
    }

    // ---- 初始化 ----

    /** 懒初始化：第一次用到才建引擎，避免进 App 就抢音频焦点 / 占内存 */
    private fun ensureInit(result: MethodChannel.Result, enginePackage: String? = null) {
        // 只缓存「成功」。
        //
        // 旧实现把 false 也缓存下来（`if (current != null) return`），于是**一旦某次
        // 初始化失败，这个进程里的「重试」永远拿回同一个 false**：用户按页面提示去
        // 系统里装好 / 启用好语音引擎再回来点重试，照样一声音不吭，必须杀 App 重开
        // 才行（真机复现：停用引擎 → 报错 → 恢复引擎 → 点重试无任何 rebind，杀进程
        // 重开立刻恢复）。所以失败态一律不缓存，并顺手销毁失败的实例。
        if (state == STATE_READY && (enginePackage == null || enginePackage == boundEngine)) {
            result.success(true)
            return
        }
        // 用户在设置里换了引擎：先把旧实例丢掉，下面按新引擎重建
        if (enginePackage != null && enginePackage != boundEngine) {
            cancelInitTimeout()
            clearEngine()
            state = STATE_IDLE
            initOk = null
        }
        if (state == STATE_INITIALIZING) {
            // 引擎正在初始化：排队等 onInit 回来（超时会一起兜底答复）
            pendingInit.add(result)
            return
        }
        // 上一次失败留下的残骸先清掉，避免「tts 非空但没起来」被当成正在初始化
        clearEngine()
        pendingInit.add(result)
        startInit(enginePackage)
    }

    /** 真正建引擎。任何失败路径都必须回到 STATE_IDLE 并答复所有排队请求 */
    private fun startInit(enginePackage: String? = null) {
        state = STATE_INITIALIZING
        initOk = null
        // holder 而不是在回调里读字段：个别实现可能在构造返回前就回调 onInit，
        // 那时字段还没赋值，回调里拿到的会是 null（挂不上完成回调 → 读完不往下走）
        val holder = arrayOfNulls<TextToSpeech>(1)
        // 指定了引擎包名就用三参构造（TextToSpeech 的第三参就是引擎包名）；
        // 不指定（null）交给系统按「默认引擎」来挑
        val engine = if (enginePackage.isNullOrEmpty()) {
            TextToSpeech(applicationContext) { status -> handleInit(holder[0], status) }
        } else {
            TextToSpeech(applicationContext, { status -> handleInit(holder[0], status) }, enginePackage)
        }
        holder[0] = engine
        // 记录本次「绑的是哪个引擎」，供下次 init 判断是否需要重建
        boundEngine = enginePackage
        // 构造返回时回调已经处理完（成功或失败）就别再动 tts 了：
        // 覆盖回去会留下一个「没挂进度回调」的实例，甚至让下一次 init 永远排队
        if (state == STATE_INITIALIZING) tts = engine
        scheduleInitTimeout()
    }

    /** 等 onInit 超时：按失败处理，保证 Dart 侧不会一直 await 下去 */
    private fun scheduleInitTimeout() {
        cancelInitTimeout()
        val runnable = Runnable {
            if (state != STATE_INITIALIZING) return@Runnable
            finishInit(false)
        }
        initTimeout = runnable
        initHandler.postDelayed(runnable, INIT_TIMEOUT_MS)
    }

    private fun cancelInitTimeout() {
        initTimeout?.let { initHandler.removeCallbacks(it) }
        initTimeout = null
    }

    /** onInit 回来：成功就挂进度回调并置位，失败则销毁实例、保持「可重试」 */
    private fun handleInit(engine: TextToSpeech?, status: Int) {
        if (state != STATE_INITIALIZING) {
            // 已经超时判失败过了：这个迟到的回调不要再改状态
            runCatching { engine?.shutdown() }
            return
        }
        if (status == TextToSpeech.SUCCESS && engine != null) {
            // 读完 / 出错都要回事件；否则 Dart 侧不会自动读下一条
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit

                override fun onDone(utteranceId: String?) {
                    if (utteranceId == null || utteranceId != activeUtteranceId) return
                    activeUtteranceId = null
                    emit("done", null)
                }

                @Deprecated("系统 TTS 的旧回调，仍需实现")
                override fun onError(utteranceId: String?) {
                    if (utteranceId == null || utteranceId != activeUtteranceId) return
                    activeUtteranceId = null
                    emit("error", "朗读失败：系统语音引擎报错")
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    if (utteranceId == null || utteranceId != activeUtteranceId) return
                    activeUtteranceId = null
                    emit("error", "朗读失败（错误码 $errorCode）")
                }
            })
            tts = engine
            finishInit(true)
        } else {
            finishInit(false)
        }
    }

    /** 收尾：落状态、清定时器、答复所有排队请求（true/false 都从这里出去） */
    private fun finishInit(ok: Boolean) {
        cancelInitTimeout()
        if (ok) {
            state = STATE_READY
            initOk = true
        } else {
            state = STATE_IDLE
            initOk = null
            clearEngine()
        }
        val waiting = pendingInit.toList()
        pendingInit.clear()
        for (r in waiting) r.success(ok)
    }

    /** 丢掉引擎实例（失败残骸 / 换过系统设置 / 重试前都走这里） */
    private fun clearEngine() {
        val old = tts
        tts = null
        if (old != null) runCatching { old.shutdown() }
    }

    /** 销毁当前引擎实例，回到「未初始化」：重试 / 换过系统设置后都靠它 */
    private fun resetEngine() {
        cancelInitTimeout()
        stopSpeaking()
        state = STATE_IDLE
        initOk = null
        clearEngine()
        // 还挂着的请求（正常不该有）一起答复，别让 Dart 侧继续等
        val waiting = pendingInit.toList()
        pendingInit.clear()
        for (r in waiting) r.success(false)
    }

    /** 打开系统页面；本机没有对应页面时返回 false，由 Flutter 侧换一句话提示 */
    private fun openSystemPage(action: String): Boolean = try {
        startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: Exception) {
        false
    }

    /** 系统里装着的 TTS 引擎包名（设置面板「朗读用哪个引擎」用） */
    private fun systemEngines(): List<String> = try {
        packageManager.queryIntentServices(
            Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE),
            0,
        ).mapNotNull { it.serviceInfo?.packageName }.distinct()
    } catch (e: Exception) {
        emptyList()
    }

    /** 系统当前的默认引擎包名（可能为空） */
    private fun defaultEnginePackage(): String? = try {
        Settings.Secure.getString(contentResolver, "tts_default_synth")
    } catch (e: Exception) {
        null
    }

    /**
     * 跳到应用商店的**搜索页**（本机没有商店时返回 false）。
     *
     * 为什么要有这条路：App 不能替用户装引擎（Android 不允许静默安装 APK），
     * 但可以把用户送到商店搜索页——在手机上一键搜到、一键安装，不需要电脑与数据线。
     * 各家商店 scheme 不同（魅族 mstore / 通用 market），逐个试；
     * query 参数个别商店不认，不认就退回该商店首页（用户自己搜）。
     */
    private fun openStoreSearch(query: String): Boolean {
        val candidates = listOf(
            "mstore://search?keyword=" + Uri.encode(query), // 魅族应用商店
            "market://search?q=" + Uri.encode(query), // 通用（含各 ROM 自带商店）
            "mstore://", // 退到商店首页
            "market://",
        )
        for (uri in candidates) {
            try {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (intent.resolveActivity(packageManager) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (e: Exception) {
                // 这个 scheme 不行，试下一个
            }
        }
        return false
    }

    /** 本机语音引擎现状：给 Dart 侧拼可执行的提示文案用 */
    private fun diagnose(): Map<String, Any?> {
        // 引擎列表用 PackageManager 直接查，不依赖 tts 实例：
        // TextToSpeech.getEngines() 是**实例方法**，而诊断恰恰发生在实例建不起来的时候
        val engines = systemEngines()
        // 默认引擎同理走系统设置（Settings.Secure.TTS_DEFAULT_SYNTH 的字面量）
        val defaultEngine = defaultEnginePackage()
        // 中文可用性只能在引擎**真的绑定成功**时问：实例刚构造出来还没 onInit 时，
        // isLanguageAvailable 对任何语言都回 LANG_NOT_SUPPORTED，照它报就会在
        // 健康的机器上误报「不支持中文」（真机复现过，且那条提示是粘性的）
        val zhState = when {
            engines.isEmpty() -> "no_engine"
            state != STATE_READY || tts == null -> "unknown"
            else -> try {
                languageState(tts!!, Locale.forLanguageTag("zh-CN"))
            } catch (e: Exception) {
                "unknown"
            }
        }
        return mapOf(
            "engines" to engines,
            "default" to defaultEngine,
            "zhState" to zhState,
        )
    }

    private fun languageState(engine: TextToSpeech, locale: Locale): String =
        when (engine.isLanguageAvailable(locale)) { // API 14+，minSdk 24 可直接用
            TextToSpeech.LANG_MISSING_DATA -> "missing_data"
            TextToSpeech.LANG_NOT_SUPPORTED -> "not_supported"
            else -> "ok"
        }

    // ---- 朗读 ----

    private fun speak(
        rawText: String,
        language: String,
        rate: Float,
        pitch: Float,
        result: MethodChannel.Result,
    ) {
        val text = rawText.trim()
        if (text.isEmpty()) {
            result.success(false)
            return
        }
        // 引擎要真的绑定成功才算就绪：光有实例不算（失败残骸 / 还在初始化都不行）
        val engine = tts
        if (state != STATE_READY || engine == null) {
            // 带上原因：Dart 侧据此显示「没有引擎 / 引擎被停用 / 缺中文语音包」
            result.error("TTS_NOT_INIT", "语音引擎未就绪", null)
            return
        }
        // 语速上限放到 4.0，与设置面板档位对齐。
        // 注意：Android 官方建议的正常范围是 0.5–3.0，传 4.0 给系统引擎时
        // 有的引擎会自己夹到上限（那也正常，至少不是被我们这边悄悄改回 1.0）。
        engine.setSpeechRate(if (rate in 0.1f..4.0f) rate else 1.0f)
        engine.setPitch(if (pitch in 0.1f..2.0f) pitch else 1.0f)

        // 语言不可用（设备没装对应语音包）时退回设备默认语言，而不是不读。
        //
        // 注意先问 isLanguageAvailable 再 setLanguage：引擎一旦掉线，setLanguage 对
        // 任何语言都返回 LANG_NOT_SUPPORTED，直接照它报错会变成「不支持中文：请换一个
        // 支持中文的引擎」——真机上正是这条把用户引向了错误的方向（明明是引擎被停用）。
        val locale = Locale.forLanguageTag(language)
        val zhState = languageState(engine, locale)
        if (zhState != "ok") {
            val fallback = try {
                engine.setLanguage(Locale.getDefault())
            } catch (e: Exception) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            if (fallback == TextToSpeech.LANG_MISSING_DATA ||
                fallback == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                // 「引擎在、但没有中文语音数据」与「引擎不支持中文」是两件事，
                // 给用户的下一步动作也不同，所以分开回错误码
                val code = if (zhState == "missing_data") {
                    "TTS_LANG_MISSING_DATA"
                } else {
                    "TTS_LANG_NOT_SUPPORTED"
                }
                val message = if (zhState == "missing_data") {
                    "语音引擎缺少中文语音数据，请到「设置 → 文字转语音」的引擎设置里下载中文语音包"
                } else {
                    "当前语音引擎不支持中文，请到「设置 → 文字转语音」换一个支持中文的引擎"
                }
                result.error(code, message, null)
                return
            }
        } else {
            engine.setLanguage(locale)
        }

        val utteranceId = "dsh-tts-${utteranceSeq.incrementAndGet()}"
        activeUtteranceId = utteranceId
        val queued = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (queued != TextToSpeech.SUCCESS) activeUtteranceId = null
        if (queued != TextToSpeech.SUCCESS) {
            result.error("TTS_SYNTH_FAILED", "语音引擎拒绝了这次朗读", null)
            return
        }
        result.success(true)
    }

    /** 停止朗读：先让当前 utterance 失效，再 stop —— 停下来的那条不该回 done */
    private fun stopSpeaking() {
        activeUtteranceId = null
        tts?.stop()
    }

    /**
     * 解析 `setBackgroundPlayback` 的参数。
     *
     * 兼容两种形态：Dart 侧 `invokeMethod('setBackgroundPlayback', true)`（参数就是 bool）
     * 或 `invokeMethod(..., {'enabled': true})`。契约只冻结了方法名，参数形态由 Dart 实现决定，
     * 这里两种都认，任何一边先改都不会让「后台继续朗读」静默失效。认不出来按 false 处理（保守：退后台仍停）。
     */
    private fun readBackgroundPlayback(arguments: Any?): Boolean = when (arguments) {
        is Boolean -> arguments
        is Map<*, *> -> (arguments["enabled"] as? Boolean)
            ?: (arguments["value"] as? Boolean)
            ?: (arguments["backgroundPlayback"] as? Boolean)
            ?: false
        else -> false
    }

    private fun emit(event: String, message: String?) {
        val sink = events ?: return
        runOnUiThread {
            val payload = HashMap<String, Any?>()
            payload["event"] = event
            payload["message"] = message
            sink.success(payload)
        }
    }

    // ---- 生命周期 ----

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 通知点击拉起（冷启动）时 Intent 里带 open_outline_generation：
        // 此刻 Flutter 侧还没开始监听事件，交给 OutlineBackgroundChannel 记成 pending，
        // Dart 启动后用 consumeLaunchTap 消费。
        // savedInstanceState 非空 = 配置变更重建，同一份 intent 会被系统再投递一次，
        // 不能当成新的点击（否则处理完又被拉回大纲页）。
        // 放在 super.onCreate 之后：平台消息在 onCreate 这个主线程消息处理完之后才会派发，
        // Dart 不可能抢在 handleLaunchIntent 之前调 consumeLaunchTap。
        if (savedInstanceState == null) {
            OutlineBackgroundChannel.handleLaunchIntent(intent)
            // 同理：「听大纲」朗读通知点击拉起时带 open_outline_listening，
            // 交给 OutlineListeningChannel 记成 pending / 直接发 tap 事件（两条通道各有各的 extra）
            OutlineListeningChannel.handleLaunchIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // App 已在运行时点通知走这里：extra 只处理一次，handleLaunchIntent 内部会清掉它
        setIntent(intent)
        OutlineBackgroundChannel.handleLaunchIntent(intent)
        OutlineListeningChannel.handleLaunchIntent(intent)
    }

    override fun onDestroy() {
        // 真正退出 App（返回键退出 / 系统回收），不是横竖屏等配置变更：
        // Flutter 引擎跟着一起销毁，Dart 侧的生成循环已经停了，但前台服务还在的话
        // 通知栏会永远停在「生成中」。让服务按「已中断」收尾（释放 wakelock、退出前台）。
        // 只动通知与前台服务，生成数据仍留在 Dart/本地，重新打开后可从「继续上次」恢复。
        if (isFinishing && !isChangingConfigurations) {
            OutlineGenerationService.hostActivityDestroyed(applicationContext)
            // 「听大纲」朗读同理：Activity 真正退出后 Dart 的逐事件循环停了，前台服务不能
            // 继续挂「正在朗读」——按「已停止」收尾（保留可划掉的终态通知、释放 wakelock）
            OutlineListenService.hostActivityDestroyed(applicationContext)
        }
        // 通道跟着引擎一起失效：摘掉事件回调，避免之后还有通知点击/播控往已销毁的引擎发事件
        outlineBackground?.dispose()
        outlineBackground = null
        outlineListening?.dispose()
        outlineListening = null
        backgroundPlayback = false
        cancelInitTimeout()
        stopSpeaking()
        localTts?.dispose()
        localTts = null
        clearEngine()
        state = STATE_IDLE
        initOk = null
        val waiting = pendingInit.toList()
        pendingInit.clear()
        for (r in waiting) r.success(false)
        super.onDestroy()
    }

    override fun onStop() {
        // 退到后台默认停 TTS：继续读用户会以为 App 出了毛病（回来点播放即可续读）。
        // 但「听大纲」播放中 Dart 会把 backgroundPlayback 置 true：此时朗读要继续
        //（前台服务保活 + 通知栏播控），由 onDestroy 兜底停止，避免退出 App 后还在念。
        if (!isChangingConfigurations && !backgroundPlayback) stopSpeaking()
        super.onStop()
    }
}
