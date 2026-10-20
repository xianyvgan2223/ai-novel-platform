package com.deepseek.deepseekapp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * 「听大纲改名」的**内置离线朗读**通道（sherpa-onnx + 中文 int8 模型）。
 *
 * 为什么需要它：有些手机（例如魅族 18 / Flyme）系统里**没有任何可用的「文字转语音」
 * 引擎**，系统 `TextToSpeech` 初始化必然失败——此时再好的提示也读不出声音。
 * 这条通道不依赖系统引擎：模型随 App 一起装好，进 App 后本地合成、本地播放。
 *
 * 与系统通道（[MainActivity] 里的 `deepseek_app/tts`）的分工：
 * - 系统引擎可用 → 仍然优先用系统（省内存、音色跟系统走）；
 * - 系统引擎不可用 → 页面自动回落到这条本地通道。
 *
 * 通道：方法 `deepseek_app/local_tts`，事件 `deepseek_app/local_tts/events`。
 * 事件格式与系统通道保持一致（{event: "done"|"error", message}），Dart 侧同一套回调。
 */
class LocalTtsChannel(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var tts: com.k2fsa.sherpa.onnx.OfflineTts? = null

    /** 正在准备模型 / 正在合成：用来避免重复初始化 */
    @Volatile private var preparing = false

    @Volatile private var ready = false

    @Volatile private var speaking = false

    /** 每次朗读一个自增号：停止 / 新请求都会让旧的失效（旧的不许再回 done） */
    private val speakSeq = AtomicInteger(0)

    @Volatile private var activeSeq = 0

    private var job: Job? = null

    private var track: AudioTrack? = null

    @Volatile private var error = ""

    /** 本机有没有内置模型（assets 里带没带）——没带就没这条兜底路 */
    fun hasModel(): Boolean = try {
        context.assets.open("$ASSET_DIR/$MODEL_FILE").close()
        true
    } catch (t: Throwable) {
        false
    }

    fun errorMessage(): String = error

    // ---- 通道注册 ----

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isReady" -> result.success(ready)
                "hasModel" -> result.success(hasModel())
                "init" -> {
                    if (ready) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    initAsync { ok -> result.success(ok) }
                }
                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    val speed = (call.argument<Double>("speed") ?: 1.0).toFloat()
                    if (!ready || text.isBlank()) {
                        if (!ready) error = "内置语音还没有准备好"
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    speakAsync(text, speed)
                    result.success(true)
                }
                "stop" -> {
                    stopSpeaking()
                    result.success(true)
                }
                "isSpeaking" -> result.success(speaking)
                else -> result.notImplemented()
            }
        }
    }

    /** 事件回调由 MainActivity 转进来（与系统通道共用一条事件通道） */
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    private fun emitDone() {
        val sink = eventSink ?: return
        val payload = HashMap<String, Any?>()
        payload["event"] = "done"
        payload["message"] = null
        sink.success(payload)
    }

    private fun emitError(message: String) {
        error = message
        val sink = eventSink
        if (sink != null) {
            val payload = HashMap<String, Any?>()
            payload["event"] = "error"
            payload["message"] = message
            sink.success(payload)
        }
    }

    // ---- 初始化（解包模型 + 建引擎）----

    private fun initAsync(done: (Boolean) -> Unit) {
        if (ready) {
            done(true)
            return
        }
        if (preparing) {
            // 已经在准备：等它结束再答复（简单轮询，准备过程只有几秒）
            scope.launch {
                var waited = 0
                while (preparing && waited < 300) {
                    kotlinx.coroutines.delay(100)
                    waited++
                }
                done(ready)
            }
            return
        }
        preparing = true
        job = scope.launch {
            try {
                val dir = ensureModel()
                val config = com.k2fsa.sherpa.onnx.OfflineTtsConfig(
                    model = com.k2fsa.sherpa.onnx.OfflineTtsModelConfig(
                        vits = com.k2fsa.sherpa.onnx.OfflineTtsVitsModelConfig(
                            model = File(dir, MODEL_FILE).absolutePath,
                            lexicon = File(dir, LEXICON_FILE).absolutePath,
                            tokens = File(dir, TOKENS_FILE).absolutePath,
                        ),
                        numThreads = 2,
                        debug = false,
                        provider = "cpu",
                    ),
                    maxNumSentences = 1,
                )
                // ⚠️ assetManager 必须传 null：模型是从 filesDir 读的**绝对路径**，
                // 再带 assetManager 会被原生层判为用法错误并直接中止（真机实测闪退：
                // "You are using an absolute path ... but assetManager is NOT set to null"）。
                val engine = com.k2fsa.sherpa.onnx.OfflineTts(
                    assetManager = null,
                    config = config,
                )
                tts = engine
                ready = true
                error = ""
                done(true)
            } catch (t: Throwable) {
                ready = false
                val message = t.message ?: t.javaClass.simpleName
                error = "内置语音初始化失败：$message"
                done(false)
            } finally {
                preparing = false
            }
        }
    }

    /**
     * 把 assets 里的模型解包到 filesDir。
     *
     * 为什么要解包：onnxruntime 要的是**真实文件路径**，而 assets 在 APK 里是压缩包内
     * 的条目，读不到路径。只在第一次（或版本变化）时解一次，之后直接用。
     */
    private fun ensureModel(): File {
        val dir = File(context.filesDir, "sherpa-tts")
        if (!dir.exists()) dir.mkdirs()
        // 版本标记：换模型时改这里，旧的会自动重解
        val stamp = File(dir, ".model-version")
        val version = MODEL_VERSION
        if (stamp.exists() && stamp.readText().trim() == version) return dir

        for (name in listOf(MODEL_FILE, TOKENS_FILE, LEXICON_FILE)) {
            val target = File(dir, name)
            context.assets.open("sherpa-tts/$name").use { input ->
                target.outputStream().use { output -> input.copyTo(output, bufferSize = 1 shl 16) }
            }
        }
        stamp.writeText(version)
        return dir
    }

    // ---- 朗读 ----

    /**
     * 逐句朗读：**一个线程合成、另一个线程播放**，两者并行。
     *
     * 为什么必须并行：VITS 是整段推理，低端机上合成比播放慢（实测约 0.14 秒/字，
     * 而正常语速播放约 0.25 秒/字），单线程「算一句 → 播一句」会在每句之间空等，
     * 听感是一顿一顿的。这里合成端把算好的 FloatArray 塞进有界队列，播放端持续
     * 往 AudioTrack 写，队列满时合成端自然被挡住（背压），内存也不会堆积。
     *
     * 另外：不用 `generateWithCallback`（真流式）——它要经 JNI 回调 Kotlin lambda，
     * 实测 ART 直接 abort（NoSuchMethodError: ...ExternalSyntheticLambda0.invoke）。
     */
    private fun speakAsync(text: String, speed: Float) {
        val seq = speakSeq.incrementAndGet()
        activeSeq = seq
        job?.cancel()
        job = scope.launch {
            val engine = tts
            if (engine == null) {
                emitError("内置语音还没有准备好")
                return@launch
            }
            speaking = true
            var audioTrack: AudioTrack? = null
            val queue = LinkedBlockingQueue<FloatArray>(QUEUE_CHUNKS)
            val t0 = System.currentTimeMillis()
            try {
                val sampleRate = engine.sampleRate()
                audioTrack = buildTrack(sampleRate)
                track = audioTrack
                audioTrack.play()
                val chunks = splitForSpeech(text)
                Log.i(TAG, "开始逐句朗读：${text.length} 字 / ${chunks.size} 句，语速 $speed")

                // 合成端：跑在另一个线程上，算完一段就交给队列
                val producer = scope.launch(Dispatchers.Default) {
                    try {
                        for ((index, chunk) in chunks.withIndex()) {
                            if (activeSeq != seq) break
                            val audio = engine.generate(chunk, SPEAKER_ID, speed.coerceIn(0.5f, 4.0f))
                            val samples = audio.samples
                            if (samples == null || samples.isEmpty()) continue
                            if (index == 0) {
                                Log.i(TAG, "第 1 句合成完成：${System.currentTimeMillis() - t0}ms")
                            }
                            queue.put(samples) // 队列满 → 在这里等播放端消费
                            // 标点停顿：不给停顿的话中文听起来是「一口气念完」。
                            // 逗号/顿号短停，句号问号叹号长停，换行也停一下。
                            val gapMs = pauseAfter(chunk)
                            if (gapMs > 0) {
                                Log.i(TAG, "停顿 ${gapMs}ms（上一句结尾：「${chunk.takeLast(1)}」）")
                                queue.put(silence(gapMs, sampleRate))
                            }
                        }
                    } finally {
                        // 结束标记：播放端据此收尾
                        queue.put(END_OF_SPEECH)
                    }
                }

                // 播放端（当前协程）：持续消费直到拿到结束标记
                var written = 0
                var firstPlayedAt = 0L
                while (true) {
                    if (activeSeq != seq) break
                    val samples = queue.take()
                    if (samples === END_OF_SPEECH) break
                    if (firstPlayedAt == 0L) {
                        firstPlayedAt = System.currentTimeMillis()
                        Log.i(TAG, "开始出声：${firstPlayedAt - t0}ms")
                    }
                    var offset = 0
                    while (offset < samples.size) {
                        if (activeSeq != seq) break
                        val n = minOf(8192, samples.size - offset)
                        val ok = audioTrack.write(samples, offset, n, AudioTrack.WRITE_BLOCKING)
                        if (ok <= 0) break
                        offset += ok
                        written += ok
                    }
                }
                producer.cancel()
                if (activeSeq != seq) return@launch
                if (written <= 0) {
                    emitError("内置语音没有合成出声音")
                    return@launch
                }
                Log.i(
                    TAG,
                    "播放结束：共 " + written + " 点，用时 " + (System.currentTimeMillis() - t0) + "ms（含首句合成等待）",
                )
                speaking = false
                emitDone()
            } catch (t: Throwable) {
                speaking = false
                Log.e(TAG, "内置语音播报失败", t)
                if (activeSeq == seq) {
                    emitError("内置语音播报失败：${t.message ?: t.javaClass.simpleName}")
                }
            } finally {
                runCatching { audioTrack?.stop() }
                runCatching { audioTrack?.release() }
                if (track === audioTrack) track = null
            }
        }
    }

    /**
     * 按标点把一段文本切成适合逐句合成的片段。
     *
     * 规则：在 `。！？；…` 等句末标点后断开；连续短句合并到 [MAX_CHUNK] 字左右，
     * 避免「一句一句」太碎（每句都要重新跑一次模型前向）。
     */
    private fun splitForSpeech(text: String): List<String> {
        val enders = "。！？!?；;\n"
        val out = mutableListOf<String>()
        val buf = StringBuilder()
        for (ch in text) {
            buf.append(ch)
            val isEnd = enders.indexOf(ch) >= 0
            if (isEnd || buf.length >= MAX_CHUNK) {
                val piece = buf.toString().trim()
                if (piece.isNotEmpty()) out.add(piece)
                buf.clear()
            }
        }
        val tail = buf.toString().trim()
        if (tail.isNotEmpty()) out.add(tail)
        return if (out.isEmpty()) listOf(text) else out
    }

    /**
     * 这一段读完该停多久（毫秒）。
     *
     * 为什么不靠文本里的标点让模型自己停：模型对这些符号的停顿很不稳定，
     * 实测听起来是「一口气念完」。这里在合成结果之间插入真正的静音，
     * 停顿长度按尾部标点决定，读起来才像正常朗读。
     */
    private fun pauseAfter(chunk: String): Int {
        val tail = chunk.trimEnd()
        if (tail.isEmpty()) return 0
        return when (tail.last()) {
            '。', '！', '？', '!', '?' -> 320
            '；', ';' -> 260
            '：', ':' -> 240
            '，', '、', ',', '—', '…' -> 180
            '\n' -> 200
            else -> 90 // 被字数上限切断的地方：给一点自然的换气
        }
    }

    /** 生成一段静音（采样点），用来做标点停顿 */
    private fun silence(ms: Int, sampleRate: Int): FloatArray =
        FloatArray((sampleRate.toLong() * ms / 1000L).toInt().coerceAtLeast(1))

    /** 建一条流式播放用的 AudioTrack（媒体音量、语音内容类型） */
    private fun buildTrack(sampleRate: Int): AudioTrack {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
        ).coerceAtLeast(sampleRate / 2)
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(minBuf)
            .build()
    }

    /** 停止朗读：作废当前序号（回调据此立刻收手）并放掉音频轨道 */
    private fun stopSpeaking() {
        activeSeq = speakSeq.incrementAndGet()
        speaking = false
        runCatching { track?.pause() }
        runCatching { track?.flush() }
        runCatching { track?.release() }
        track = null
        job?.cancel()
    }

    fun dispose() {
        stopSpeaking()
        runCatching { tts?.free() }
        tts = null
        ready = false
    }

    companion object {
        const val METHOD_CHANNEL = "deepseek_app/local_tts"

        /** 日志 TAG：内置语音的关键节点都打这个，真机排查直接 `adb logcat -s DshLocalTts` */
        const val TAG = "DshLocalTts"

        /** 模型放在 assets 的这个目录下（见 android/app/src/main/assets/sherpa-tts） */
        private const val ASSET_DIR = "sherpa-tts"

        /** 模型版本：换了模型文件就改这个值，App 会重新解包一次 */
        private const val MODEL_VERSION = "vits-zh-aishell3-int8-v1"

        private const val MODEL_FILE = "vits-aishell3.int8.onnx"
        private const val TOKENS_FILE = "tokens.txt"
        private const val LEXICON_FILE = "lexicon.txt"

        /**
         * 单个合成片段的字面上限。
         *
         * 低端机上 VITS 的耗时基本与字数成正比（实测约 0.14 秒/字），切到 24 字左右
         * 每片 3 秒上下；而同样长度播放要 5 秒左右 → **合成比播放快**，队列不会见底，
         * 听感才是连续的。片段再大就会「播完等合成」，再小则韵律变碎。
         */
        private const val MAX_CHUNK = 24

        /** 合成 → 播放 队列的容量（段）：满了就挡住合成端，避免内存堆积 */
        private const val QUEUE_CHUNKS = 4

        /** 队列里的结束标记 */
        private val END_OF_SPEECH = FloatArray(0)

        /**
         * 音色编号（AISHELL-3 是多发音人模型）。
         *
         * 21 是 sherpa-onnx 官方给的默认值（该模型 `--sid` 的默认就是 21）；
         * 用不到别的音色就先固定这一个，将来要在设置里做「内置音色」再把它开放出来。
         */
        private const val SPEAKER_ID = 21
    }
}
