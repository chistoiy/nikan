package com.nikan.nikonsync

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
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
    private var appContext: Context? = null
    private var engineRef: FlutterEngine? = null
    private var pendingFolderResult: MethodChannel.Result? = null

    private const val REQ_PICK_FOLDER = 4201
    private const val REQ_POST_NOTIFICATIONS = 4202

    private fun prefs(context: Context) =
        context.getSharedPreferences("nikonsync", Context.MODE_PRIVATE)

    /** 最近一次 USB 接入的设备名。事件可能在事件通道建立之前就发出并丢失，故同时留一份供查询。 */
    @Volatile private var lastUsbAttachName: String? = null

    /**
     * 处理"插入 USB 相机把应用拉起"的 Intent。
     *
     * Manifest 里声明了 `USB_DEVICE_ATTACHED` 的 intent-filter（配合 device_filter.xml 的
     * VID=0x1200），所以插上线系统会把本应用拉起来——但此前**没有任何代码处理这个 Intent**，
     * 用户看到的是"插上相机、App 自己开了、然后什么都不做"，很容易以为坏了。
     *
     * 这里把它变成一条事件：连接页据此自动切到 USB 模式并给出提示。
     */
    fun onUsbAttachIntent(intent: Intent?) {
        if (intent == null || intent.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        @Suppress("DEPRECATION")
        val dev = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE) as? UsbDevice
        val label = dev?.productName ?: "USB 相机"
        lastUsbAttachName = label
        Log.d("NikonSync", "USB 设备接入：$label（VID=${dev?.vendorId} PID=${dev?.productId}）")
        CameraEngine.emitRaw(mapOf("type" to "usbAttached", "name" to label))
    }

    /**
     * 申请通知权限（仅 Android 13+ 需要，POST_NOTIFICATIONS 是 API 33 引入的）。
     *
     * 必须由主线程调用：平台通道的轻量分支本来就在主线程，所以直接放在那里。
     * 返回 true = 已有权限或不需要；false = 已弹出系统授权框，结果由用户决定。
     */
    private fun requestNotificationPermission(): Boolean {
        val act = activity ?: return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (act.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        return runCatching {
            act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
            false
        }.getOrDefault(true) // 申请动作本身失败就当作"不需要"，不让上层因此报错
    }

    fun register(messenger: BinaryMessenger, context: Context, engine: FlutterEngine, activity: Activity?) {
        CameraEngine.init(context)
        this.activity = activity
        this.appContext = context.applicationContext
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
            // 取消必须**直通主线程**、不能进下面的工作线程池：池里的任务会排在正在跑的
            // 那笔下载后面，等排到它时文件早传完了，等于没取消。取消的价值全在"立刻"。
            // 只设置一个 volatile 标志，不阻塞，因此放主线程也是安全的。
            "cancelDownload" -> result.success(CameraEngine.cancelDownload())
            // 通知权限（Android 13+）。Manifest 里早就声明了，但代码从没运行时申请过——
            // 结果是保活前台服务的通知在 13+ 上**完全不可见**，用户不知道后台在跑。
            // 返回 true = 已有权限或不需要；false = 已弹出系统授权框，结果待定。
            "requestNotificationPermission" -> result.success(requestNotificationPermission())
            // 查询"是否有 USB 相机刚接入"：插入时系统拉起应用那一刻事件通道可能还没建立，
            // 事件会丢，所以连接页初始化时主动查一次。
            "lastUsbAttach" -> result.success(lastUsbAttachName)
            "clearUsbAttach" -> {
                lastUsbAttachName = null
                result.success(true)
            }
            // 应用版本：读实际安装的包信息（AGP 8 起 BuildConfig 默认不生成，
            // 且这样拿到的是真正生效的版本，不会与 pubspec 失同步）
            "appVersion" -> {
                val ctx = appContext
                result.success(
                    runCatching {
                        val info = ctx!!.packageManager.getPackageInfo(ctx.packageName, 0)
                        "${info.versionName} (${info.longVersionCode})"
                    }.getOrNull(),
                )
            }
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
                        "connectUsb" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.connectUsb(
                                (args["friendlyName"] as? String)
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
                        "storageInfo" -> CameraEngine.storageInfo()
                        "previewBytes" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.previewBytes(
                                (args["handle"] as Number).toLong(),
                                (args["quality"] as? String) ?: "medium",
                            )
                        }
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
                        "liveViewRestart" -> CameraEngine.liveViewRestart()
                        "liveViewStop" -> {
                            CameraEngine.liveViewStop()
                            true
                        }
                        "liveViewFrame" -> CameraEngine.liveViewFrame()
                        "capture" -> CameraEngine.capture()
                        "lvCapture" -> CameraEngine.lvCapture()
                        "afDrive" -> CameraEngine.afDrive()
                        "afArea" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.afArea(
                                (args["x"] as Number).toInt(),
                                (args["y"] as Number).toInt(),
                            )
                        }
                        "shotParams" -> CameraEngine.shotParams()
                        "setShotParam" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.setShotParam(
                                args["name"] as String,
                                (args["value"] as Number).toLong(),
                            )
                        }
                        "probeProps" -> CameraEngine.probeProps()
                        "probeHiSpeed" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.probeHiSpeed((args["handle"] as Number).toLong())
                        }
                        // 无线链路基准测速：会把整个文件真传一遍（耗时同一次下载），
                        // 所以要留在工作线程；数据丢弃、不落盘。
                        "probeLinkThroughput" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.probeLinkThroughput((args["handle"] as Number).toLong())
                        }
                        "probeResize" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.probeResize((args["handle"] as Number).toLong())
                        }
                        "probeLiveView" -> CameraEngine.probeLiveView()
                        "probeLvFrames" -> CameraEngine.probeLvFrames()
                        // USB 连接模式 U0 实验（见 docs/USB连接方案.md）：
                        // 会等用户点一次系统授权弹窗，最长 60s，必须留在工作线程
                        "usbProbe" -> {
                            val ctx = appContext ?: throw IllegalStateException("插件未注册")
                            PtpUsbProbe.run(ctx) { CameraEngine.log(it) }
                        }
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
                        // 取景对焦坐标标定：帧尺寸由 Dart 侧传入（它才知道当前取景帧多大）
                        "probeAfArea" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.probeAfArea(
                                ((args?.get("frameW") as? Number) ?: 0).toInt(),
                                ((args?.get("frameH") as? Number) ?: 0).toInt(),
                            )
                        }
                        "probeSleep" -> CameraEngine.probeSleep()
                        // 自动对焦倍数（从取景帧头部解出的相机图像尺寸 ÷ 取景帧尺寸）
                        "afScaleFromHeader" -> CameraEngine.afScaleFromHeader()
                        // 取景帧头部完整 dump（384B，找实时 ISO 用）
                        "probeLvHeader" -> CameraEngine.probeLvHeader()
                        // 实时 ISO 发现（差分法，约 15 秒；期间请对着明暗变化处让 Auto ISO 动起来）
                        "probeLiveIso" -> CameraEngine.probeLiveIso()
                        // 防待机"戳一下"（实验）：DeviceReady + 重发上次对焦点，无副作用
                        "pokeActivity" -> CameraEngine.pokeActivity()
                        // 遥控期间保持相机屏幕常亮（可写 MonitorOff/MeterOff，退出时还原）
                        "keepAwake" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.keepAwake(args?.get("enable") != false)
                        }
                        // 息屏后尝试唤醒（DeviceReady），返回是否应答
                        "wakeUp" -> CameraEngine.wakeUp()
                        // Dart 侧写一行到 logcat：release 包里 UI 层日志原本无处可查
                        "logToNative" -> {
                            val args = call.arguments as? Map<*, *>
                            CameraEngine.logFromDart(args?.get("line")?.toString() ?: "")
                            true
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
                        // 带进度的在线取原图（不落盘）：大图页「显示原图」在
                        // "不保存到本地"设置下走这里，进度事件让 UI 能显示真实百分比
                        "fetchOriginal" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.fetchOriginal(
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
                    // 原生侧记一笔失败原因：download() 内部没有 catch，异常直接穿过这里
                    // 回到 Dart，此前 logcat 里对"下载中途失败"完全没有痕迹（真机踩过）。
                    //
                    // 高频方法（取景帧）必须限流：相机退出取景时它每秒失败 8 次，
                    // 实测能把 logcat 缓冲整个冲掉，反而丢失真正有用的日志。
                    if (shouldLogMethodFailure(call.method)) {
                        CameraEngine.log("✗ 方法 ${call.method} 失败：$msg")
                    }
                    if (e !is PtpException) {
                        Log.w("NikonSync", "方法 ${call.method} 异常", e)
                    }
                    mainHandler.post { result.error("ENGINE_ERROR", msg, null) }
                }
            }
        }
    }

    /** 方法名 → 上次失败日志时间戳（仅高频方法需要限流） */
    private val methodFailLogAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private fun shouldLogMethodFailure(method: String): Boolean {
        if (!HIGH_FREQ_METHODS.contains(method)) return true
        val now = SystemClock.elapsedRealtime()
        val prev = methodFailLogAt[method] ?: 0L
        if (now - prev < FAIL_LOG_MIN_GAP_MS) return false
        methodFailLogAt[method] = now
        return true
    }

    /** 会被上层以每帧一次的频率调用的方法 */
    private val HIGH_FREQ_METHODS = setOf("liveViewFrame")

    private const val FAIL_LOG_MIN_GAP_MS = 5_000L
}
