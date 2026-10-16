plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.deepseek.deepseekapp"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.deepseek.deepseekapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 「听大纲改名」的内置离线朗读走 sherpa-onnx（本地合成，不依赖系统 TTS 引擎）。
        // 只打这两个 ABI：手机上没有 x86，带上 x86/x86_64 会白白多出 50MB 原生库。
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // AAR 放在 app/libs 下（sherpa-onnx 原生库 + JNI/Java API）
    packaging {
        jniLibs {
            // 原生库直接映射，不再解压释放，省安装体积也避免旧版解压路径问题
            useLegacyPackaging = false

            // 只留手机用得到的两个 ABI。
            //
            // 注意：`defaultConfig.ndk.abiFilters` 拦不住 AAR 里带的原生库
            // （它只影响我们自己编的东西），必须在这里显式排掉——否则 AAR 里的
            // x86 / x86_64 会一起打进包，实测多出 80MB 上下，纯属浪费。
            excludes += setOf(
                "lib/x86/**",
                "lib/x86_64/**",
                "**/libx86/**",
                "**/libx86_64/**",
            )
        }
    }

    buildTypes {
        release {
            // ⚠️⚠️ 不要改这个签名配置！⚠️⚠️
            //
            // 现在用的是本机 `~/.android/debug.keystore`（CN=Android Debug，
            // 证书 SHA-256 = 1fe397221e1ec36ebf1b943bf764d3348bc63393e32a9f967d43a81dd9904daf）。
            //
            // 为什么不能随便换：
            // - Android 要求「更新包的签名必须与已安装包一致」，不一致会拒绝覆盖安装；
            // - 一旦走「卸载重装」这条路，**用户的全部数据（小说 / 聊天记录 / 设置）会被一起删掉**。
            //   2026-10-16 就这么丢过一次数据，最后靠项目里的备份库才恢复。
            //
            // 如果要用正式（release）签名对外发布，请**一次性定好**并从此不变：把 keystore 与
            // 口令固定下来（keystore 文件要备份 + 跟着仓库走），换签名前必须通知用户先导出数据。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(files("libs/sherpa-onnx-1.13.8.aar"))
    // 内置离线朗读（LocalTtsChannel）在后台线程做「解包模型 / 合成 / 播放」，
    // 用协程比裸线程好收尾（停止朗读时要能取消）
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
