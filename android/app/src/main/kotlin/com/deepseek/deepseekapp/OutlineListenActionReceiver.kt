package com.deepseek.deepseekapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 「听大纲」通知栏播控按钮 / 展开大视图动作的广播接收器。
 *
 * 负责三类输入：
 * 1. 通知 action 行（SystemUI 渲染）：「上一个事件 / 暂停继续 / 停止」→ prev / toggle / stop；
 * 2. 通知展开大视图里的进度条分区：seek_fraction + fraction（0~1）→ 交给 Dart 换算成第几句；
 * 3. 展开大视图里的「退 3 句 / 进 3 句」：rewind / forward → action 事件。
 *
 * 为什么用广播而不是直接操作服务：怎么读只有 Dart 侧知道（该读第几条、从哪句继续、
 * 暂停时保留什么状态），原生只负责把「用户点了什么」转给 Dart（[OutlineListeningChannel]），
 * 由 Dart 决定下一句读什么。
 *
 * 权限上这个接收器 `exported=false`：只有本 App 自己的通知 PendingIntent 能触发它，
 * 外部 App 无法伪造播控指令。广播 Intent 在服务侧已经显式指定了组件。
 */
class OutlineListenActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        // 所有动作都放在契约约定的 "action" extra 里
        val action = intent?.getStringExtra(OutlineListenService.EXTRA_ACTION) ?: return
        when (action) {
            // 展开大视图：点了进度条上第 i 个分区。fraction 是当前事件内 0~1 的相对位置，
            // 先做有效性校验再转给 Dart（缺失/NaN 说明 PendingIntent 构造有问题，直接丢弃）
            OutlineListenService.ACTION_SEEK_FRACTION -> {
                val fraction = intent.getDoubleExtra(OutlineListenService.EXTRA_FRACTION, Double.NaN)
                if (fraction.isNaN()) {
                    Log.w(TAG, "seek_fraction 缺少有效的 fraction extra")
                    return
                }
                // deliverSeek 内部会再 clamp 到 0~1，并切主线程发 EventChannel 事件
                OutlineListeningChannel.deliverSeek(fraction)
            }
            // 展开大视图：退 / 进 3 句；以及通知 action 行 / 系统媒体面板的原有动作，原样转发
            OutlineListenService.ACTION_REWIND,
            OutlineListenService.ACTION_FORWARD,
            OutlineListenService.ACTION_PREV,
            OutlineListenService.ACTION_TOGGLE,
            OutlineListenService.ACTION_STOP,
            OutlineListenService.ACTION_PLAY,
            OutlineListenService.ACTION_PAUSE,
            OutlineListenService.ACTION_NEXT,
            -> OutlineListeningChannel.deliverAction(action)
            // 只认冻结契约里的动作值：别的 action 一律忽略，避免以后复用这条广播时误触发
            else -> Log.w(TAG, "收到未知的播控动作：$action")
        }
    }

    private companion object {
        const val TAG = "DshOutlineListenAction"
    }
}
