package com.nikan.nikonsync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Flutter 桥接：
 *  - MethodChannel "nikonsync/engine"：指令（扫描/连接/枚举/下载/遥控…）
 *  - EventChannel "nikonsync/events"：日志、进度、相机事件、连接状态
 *
 * 阻塞型方法统一放到后台线程执行，结果回投主线程（平台通道要求）。
 */
object NikonsyncPlugin {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var executor: ExecutorService? = null
    private var activity: Activity? = null
    private var engineRef: FlutterEngine? = null
    private var pendingFolderResult: MethodChannel.Result? = null

    private const val REQ_PICK_FOLDER = 4201

    private fun prefs(context: Context) =
        context.getSharedPreferences("nikonsync", Context.MODE_PRIVATE)

    fun register(messenger: BinaryMessenger, context: Context, engine: FlutterEngine, activity: Activity?) {
        CameraEngine.init(context)
        this.activity = activity
        this.engineRef = engine
        executor = Executors.newCachedThreadPool()
        MethodChannel(messenger, "nikonsync/engine").setMethodCallHandler { call, result ->
            onMethodCall(call, result)
        }
        EventChannel(messenger, "nikonsync/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                CameraEngine.attachSink(events)
            }

            override fun onCancel(arguments: Any?) {
                CameraEngine.attachSink(null)
            }
        })
    }

    fun unregister(engine: FlutterEngine?) {
        activity = null
        engineRef = null
        executor?.shutdownNow()
        executor = null
        CameraEngine.attachSink(null)
    }

    /** SAF 目录选择结果（由 MainActivity.onActivityResult 转发） */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK_FOLDER) return false
        val cb = pendingFolderResult
        pendingFolderResult = null
        val act = activity
        if (cb != null && act != null) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                runCatching {
                    act.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
                prefs(act).edit().putString("save_tree", uri.toString()).apply()
                cb.success(uri.toString())
            } else {
                cb.success(null)
            }
        }
        return true
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ex = executor
        if (ex == null) {
            result.error("STATE", "插件未注册", null)
            return
        }
        when (call.method) {
            // 轻量方法直接在主线程执行
            "wifiInfo" -> result.success(CameraEngine.wifiInfo())
            "openWifiSettings" -> {
                runCatching { CameraEngine.openWifiSettings() }
                result.success(true)
            }
            "getSaveFolder" -> result.success(
                activity?.let { prefs(it).getString("save_tree", null) },
            )
            "clearSaveFolder" -> {
                activity?.let { prefs(it).edit().remove("save_tree").apply() }
                result.success(true)
            }
            "pickSaveFolder" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "无可用 Activity", null)
                    return
                }
                pendingFolderResult = result
                runCatching {
                    act.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_FOLDER)
                }.onFailure {
                    pendingFolderResult = null
                    result.error("PICK_FAILED", it.message, null)
                }
            }
            // 阻塞型方法放后台线程
            else -> ex.execute {
                try {
                    val r: Any? = when (call.method) {
                        "scan" -> CameraEngine.scan()
                        "connectSmart" -> CameraEngine.connectSmart()
                        "connect" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.connect(
                                ip = args["ip"] as String,
                                friendlyName = (args["friendlyName"] as? String)
                                    ?: CameraEngine.DEFAULT_FRIENDLY_NAME,
                            )
                        }
                        "disconnect" -> {
                            CameraEngine.disconnect()
                            true
                        }
                        "enumerate" -> CameraEngine.enumerate()
                        "listFolders" -> CameraEngine.listFolders()
                        "fileInfo" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.fileInfo((args["handle"] as Number).toLong())
                        }
                        "fileView" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.fileView((args["handle"] as Number).toLong())
                        }
                        "objectInfo" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.objectInfo(
                                (args["handles"] as List<*>).map { (it as Number).toLong() },
                            )
                        }
                        "getThumbnail" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.thumbnail((args["handle"] as Number).toLong())
                        }
                        "battery" -> CameraEngine.battery()
                        "capabilities" -> CameraEngine.capabilities()
                        "download" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.download(
                                (args["handle"] as Number).toLong(),
                                args["fileName"] as String,
                                (args["size"] as Number).toLong(),
                                (args["variant"] as? String) ?: CameraEngine.VARIANT_ORIGINAL,
                            )
                        }
                        "deleteObject" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.deleteObject((args["handle"] as Number).toLong())
                            true
                        }
                        "protectObject" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.protectObject(
                                (args["handle"] as Number).toLong(),
                                (args["protection"] as Number).toInt(),
                            )
                            true
                        }
                        "liveViewStart" -> CameraEngine.liveViewStart()
                        "liveViewStop" -> {
                            CameraEngine.liveViewStop()
                            true
                        }
                        "liveViewFrame" -> CameraEngine.liveViewFrame()
                        "capture" -> CameraEngine.capture()
                        "lvCapture" -> CameraEngine.lvCapture()
                        "afDrive" -> CameraEngine.afDrive()
                        "shotParams" -> CameraEngine.shotParams()
                        "probeHiSpeed" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.probeHiSpeed((args["handle"] as Number).toLong())
                        }
                        "probeResize" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.probeResize((args["handle"] as Number).toLong())
                        }
                        "probeLiveView" -> CameraEngine.probeLiveView()
                        "probeLiveView2" -> CameraEngine.probeLiveView2()
                        "probeLiveView5" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.probeLiveView5(
                                ((args?.get("handle") as? Number) ?: 0L).toLong(),
                            )
                        }
                        "probeLvAf" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.probeLvAf(((args?.get("handle") as? Number) ?: 0L).toLong())
                        }
                        "probeLiveView4" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.probeLiveView4(
                                ((args?.get("handle") as? Number) ?: 0L).toLong(),
                            )
                        }
                        "probeLiveView3" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.probeLiveView3(
                                ((args?.get("handle") as? Number) ?: 0L).toLong(),
                            )
                        }
                        "mediaThumb" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.mediaThumb(args["uri"] as String)
                        }
                        "mediaDelete" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.mediaDelete(args["uri"] as String)
                        }
                        "openMedia" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.openMedia(args["uri"] as String)
                        }
                        "fetchObject" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.fetchObject(
                                (args["handle"] as Number).toLong(),
                                (args["size"] as Number).toLong(),
                            )
                        }
                        "mediaBytes" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.mediaBytes(args["uri"] as String)
                        }
                        "findMediaByName" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.findMediaByName(args["name"] as String)
                        }
                        else -> throw IllegalArgumentException("未知方法 ${call.method}")
                    }
                    mainHandler.post { result.success(r) }
                } catch (e: Throwable) {
                    val msg = e.message ?: e.javaClass.simpleName
                    mainHandler.post { result.error("ENGINE_ERROR", msg, null) }
                }
            }
        }
    }
}
