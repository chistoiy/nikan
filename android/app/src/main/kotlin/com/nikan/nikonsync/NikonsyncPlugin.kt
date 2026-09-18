package com.nikan.nikonsync

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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

    /** 扫描附近 Wi-Fi 的权限请求码（13+ = NEARBY_WIFI_DEVICES，否则 ACCESS_FINE_LOCATION） */
    private const val REQ_WIFI_SCAN = 4203

    /**
     * 扫描权限的申请状态。
     *
     * 为什么要在原生侧自己记：系统的"是否已问过用户"只能靠
     * `shouldShowRequestPermissionRationale` 间接推断，而这个值在
     * "从没问过"和"拒绝两次（不再弹框）"两种情况下**都是 false**——
     * 单看它无法区分，必须配合"我们是否真的发起过请求"。
     *
     * 真机踩过的坑：Dart 侧原本靠"轮询 3.6 秒看权限有没有变成 granted"来判断，
     * 用户在授权框上多看一眼就超时了，于是被判定为失败并弹"去设置授权"，
     * 而权限其实**从没被问过**（`dumpsys` 里 NEARBY_WIFI_DEVICES 没有 USER_SET 标志）。
     */
    @Volatile private var wifiPermAsked = false

    /** 用户是否明确拒绝过（由系统的 onRequestPermissionsResult 回调写入） */
    @Volatile private var wifiPermDenied = false

    private fun prefs(context: Context) =
        context.getSharedPreferences("nikonsync", Context.MODE_PRIVATE)

    /** 最近一次 USB 接入的设备名。事件可能在事件通道建立之前就发出并丢失，故同时留一份供查询。 */
    @Volatile private var lastUsbAttachName: String? = null

    /** 运行时注册的 USB 插拔广播接收器（见 registerUsbReceiver） */
    private var usbReceiver: BroadcastReceiver? = null

    /**
     * 运行时注册 USB 插拔广播。
     *
     * 为什么不能只靠清单里的 intent-filter：那是"冷启动/被系统拉起"的路径，
     * 只有在用户把本应用选为 USB 默认处理程序时才会送到；App 已经在前台时
     * 更是常常什么都不发生。动态注册的接收器在进程存活期间必定收到。
     */
    private fun registerUsbReceiver(ctx: Context) {
        if (usbReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                        @Suppress("DEPRECATION")
                        val dev = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE) as? UsbDevice
                        val label = dev?.productName ?: CameraEngine.usbCameraPresent() ?: "USB 相机"
                        lastUsbAttachName = label
                        CameraEngine.log("USB 接入（动态广播）：$label")
                        CameraEngine.emitRaw(mapOf("type" to "usbAttached", "name" to label))
                    }
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        lastUsbAttachName = null
                        CameraEngine.log("USB 拔出（动态广播）")
                        CameraEngine.emitRaw(mapOf("type" to "usbDetached"))
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        usbReceiver = r
        // 系统广播对 NOT_EXPORTED 的接收器仍然可达（只有跨应用广播会被挡），
        // 13+ 必须显式给标志；低版本 API 不认这个重载，退回两参版本。
        runCatching { ctx.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED) }
            .onFailure { runCatching { ctx.registerReceiver(r, filter) } }
    }

    private fun unregisterUsbReceiver(ctx: Context?) {
        val r = usbReceiver ?: return
        usbReceiver = null
        runCatching { ctx?.unregisterReceiver(r) }
    }

    /**
     * 处理"插入 USB 相机把应用拉起"的 Intent。
     *
     * Manifest 里声明了 `USB_DEVICE_ATTACHED` 的 intent-filter（配合 device_filter.xml 的
     * VID=0x1200），所以插上线系统会把本应用拉起来——但此前**没有任何代码处理这个 Intent**，
     * 用户看到的是"插上相机、App 自己开了、然后什么都不做"，很容易以为坏了。
     *
     * ⚠️ 这条路**在多数 ROM 上并不可靠**：只有当用户把本应用选为"默认处理程序"时，
     * 插入的 Intent 才会送进来；否则系统弹一个选择框或干脆不投（真机 HyperOS 就不投）。
     * 所以另配了两条：[usbReceiver]（运行时动态广播）与 [CameraEngine.usbCameraPresent]
     * （主动查 `UsbManager.deviceList`）。
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

    /**
     * 申请"扫描附近 Wi-Fi"所需的运行时权限。
     * 13+ 用 NEARBY_WIFI_DEVICES（Manifest 里已声明，注意本项目带 neverForLocation）
     * 10~12 用 ACCESS_FINE_LOCATION（Manifest 里 maxSdkVersion=32）。
     *
     * 返回一个**状态字符串**（而不是布尔）：调用方需要知道"是不是真的弹框了"，
     * 以及"是不是已经问过两次、系统不再弹框"——两者的后续处理完全不同。
     * - `granted`    : 已有权限，可以直接扫描
     * - `asked`      : 授权框已弹出，等用户在框上作答
     * - `blocked`    : 已问过且被拒，系统不再弹框 → 只能引导去应用设置
     * - `no-activity`: 拿不到 Activity（极罕见），无法弹框
     * - `error`      : 调用 requestPermissions 抛异常
     */
    private fun requestWifiScanPermission(): String {
        val act = activity ?: return "no-activity"
        val perm = wifiScanPermission()
        if (act.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED) {
            wifiPermDenied = false
            return "granted"
        }
        // 已经问过一次、且系统认为"不必再解释" → 说明用户选了不再询问（或拒了两次）。
        // 此时再调 requestPermissions 不会弹框，会直接回调失败——别让用户白等。
        if (wifiPermAsked && !act.shouldShowRequestPermissionRationale(perm)) {
            CameraEngine.log("扫描权限：system 不再弹框（已拒绝过），需去应用设置手动开")
            return "blocked"
        }
        return runCatching {
            CameraEngine.log("扫描权限：发起系统授权框（$perm）")
            act.requestPermissions(arrayOf(perm), REQ_WIFI_SCAN)
            wifiPermAsked = true
            wifiPermDenied = false
            "asked"
        }.getOrElse { e ->
            CameraEngine.log("扫描权限：requestPermissions 失败：${e.message}")
            "error"
        }
    }

    private fun wifiScanPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }

    /**
     * 权限状态查询：`granted` / `denied` / `pending`。
     *
     * Dart 侧靠它等待用户在系统框上作答，而不是"数着秒数猜超时"。
     */
    fun wifiPermissionState(): String = when {
        CameraEngine.hasWifiScanPermission() -> "granted"
        wifiPermDenied -> "denied"
        else -> "pending"
    }

    /**
     * 系统授权框的结果回调（由 MainActivity 转发）。
     *
     * ⚠️ 之前**完全没有这个转发**：`requestPermissions` 弹了框，但结果没人接，
     * Dart 只能轮询 `checkSelfPermission` 猜——用户犹豫几秒就被判失败。
     */
    fun onPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != REQ_WIFI_SCAN) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        wifiPermDenied = !granted
        wifiPermAsked = true
        CameraEngine.log(
            "扫描权限：用户${if (granted) "允许" else "拒绝"}（${permissions.firstOrNull()}）",
        )
    }

    fun register(messenger: BinaryMessenger, context: Context, engine: FlutterEngine, activity: Activity?) {        CameraEngine.init(context)
        this.activity = activity
        this.appContext = context.applicationContext
        this.        engineRef = engine
        executor = Executors.newCachedThreadPool()
        registerUsbReceiver(context.applicationContext)
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
        unregisterUsbReceiver(appContext)
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
            // 主动查 USB 总线上有没有（提供 PTP 接口的）相机。
            // 不依赖 ATTACHED 广播——多数 ROM 不会把它投给非默认处理程序，
            // 表现就是"插上相机 App 毫无反应"（真机反馈）。
            "usbCameraPresent" -> result.success(CameraEngine.usbCameraPresent())
            "clearUsbAttach" -> {
                lastUsbAttachName = null
                result.success(true)
            }
            // 是否正处于"App 专属的相机热点"连接（AP 模式一键入网后为 true）
            "cameraApActive" -> result.success(CameraEngine.cameraApActive())
            "currentSsid" -> result.success(CameraEngine.currentSsidOrNull())
            "hasWifiScanPermission" -> result.success(CameraEngine.hasWifiScanPermission())
            // 申请扫描所需权限（13+ = NEARBY_WIFI_DEVICES，10~12 = ACCESS_FINE_LOCATION）。
            // 返回状态串：granted / asked / blocked / no-activity / error（见函数注释）。
            "requestWifiScanPermission" -> result.success(requestWifiScanPermission())
            // 权限是否已由用户作答（Dart 靠它等待系统框，不靠数秒数猜）
            "wifiPermissionState" -> result.success(wifiPermissionState())
            // 手机**已保存过**的热点名。这份列表往往比"现扫"更有用：
            // 相机热点是用户手动连过一次的，凭据就在系统里，这里能直接列出它的名字，
            // 不必等 startScan 回填（新装应用/扫描被限流时现扫常常是空的）。
            "savedWifiSsids" -> result.success(CameraEngine.savedWifiSsids())
            // 退出该连接、恢复系统默认网络。只解绑与注销回调，不阻塞。
            "leaveCameraAp" -> {
                CameraEngine.leaveCameraAp()
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
                        // 旧记录补全保存位置用（见 CameraEngine.mediaRelativePath）
                        "mediaRelativePath" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.mediaRelativePath(args["name"] as String)
                        }
                        // 加入相机自建热点（AP 模式一键入网）。**会阻塞等待用户在系统确认框里
                        // 点「连接」**，因此必须在工作线程执行——放主线程会直接卡死界面。
                        "joinCameraAp" -> {
                            val args = call.arguments as Map<*, *>
                            CameraEngine.joinCameraAp(
                                args["ssid"] as String,
                                (args["passphrase"] as String?) ?: "",
                            )
                        }
                        // 扫描附近热点：内部会 startScan + 等驱动回填（约 1.2 秒），
                        // 属阻塞操作，必须走工作线程
                        "scanWifiNetworks" -> CameraEngine.scanWifiNetworks()
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
