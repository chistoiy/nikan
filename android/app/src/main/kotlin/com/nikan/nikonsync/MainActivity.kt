package com.nikan.nikonsync

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NikonsyncPlugin.register(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
            flutterEngine,
            this,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        NikonsyncPlugin.unregister(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * 插入相机时的冷启动路径：Manifest 声明了 USB_DEVICE_ATTACHED 的 intent-filter，
     * 系统会带着该 Intent 拉起本 Activity——此前完全没处理，表现是
     * "插上线，App 自己开了，然后什么都不做"。现在转发给插件（连接页会据此切到 USB 模式）。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NikonsyncPlugin.onUsbAttachIntent(intent)
    }

    /** 应用已在后台时插入相机走这里。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        NikonsyncPlugin.onUsbAttachIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        NikonsyncPlugin.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * 运行时权限的结果**必须**转发给插件。
     *
     * 本插件是手工注册的（不走 Flutter 生成的注册表），所以引擎的
     * `onRequestPermissionsResult` 分发到不了它——此前完全没转发，
     * 结果是"授权框弹了，但没人知道用户选了什么"，Dart 只能轮询权限位去猜，
     * 用户犹豫几秒就被判成失败（真机踩过）。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        NikonsyncPlugin.onPermissionResult(requestCode, permissions, grantResults)
    }
}
