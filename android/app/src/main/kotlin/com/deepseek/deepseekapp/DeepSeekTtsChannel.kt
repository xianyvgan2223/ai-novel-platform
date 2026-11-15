package com.deepseek.deepseekapp

import android.media.MediaPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * DeepSeek TTS 的播放通道：Flutter 负责请求官方 TTS 并把 WAV 写到缓存文件，
 * 原生侧只负责播放这个文件，并用 EventChannel 回报「读完 / 出错」。
 *
 * 不依赖任何第三方音频插件，避免再引入一套 Android 构建链。
 */
class DeepSeekTtsChannel(messenger: BinaryMessenger) {

    private val methodChannel = MethodChannel(messenger, "deepseek_app/deepseek_tts")
    private val eventChannel = EventChannel(messenger, "deepseek_app/deepseek_tts/events")

    private var player: MediaPlayer? = null
    private var eventSink: EventChannel.EventSink? = null

    fun register() {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val path = call.argument<String>("path")
                    val speed = (call.argument<Double>("speed") ?: 1.0)
                        .coerceIn(0.75, 4.0)
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "缺少音频文件路径", null)
                    } else {
                        play(path, speed.toFloat(), result)
                    }
                }
                "stop" -> {
                    stop()
                    result.success(true)
                }
                "isPlaying" -> result.success(player?.isPlaying == true)
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    private fun play(path: String, speed: Float, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists()) {
            result.error("file_missing", "音频文件不存在", null)
            return
        }
        stop()
        try {
            val mp = MediaPlayer()
            player = mp
            mp.setDataSource(path)
            mp.setOnPreparedListener {
                try {
                    // API 23+：DeepSeek 返回的是 WAV，交给系统按播放速率变速，
                    // 这样 4x 语速不只是 UI 选项，实际音频也会加速。
                    it.playbackParams = it.playbackParams.setSpeed(speed)
                } catch (_: Exception) {
                    // 个别设备/格式不支持变速时仍按 1x 播放，不阻断朗读。
                }
                it.start()
            }
            mp.setOnCompletionListener {
                emitDone()
                releasePlayer()
            }
            mp.setOnErrorListener { _, what, extra ->
                emitError("原生播放失败（$what/$extra）")
                releasePlayer()
                true
            }
            mp.prepareAsync()
            result.success(true)
        } catch (e: Exception) {
            releasePlayer()
            result.error("play_failed", e.message ?: "播放失败", null)
        }
    }

    private fun stop() {
        val mp = player
        player = null
        try {
            mp?.stop()
        } catch (_: Exception) {
        }
        try {
            mp?.release()
        } catch (_: Exception) {
        }
    }

    private fun releasePlayer() {
        val mp = player
        player = null
        try {
            mp?.release()
        } catch (_: Exception) {
        }
    }

    private fun emitDone() {
        val payload = HashMap<String, Any?>()
        payload["event"] = "done"
        eventSink?.success(payload)
    }

    private fun emitError(message: String) {
        val payload = HashMap<String, Any?>()
        payload["event"] = "error"
        payload["message"] = message
        eventSink?.success(payload)
    }
}
