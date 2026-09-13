package com.nikan.nikonsync

import android.content.Intent
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        NikonsyncPlugin.onActivityResult(requestCode, resultCode, data)
    }
}
