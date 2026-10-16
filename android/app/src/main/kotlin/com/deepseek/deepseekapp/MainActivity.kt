package com.deepseek.deepseekapp

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

    /** 初始化结果：null = 还没结束（请求排队等待），true/false = 已就绪 / 失败 */
    private var initOk: Boolean? = null
    private val pendingInit = mutableListOf<MethodChannel.Result>()

    private var events: EventChannel.EventSink? = null

    /** 每条朗读请求一个自增 id：停止后到达的旧回调据此丢弃，不再冒泡成 done */
    private val utteranceSeq = AtomicInteger(0)

    /** 当前有效的 utterance id；stop / 新请求都会让旧的失效 */
    @Volatile private var activeUtteranceId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> ensureInit(result)
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
                    "isSpeaking" -> result.success(tts?.isSpeaking == true)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            })
    }

    // ---- 初始化 ----

    /** 懒初始化：第一次用到才建引擎，避免进 App 就抢音频焦点 / 占内存 */
    private fun ensureInit(result: MethodChannel.Result) {
        val current = initOk
        if (current != null) {
            result.success(current)
            return
        }
        if (tts != null) {
            // 引擎正在初始化：排队等 onInit 回来
            pendingInit.add(result)
            return
        }
        pendingInit.add(result)
        tts = TextToSpeech(applicationContext) { status ->
            val ok = status == TextToSpeech.SUCCESS
            val engine = tts
            if (ok && engine != null) {
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
            }
            initOk = ok
            val waiting = pendingInit.toList()
            pendingInit.clear()
            for (r in waiting) r.success(ok)
        }
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
        if (initOk != true || tts == null) {
            result.success(false)
            return
        }
        val engine = tts!!
        engine.setSpeechRate(if (rate in 0.1f..3.0f) rate else 1.0f)
        engine.setPitch(if (pitch in 0.1f..2.0f) pitch else 1.0f)

        // 语言不可用（设备没装对应语音包）时退回设备默认语言，而不是不读。
        // 个别设备在设置语言时会抛异常，这里兜住：读成默认语言也好过整条读不出来。
        val locale = Locale.forLanguageTag(language)
        val applied = try {
            engine.setLanguage(locale)
        } catch (e: Exception) {
            TextToSpeech.LANG_NOT_SUPPORTED
        }
        if (applied == TextToSpeech.LANG_MISSING_DATA ||
            applied == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            val fallback = try {
                engine.setLanguage(Locale.getDefault())
            } catch (e: Exception) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            if (fallback == TextToSpeech.LANG_MISSING_DATA ||
                fallback == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                result.success(false)
                return
            }
        }

        val utteranceId = "dsh-tts-${utteranceSeq.incrementAndGet()}"
        activeUtteranceId = utteranceId
        val queued = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (queued != TextToSpeech.SUCCESS) activeUtteranceId = null
        result.success(queued == TextToSpeech.SUCCESS)
    }

    /** 停止朗读：先让当前 utterance 失效，再 stop —— 停下来的那条不该回 done */
    private fun stopSpeaking() {
        activeUtteranceId = null
        tts?.stop()
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

    override fun onDestroy() {
        stopSpeaking()
        tts?.shutdown()
        tts = null
        initOk = null
        val waiting = pendingInit.toList()
        pendingInit.clear()
        for (r in waiting) r.success(false)
        super.onDestroy()
    }

    override fun onStop() {
        // 退到后台就停：继续读用户会以为 App 出了毛病（回来点播放即可续读）
        if (!isChangingConfigurations) stopSpeaking()
        super.onStop()
    }
}
