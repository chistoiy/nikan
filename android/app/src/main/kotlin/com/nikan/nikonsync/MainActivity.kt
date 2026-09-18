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
}
