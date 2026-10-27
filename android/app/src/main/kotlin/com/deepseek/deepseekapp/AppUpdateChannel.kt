package com.deepseek.deepseekapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新通道：读取当前 versionCode、检查「安装未知应用」权限、调起 APK 安装器。
 *
 * Dart 侧（features/update/data/app_update_service.dart）只依赖四个方法：
 *   versionCode / canInstallPackages / openInstallPermission / installApk
 */
class AppUpdateChannel(private val context: Context) {

    private val channelName = "deepseek_app/update"

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "versionCode" -> result.success(currentVersionCode())
                "canInstallPackages" -> result.success(canInstallPackages())
                "openInstallPermission" -> {
                    try {
                        openInstallPermission()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_settings_failed", e.message ?: "打不开安装权限设置", null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "缺少 APK 路径", null)
                    } else {
                        try {
                            installApk(File(path))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message ?: "调起安装失败", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun currentVersionCode(): Long {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }

    private fun installApk(file: File) {
        require(file.exists()) { "APK 文件不存在" }
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }
}
