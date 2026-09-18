package com.nikan.nikonsync

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.hardware.usb.UsbManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.content.ContentUris
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory
import kotlin.math.roundToInt

/**
 * 相机引擎：单例。管理 PTP/IP 连接生命周期、Wi-Fi 网络绑定、
 * 网段扫描、枚举、缩略图、下载（MediaStore 落盘）与事件转发。
 */
object CameraEngine {
    private const val TAG = "NikonSync"
    const val DEFAULT_FRIENDLY_NAME = "Nikon Wireless Mobile Utility"

    /** USB 会话的 cameraIp 伪地址前缀（USB 没有 IP，用它区分连接类型）。 */
    private const val USB_IP_PREFIX = "usb://"

    /** 拆除旧会话后、发起新握手前留给相机释放会话的时间 */
    private const val SESSION_SETTLE_MS = 1500L

    private var appContext: Context? = null
    internal var client: PtpSession? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var sink: EventChannel.EventSink? = null
    private var lastProgressEmit = 0L

    // ---- 保活：DeviceReady 轮询（相机响应即视为存活；socket 异常即断线）----
    private val keepAliveExecutor = Executors.newSingleThreadExecutor()
    private val keepAliveHandler = Handler(Looper.getMainLooper())
    private var keepAliveRunning = false

    /**
     * 是否有下载正在进行。
     *
     * 下载期间 PTP 通道被数据相位独占（USB 的 GetObject 要持有事务锁直到整文件读完），
     * 保活探针发不出去、也没法及时拿到结果——排在后面的探针会在下载结束后一次性补发，
     * 而这期间真正的断线反而没人发现。所以下载期间改用"最近是否还有进度"做活性判据。
     */
    @Volatile private var downloadInFlight = false

    /** 最近一次链路上确实发生 I/O 的时刻（下载进度即心跳）。 */
    @Volatile private var lastIoAt = 0L

    /** 下载期间多久没有新数据就判为链路可疑。取 30s：正常下载至少每 1MB 报一次进度。 */
    private const val DOWNLOAD_STALL_MS = 30_000L

    /**
     * 最近一次收到相机事件的时间。相机空闲时也在周期推 DevicePropChanged（实测 3~60s 一次），
     * 因此事件通道本身就是**免费的存活证据**：有事件就不必再占事务通道发探针——
     * 取景时事务通道很紧张，探针排队反而会把帧请求挤到超时。
     */
    @Volatile private var lastEventAt = 0L
    private const val EVENT_IDLE_MS = 8_000L

    /**
     * 最近一次保活探针的往返耗时（-1 = 本会话还没发过探针）。
     * UI 用它显示"连接正常 · 12ms"这类**可感知的活性证据**：只显示"已连接"
     * 无法回答"是卡住了还是断了"，一个具体的往返耗时可以。
     */
    @Volatile private var probeRttMs = -1L

    /** 最近一次探针是否成功（复探成功也算成功）。 */
    @Volatile private var probeOk = true

    private fun startKeepAlive() {
        stopKeepAlive()
        keepAliveRunning = true
        probeRttMs = -1
        probeOk = true
        val task = object : Runnable {
            override fun run() {
                if (!keepAliveRunning) return
                keepAliveExecutor.execute {
                    val c = client ?: return@execute
                    val silent = SystemClock.elapsedRealtime() - lastEventAt
                    // 心跳上报：**即使不发探针也要报**。UI 需要知道"相机此刻是空闲
                    // 还是失联"——只看有没有事件是分不出来的（空闲期本就可能 60s 无事件）。
                    emit(
                        mapOf(
                            "type" to "health",
                            "eventAgoMs" to if (lastEventAt == 0L) -1L else silent,
                            "rttMs" to probeRttMs,
                            "probeOk" to probeOk,
                        ),
                    )
                    // 下载进行中：不发探针（见 downloadInFlight 的说明），改看"最近还有没有进度"。
                    // 进度停滞才是真问题——这比"探针排队后一次性补发"有信息量得多。
                    if (downloadInFlight) {
                        val idle = if (lastIoAt == 0L) 0L else SystemClock.elapsedRealtime() - lastIoAt
                        if (idle > DOWNLOAD_STALL_MS) {
                            probeOk = false
                            c.notifyLinkDead("下载已 ${idle / 1000} 秒没有新数据，链路可能已断")
                        } else {
                            probeOk = true
                        }
                        return@execute
                    }
                    if (lastEventAt != 0L && silent < EVENT_IDLE_MS) return@execute
                    val t0 = SystemClock.elapsedRealtime()
                    try {
                        c.transact(Ptp.OP_NIKON_DEVICE_READY)
                        probeRttMs = SystemClock.elapsedRealtime() - t0
                        probeOk = true
                        drainCheckEvents()
                    } catch (e: PtpException) {
                        // 相机响应了 PTP 错误（如忙），链路仍在
                        probeRttMs = SystemClock.elapsedRealtime() - t0
                        probeOk = true
                    } catch (e: Exception) {
                        // 一次失败不判死：相机短暂忙、Wi-Fi 抖动、以及"超时落在包边界"
                        // 都会走到这里。复探一次仍失败才认定链路死亡——空闲期误报
                        // "已断开"比漏报更糟（用户会看到相机明明连着却要重连）。
                        val retry = runCatching {
                            Thread.sleep(500)
                            c.transact(Ptp.OP_NIKON_DEVICE_READY)
                        }
                        val alive = retry.isSuccess || retry.exceptionOrNull() is PtpException
                        if (alive) {
                            probeRttMs = SystemClock.elapsedRealtime() - t0
                            probeOk = true
                            log("保活探针首次失败（${e.message}），复探成功，判定链路正常")
                        } else {
                            probeOk = false
                            c.notifyLinkDead(e.message ?: "保活探针失败")
                        }
                    }
                }
                keepAliveHandler.postDelayed(this, 5_000)
            }
        }
        keepAliveHandler.postDelayed(task, 5_000)
    }

    private fun stopKeepAlive() {
        keepAliveRunning = false
        keepAliveHandler.removeCallbacksAndMessages(null)
    }

    var cameraIp: String? = null
        private set
    var deviceInfo: DeviceInfo? = null
        private set

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    // ------------------------------------------------------------ 事件上报

    fun attachSink(s: EventChannel.EventSink?) {
        sink = s
    }

    private fun emit(map: Map<String, Any?>) {
        mainHandler.post { sink?.success(map) }
    }

    /**
     * 供插件层转发"非引擎来源"的事件（例如 USB 插入）。
     * 与 [emit] 语义一致，只是把投递能力开放给同包的桥接层。
     */
    fun emitRaw(map: Map<String, Any?>) = emit(map)

    fun log(line: String) {
        Log.d(TAG, line)
        emit(mapOf("type" to "log", "line" to line))
    }

    /**
     * 让 Dart 侧也能写进 logcat。
     *
     * release 包里 Dart 的应用内日志（AppLog）不出现在 logcat，于是"UI 为什么没刷新"
     * 这类**界面层**问题在真机上没有任何外部证据——只能靠用户截图描述。
     * 关键路径（参数同步、取景状态机）用这个方法留痕，排查时不要再靠猜。
     */
    fun logFromDart(line: String) = Log.d(TAG, "[ui] $line")

    // ------------------------------------------------------------ 网络

    private fun cm(): ConnectivityManager =
        appContext!!.getSystemService(ConnectivityManager::class.java)

    /** 当前 Wi-Fi 网络（相机热点没有互联网，也不能要求有）。 */
    fun wifiNetwork(): Network? = apNetwork ?: cm().allNetworks.firstOrNull { n ->
        cm().getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    /**
     * 扫描附近的 Wi-Fi 热点，供「选择相机热点」用——**避免让用户手抄一长串 SSID**。
     *
     * 为什么不直接用 `WifiInfo.getSSID()` 拿当前热点名：本应用的 `NEARBY_WIFI_DEVICES`
     * 声明了 `neverForLocation`，系统在 Android 13+ 上会把 SSID 抹成 `<unknown ssid>`。
     * 而扫描结果里的 SSID 是可用的（这正是该权限的用途），所以改用"让用户从列表里选"。
     *
     * 需要运行时权限（13+ = NEARBY_WIFI_DEVICES，10~12 = ACCESS_FINE_LOCATION），
     * 拿不到就返回空列表，由 UI 提示去授权。
     */
    fun scanWifiNetworks(): List<Map<String, Any?>> {
        val ctx = appContext ?: return emptyList()
        return runCatching {
            @Suppress("DEPRECATION")
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (!wm.isWifiEnabled) {
                log("扫描附近 Wi-Fi：系统 Wi-Fi 未开启")
                return emptyList()
            }
            if (!hasWifiScanPermission()) {
                log("扫描附近 Wi-Fi：缺少运行时权限（13+ 需 NEARBY_WIFI_DEVICES，10~12 需定位）")
                return emptyList()
            }
            // 主动触发一次扫描：只读扫描结果可能为空——系统缓存里的结果有有效期，
            // 而且新装的 App 从来没触发过扫描时缓存里就是空的（真机踩过：列表一片空白）
            @Suppress("DEPRECATION")
            val started = runCatching { wm.startScan() }.getOrDefault(false)
            if (started) Thread.sleep(1200) // 等驱动回填结果（阻塞在调用方的工作线程上）
            @Suppress("DEPRECATION")
            val results = wm.scanResults ?: emptyList()
            log("扫描附近 Wi-Fi：startScan=$started，拿到 ${results.size} 条结果")
            // 同名去重，保留信号最强的那条
            val best = LinkedHashMap<String, android.net.wifi.ScanResult>()
            for (r in results) {
                val ssid = r.SSID
                if (ssid.isNullOrEmpty()) continue
                val cur = best[ssid]
                if (cur == null || r.level > cur.level) best[ssid] = r
            }
            best.values.sortedByDescending { it.level }.map { r ->
                val cap = r.capabilities ?: ""
                mapOf(
                    "ssid" to r.SSID,
                    "level" to r.level,
                    // WPA/WEP 都算需要密码；相机热点固定是 WPA2
                    "secured" to (cap.contains("WPA") || cap.contains("WEP")),
                    "capabilities" to cap,
                )
            }
        }.getOrElse { e ->
            log("扫描附近 Wi-Fi 失败：${e.message}")
            emptyList()
        }
    }

    /**
     * 尽力读出**当前所连热点的 SSID**，读不到返回 null。
     *
     * 为什么要单独试这条路：Android 13+ 上 `WifiInfo.getSSID()` 常被抹成 `<unknown ssid>`，
     * 而 `NetworkCapabilities.getSsid()`（API 30+）在拿到 NEARBY_WIFI_DEVICES 后往往可读——
     * 能读到就不必让用户再从扫描列表里挑一次。
     */
    fun currentSsidOrNull(): String? {
        val ctx = appContext ?: return null
        return runCatching {
            // 正路：NetworkCapabilities.transportInfo 拿出 WifiInfo（API 29+）。
            // ⚠️ NetworkCapabilities 本身没有 getSsid()——这一点容易凭印象写错。
            val cap = cm().activeNetwork?.let { cm().getNetworkCapabilities(it) }
            val info = cap?.transportInfo as? android.net.wifi.WifiInfo
            val fromCap = info?.ssid
            if (!fromCap.isNullOrEmpty() && !fromCap.startsWith("<")) return fromCap
            @Suppress("DEPRECATION")
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val fromWifi = wm.connectionInfo?.ssid
            if (!fromWifi.isNullOrEmpty() && !fromWifi.startsWith("<")) return fromWifi
            null
        }.getOrElse { e ->
            log("读取当前 SSID 失败：${e.message}")
            null
        }
    }

    /** 当前是否持有扫描所需的运行时权限（13+ = NEARBY_WIFI_DEVICES，否则 ACCESS_FINE_LOCATION） */
    fun hasWifiScanPermission(): Boolean {
        val ctx = appContext ?: return false
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            android.Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            android.Manifest.permission.ACCESS_FINE_LOCATION
        }
        return ctx.checkSelfPermission(perm) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /**
     * 手机**已保存过**的热点名（去重后按名称排序）。
     *
     * ⚠️ **Android 10+ 上这个方法对普通应用恒返回空列表**——官方行为变更明文规定：
     * "只有系统应用和 DPC 支持手动配置系统 WLAN 网络列表"，对其他应用
     * `getConfiguredNetworks()` 恒返回空、`addNetwork/updateNetwork` 恒返回 -1、
     * `removeNetwork/reassociate/enableNetwork/disableNetwork/reconnect/disconnect`
     * 恒返回 false。**网上流传的 "getConfiguredNetworks + enableNetwork + reconnect
     * 连接已保存网络" 的方案只适用于 Android 9 及以下**，Q+ 上整条链路是空操作。
     * 本机已实证（权限已授予仍返回 0 个）。官方替代：`WifiNetworkSpecifier` /
     * `WifiNetworkSuggestion`（都要求应用自己提供凭据）。
     *
     * 保留本方法的意义：兼容极少数仍在跑 Android 9 的旧设备，以及系统应用场景；
     * 在 Android 10+ 上它只会返回空（随后走 specifier 带凭据的路径）。
     */
    fun savedWifiSsids(): List<String> {
        val ctx = appContext ?: return emptyList()
        if (!hasWifiScanPermission()) {
            log("读取已保存热点：缺少运行时权限")
            return emptyList()
        }
        return runCatching {
            @Suppress("DEPRECATION")
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val out = LinkedHashSet<String>()
            @Suppress("DEPRECATION")
            for (c in wm.configuredNetworks ?: emptyList<android.net.wifi.WifiConfiguration>()) {
                // configuredNetworks 的 SSID 带引号（"\"SSID\""），必须剥掉
                val s = c.SSID?.trim()?.trim('"') ?: continue
                if (s.isNotEmpty()) out.add(s)
            }
            log("读取已保存热点：${out.size} 个")
            out.sorted()
        }.getOrElse { e ->
            log("读取已保存热点失败：${e.message}")
            emptyList()
        }
    }

    // ---------------------------------------------------- 相机热点一键入网

    /**
     * 通过 `WifiNetworkSpecifier` 连上的**相机自建热点**（AP 模式，App 专属连接）。
     *
     * 为什么需要它：Android 10+ 禁止 App 静默切换 Wi-Fi，用户要连相机热点必须"手动去系统设置"
     * ——这是 AP 模式最烦的一步。用 specifier 可以在 App 内弹一次系统确认框就完成入网。
     *
     * ⚠️ 该连接是 **App 专属**的：系统仍保留用户与家里路由器的连接，本应用的流量走相机热点。
     * 所以必须 `bindProcessToNetwork`，并让 [wifiNetwork] 优先返回它——否则
     * `socketFactory()` 会拿到路由器的 Network，socket 就被绑到错的网络上去了。
     */
    @Volatile
    private var apNetwork: Network? = null

    @Volatile
    private var apCallback: ConnectivityManager.NetworkCallback? = null

    /** 当前是否处于"App 专属的相机热点"连接 */
    fun cameraApActive(): Boolean = apNetwork != null

    /**
     * 加入相机热点。**会弹出系统确认框**，用户点「连接」后才算成功。
     *
     * @param ssid 相机热点名（相机屏幕上显示的那个；通常由上次连接成功后自动记住）
     * @param passphrase 相机热点密码。**传空字符串时按"手机里已保存过该热点"处理**：
     *   系统会拿已保存的凭据去连，用户不必再输密码——这是"第一次手动连过、
     *   之后就能一键自动连"的关键（Android 不允许 App 读系统里保存的 Wi-Fi 密码，
     *   但允许 App 请求连接一个已保存的网络）。
     */
    fun joinCameraAp(ssid: String, passphrase: String): Map<String, Any?> {
        val ctx = appContext ?: throw IOException("尚未初始化")
        val manager = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        leaveCameraAp() // 先清掉上一次，避免回调叠加

        val specifierBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (passphrase.isNotEmpty()) {
            // 相机热点是 WPA2-PSK（尼康默认）。空串时**不设置凭据**，
            // 让系统用"已保存的网络"去匹配——即用户之前手动连过一次的那个。
            specifierBuilder.setWpa2Passphrase(passphrase)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // 相机热点**没有互联网**：不显式移除 INTERNET 能力要求的话，
            // 系统会认为该网络"不可用"，onAvailable 永远不来（这是个经典坑）
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifierBuilder.build())
            .build()

        val latch = CountDownLatch(1)
        val startedAt = SystemClock.elapsedRealtime()
        var failure: String? = null
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                apNetwork = network
                // 绑到本进程：之后扫描、握手、传输的 socket 都会走相机热点
                runCatching { manager.bindProcessToNetwork(network) }
                    .onFailure { failure = "已连上热点但绑定失败：${it.message}" }
                latch.countDown()
            }

            override fun onUnavailable() {
                val ms = SystemClock.elapsedRealtime() - startedAt
                // 秒回 vs 拖了几秒才失败，原因完全不同，所以要分开说：
                // 前者是"系统压根没试"（用户在确认框上点取消/关掉），后者才是凭据问题。
                // 混成一条"密码可能不对"会把用户支去改密码（真机反馈过）。
                failure = when {
                    ms < 1500 ->
                        "系统没有连接该热点（${ms}ms）：多半是你在系统确认框里点了取消。" +
                            "再点一次「一键连接」即可"
                    passphrase.isEmpty() ->
                        "系统没能连上「$ssid」：手机里没有保存过这个热点，所以不知道该用什么密码连。" +
                            "可以：① 到系统 Wi-Fi 设置里手动连它一次（只需一次，之后免密一键连）；" +
                            "② 在这里填一次热点密码"
                    else ->
                        "系统没能连上「$ssid」：密码不对（等 $ms ms 后放弃）。" +
                            "密码见相机屏幕：网络菜单 → 连接至智能设备 → Wi-Fi 连接"
                }
                log("加入热点失败：$failure")
                latch.countDown()
            }

            override fun onLost(network: Network) {
                if (apNetwork == network) {
                    apNetwork = null
                    runCatching { manager.bindProcessToNetwork(null) }
                }
            }
        }
        apCallback = cb

        try {
            manager.requestNetwork(request, cb)
        } catch (e: SecurityException) {
            leaveCameraAp()
            throw IOException("缺少「附近的设备/位置」权限，无法自动加入热点：${e.message}")
        } catch (e: Exception) {
            leaveCameraAp()
            throw IOException("请求加入热点失败：${e.message}")
        }

        // 等用户点确认（系统确认框没有超时回调，这里自己等）
        val ok = latch.await(90, TimeUnit.SECONDS)
        failure?.let {
            leaveCameraAp()
            throw IOException(it)
        }
        if (!ok) {
            leaveCameraAp()
            throw IOException("等待确认超时：请在系统弹框里点「连接」")
        }
        log("已加入相机热点 \"$ssid\"（App 专属连接）")
        return mapOf("ok" to true, "ssid" to ssid, "ip" to (cm().getLinkProperties(apNetwork!!)?.linkAddresses?.firstOrNull()?.address?.hostAddress ?: ""))
    }

    /** 退出 App 专属的相机热点连接，恢复系统默认网络（通常断开相机时调用） */
    fun leaveCameraAp() {
        val ctx = appContext ?: return
        val manager = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        apCallback?.let { runCatching { manager.unregisterNetworkCallback(it) } }
        apCallback = null
        if (apNetwork != null) {
            runCatching { manager.bindProcessToNetwork(null) }
            apNetwork = null
            log("已退出 App 专属的相机热点连接")
        }
    }

    fun socketFactory(): SocketFactory? = wifiNetwork()?.socketFactory

    fun wifiInfo(): Map<String, Any?> {
        val net = wifiNetwork()
        var ip = ""
        var gateway = ""
        net?.let { n ->
            runCatching {
                cm().getLinkProperties(n)?.let { lp ->
                    lp.linkAddresses.firstOrNull { it.address is Inet4Address }?.let {
                        ip = it.address.hostAddress ?: ""
                    }
                    lp.routes.firstOrNull { it.gateway is Inet4Address }?.let {
                        gateway = (it.gateway as Inet4Address).hostAddress ?: ""
                    }
                }
            }
        }
        var ssid: String? = null
        // 信号强度：用户靠它区分"App 卡住了"与"链路在变差/已断开"。
        // 取不到时 rssi 保持 0、level 保持 -1（UI 显示为"无数据"，不假装满格）。
        var rssi = 0
        var level = -1
        var linkSpeed = 0
        var frequency = 0
        runCatching {
            @Suppress("DEPRECATION")
            val wm = appContext!!.getSystemService(WifiManager::class.java)
            val ci = wm?.connectionInfo
            val raw = ci?.ssid?.removeSurrounding("\"")
            if (raw != null && raw != "<unknown ssid>" && raw != "0x") ssid = raw
            val r = ci?.rssi ?: 0
            // 0 / -127 都是"没有有效 Wi-Fi 信息"的哨兵值，不能当成真实信号
            if (ci != null && r != 0 && r != -127 && r < 0) {
                rssi = r
                level = WifiManager.calculateSignalLevel(r, 5) // 0~4 格
                linkSpeed = ci.linkSpeed
                frequency = ci.frequency
            }
        }
        return mapOf(
            "onWifi" to (net != null),
            "ssid" to ssid,
            "ip" to ip,
            "gateway" to gateway,
            "rssi" to rssi,
            "signalLevel" to level,
            "linkSpeed" to linkSpeed,
            "frequency" to frequency,
        )
    }

    fun openWifiSettings() {
        val ctx = appContext!!
        try {
            ctx.startActivity(Intent(Settings.Panel.ACTION_WIFI).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            ctx.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /**
     * 打开本应用的系统设置页。
     *
     * 用途：权限被"拒绝两次"后系统不再弹框，只能引导用户手动去开——
     * 否则用户会卡在"点了没反应"上（真机反馈过：热点列表一直空白）。
     */
    /**
     * 当前插着、且带 **PTP/静态影像接口** 的 USB 设备名（无则 null）。
     *
     * 为什么要主动查而不是等广播：`USB_DEVICE_ATTACHED` 的清单声明只有在用户
     * 把本应用设为"默认处理程序"时才会把 Intent 送到我们这；多数 ROM
     * （真机为 HyperOS）会弹一个选择框，甚至什么都不投——表现就是
     * "插上相机，App 里没有任何反应，还得手动点连接"。
     *
     * 接口判据与 [PtpUsbClient] 里挑接口的规则一致：class 6 = Still Imaging，
     * subclass 1 + protocol 1 = PTP。
     */
    fun usbCameraPresent(): String? {
        val ctx = appContext ?: return null
        return runCatching {
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return null
            val dev = mgr.deviceList.values.firstOrNull { d ->
                (0 until d.interfaceCount).any { i ->
                    val c = d.getInterface(i)
                    c.interfaceClass == 6 && c.interfaceSubclass == 1 && c.interfaceProtocol == 1
                }
            } ?: return null
            dev.productName ?: "USB 相机"
        }.getOrNull()
    }

    fun openAppSettings() {
        val ctx = appContext!!
        runCatching {
            ctx.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", ctx.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * 扫描当前网段内监听 15740 端口的设备（即相机）。
     * 只做 TCP 探测不做 PTP 握手。
     * 注意：裸 TCP 连接会让相机弹出"正在连接"又中断，主流程请用 [connectSmart]。
     */
    fun scan(): List<String> = scanInternal(wifiNetwork() ?: throw IOException("手机未连接 Wi-Fi，请先连接相机热点"), emptySet())

    private fun scanInternal(net: Network, exclude: Set<String>): List<String> {
        val candidates = LinkedHashSet<String>()
        runCatching {
            cm().getLinkProperties(net)?.let { lp ->
                lp.routes.firstOrNull { it.gateway is Inet4Address }?.let {
                    candidates.add((it.gateway as Inet4Address).hostAddress ?: return@let)
                }
                lp.linkAddresses.firstOrNull { it.address is Inet4Address }?.let { la ->
                    val a = (la.address as Inet4Address).address
                    if (a.size >= 4) {
                        for (i in 1..254) {
                            candidates.add("${a[0].toInt() and 0xFF}.${a[1].toInt() and 0xFF}.${a[2].toInt() and 0xFF}.$i")
                        }
                    }
                }
            }
        }
        candidates.add("192.168.1.1")
        candidates.removeAll(exclude)
        if (candidates.isEmpty()) return emptyList()
        log("扫描 ${candidates.size} 个候选地址 :${PtpIpClient.PORT} …")
        val found = Collections.synchronizedList(ArrayList<String>())
        val pool = Executors.newFixedThreadPool(64)
        val sf = net.socketFactory
        for (ip in candidates) {
            pool.submit {
                try {
                    val s = sf.createSocket()
                    try {
                        s.tcpNoDelay = true
                        s.connect(InetSocketAddress(ip, PtpIpClient.PORT), 600)
                    } finally {
                        runCatching { s.close() }
                    }
                    found.add(ip)
                } catch (_: Exception) {
                }
            }
        }
        pool.shutdown()
        pool.awaitTermination(20, TimeUnit.SECONDS)
        val list = found.distinct()
        log("扫描完成：${if (list.isEmpty()) "未发现相机" else list.joinToString()}")
        return list
    }

    /**
     * 智能连接：相机在 AP 模式下就是网关（DHCP 服务器），直接对网关 IP 发起
     * 正式 PTP 握手（失败重试一次，给相机端"连接失败"状态恢复时间）；
     * 仍失败才做网段扫描并逐个握手。
     */
    fun connectSmart(): Map<String, Any?> {
        val net = wifiNetwork() ?: throw IOException("手机未连接 Wi-Fi，请先连接相机热点")
        val gw = runCatching {
            cm().getLinkProperties(net)?.routes
                ?.firstOrNull { it.gateway is Inet4Address }
                ?.let { (it.gateway as Inet4Address).hostAddress }
        }.getOrNull()
        val candidates = LinkedHashSet<String>()
        // 上次连上的相机地址优先：自动重连失败后 cameraIp 会保留下来，
        // 用户再点一次「连接相机」时直接打到已知地址，不必先靠网关猜。
        cameraIp?.takeIf { !it.startsWith(USB_IP_PREFIX) }?.let { candidates.add(it) }
        // 过滤 0.0.0.0（部分 ROM 在相机热点下报无效网关，连它等于连 localhost）
        if (!gw.isNullOrBlank() && gw != "0.0.0.0") candidates.add(gw)
        candidates.add("192.168.1.1")

        var lastError: Exception? = null
        for (ip in candidates) {
            var attempt = 0
            while (attempt < 2) {
                attempt++
                try {
                    return connect(ip, DEFAULT_FRIENDLY_NAME)
                } catch (e: Exception) {
                    lastError = e
                    log("连接 $ip 第 $attempt 次失败：${e.message}")
                    if (attempt < 2) Thread.sleep(2000)
                }
            }
        }
        // 兜底：网段扫描 + 握手。
        // 但如果失败原因是"相机把连接重置了"，扫描毫无意义——在相机释放上一个会话之前，
        // 它对每一个新连接都回 RST，扫 254 个地址只会白等 2.4 秒并给出"未发现相机"
        // 这个与真实原因无关的结论（真机日志 §19 正是这一幕）。
        if (isSessionConflict(lastError?.message)) {
            log("跳过网段扫描：相机仍在释放上一个会话（新连接会被 reset）")
            throw IOException(
                "相机还在释放上一个会话（PTP/IP 只允许一台主机），此刻握手会被相机拒绝。\n" +
                    "请等 30 秒~3 分钟再点一次「连接相机」。\n" +
                    "若相机屏幕显示连接失败，请先在相机上确认/重试，再回本应用连接。",
            )
        }
        val found = scanInternal(net, candidates)
        for (ip in found) {
            try {
                return connect(ip, DEFAULT_FRIENDLY_NAME)
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw IOException(
            "未发现相机（${lastError?.message ?: "网段内无响应"}）。" +
                "请确认相机已进入显示 SSID/密码的连接等待画面；若相机提示连接失败，请先在相机上重试",
        )
    }

    /** 失败原因是否指向"相机端仍有会话占用"（连接被对端重置）。 */
    private fun isSessionConflict(msg: String?): Boolean {
        val m = msg?.lowercase() ?: return false
        return m.contains("connection reset") || m.contains("socket eof") ||
            m.contains("reset by peer") || m.contains("broken pipe")
    }

    // ------------------------------------------------------------ 连接

    fun connect(ip: String, friendlyName: String): Map<String, Any?> {
        // 用户/上层主动发起连接：取消进行中的自动重连（本机重连线程除外）
        if (autoReconnecting && Thread.currentThread() !== reconnectThread) {
            autoReconnecting = false
        }
        // 已连同一台相机时直接返回：PTP/IP 一台相机只允许一个会话，立刻拆掉再握手
        // 会让相机来不及释放旧会话，进而进入"连接失败"状态并关闭热点。
        // 用户实测：主页连上后到调试面板再点一次连接，相机就断线了。
        val cur = client
        if (cur != null && deviceInfo != null && cameraIp == ip) {
            log("已连接到 $ip，跳过重复握手")
            return describeCamera(cur)
        }
        val hadSession = cur != null
        disconnectQuiet()
        if (hadSession) {
            // 换相机/强制重连：等相机释放上一个会话再发起新的握手
            log("等待相机释放上一个会话（${SESSION_SETTLE_MS}ms）")
            Thread.sleep(SESSION_SETTLE_MS)
        }
        log("开始握手（friendlyName=\"$friendlyName\"）")
        val c: PtpSession = PtpIpClient(socketFactory(), ::log)
        try {
            c.connect(ip, friendlyName)
        } catch (e: Exception) {
            // 握手失败也要回收客户端，否则每次重试都会泄漏一条已建立的 TCP 连接
            runCatching { c.close() }
            throw e
        }
        // 先登记为当前会话再装回调：回调内用 client === c 判定归属，
        // 若先装回调，握手刚结束就断线时会被误判成"旧会话"而漏报断线。
        client = c
        deviceInfo = c.deviceInfo
        cameraIp = ip
        c.eventHandler = { code, params ->
            if (client === c) {
                lastEventAt = SystemClock.elapsedRealtime() // 事件即存活证据（保活据此免发探针）
                when {
                    code == Ptp.EVT_OBJECT_ADDED && params.isNotEmpty() ->
                        emit(mapOf("type" to "objectAdded", "handle" to params[0]))
                    // 相机在拨轮/曝光变化时会推 DevicePropChanged（实测推的正是
                    // 0x5007 焦距、0x500D 光圈、0x500E 快门、0x500F ISO）。
                    // 转给 Flutter 侧，遥控页据此实时刷新参数显示。
                    code == Ptp.EVT_DEVICE_PROP_CHANGED && params.isNotEmpty() ->
                        emit(mapOf("type" to "devicePropChanged", "code" to params[0]))
                }
            }
        }
        c.disconnectHandler = { reason ->
            // 旧会话的死亡回调可能在新连接建立后才到达（旧事件线程/旧保活任务），
            // 那种情况必须忽略，否则会把新连接的状态打回未连接。
            if (client === c) {
                stopKeepAlive()
                liveViewOn = false
                if (reason.startsWith("手动")) {
                    KeepAliveService.stop(appContext!!)
                    client = null
                    deviceInfo = null
                    cameraIp = null
                    emit(mapOf("type" to "status", "state" to "disconnected", "reason" to reason))
                } else {
                    scheduleAutoReconnect(reason)
                }
            } else {
                log("忽略非当前会话的断线通知：$reason")
            }
        }
        if (client !== c) throw IOException("握手完成后连接立即失效，请重试")
        startKeepAlive()
        KeepAliveService.start(appContext!!)
        emit(mapOf("type" to "status", "state" to "connected", "ip" to ip))
        return describeCamera(c)
    }

    /**
     * USB 连接：同一套上层逻辑（枚举/下载/遥控）直接跑在 PTP/USB 传输层上。
     * 实测吞吐 27.1 MB/s（Wi-Fi 的 11 倍，见 docs/USB连接方案.md §1）。
     * 会弹系统 USB 权限对话框，需要用户点一次「允许」。
     */
    fun connectUsb(friendlyName: String): Map<String, Any?> {
        val cur = client
        if (cur is PtpUsbClient && cur.isConnected) {
            log("已连接 USB 相机，跳过重复连接")
            return describeCamera(cur)
        }
        val hadSession = cur != null
        disconnectQuiet()
        if (hadSession) {
            log("等待释放上一个会话（${SESSION_SETTLE_MS}ms）")
            Thread.sleep(SESSION_SETTLE_MS)
        }
        log("开始 USB 连接")
        val c = PtpUsbClient({ appContext!! }, ::log)
        try {
            c.connect("usb", friendlyName)
        } catch (e: Exception) {
            runCatching { c.close() }
            throw e
        }
        client = c
        deviceInfo = c.deviceInfo
        cameraIp = USB_IP_PREFIX + c.cameraName
        c.eventHandler = { code, params ->
            if (client === c) {
                lastEventAt = SystemClock.elapsedRealtime()
                when {
                    code == Ptp.EVT_OBJECT_ADDED && params.isNotEmpty() ->
                        emit(mapOf("type" to "objectAdded", "handle" to params[0]))
                    code == Ptp.EVT_DEVICE_PROP_CHANGED && params.isNotEmpty() ->
                        emit(mapOf("type" to "devicePropChanged", "code" to params[0]))
                }
            }
        }
        c.disconnectHandler = { reason ->
            if (client === c) {
                stopKeepAlive()
                liveViewOn = false
                KeepAliveService.stop(appContext!!)
                client = null
                deviceInfo = null
                cameraIp = null
                emit(mapOf("type" to "status", "state" to "disconnected", "reason" to reason))
            } else {
                log("忽略非当前会话的断线通知：$reason")
            }
        }
        if (client !== c) throw IOException("USB 连接完成后立即失效，请重试")
        // USB 无 NAT/热点保活诉求，保活事务仅作存活探测（周期 GetDeviceInfo）
        startKeepAlive()
        KeepAliveService.start(appContext!!)
        emit(mapOf("type" to "status", "state" to "connected", "ip" to "USB"))
        return describeCamera(c)
    }

    /** 相机信息（连接结果与"已连接"快路径共用）。 */
    private fun describeCamera(c: PtpSession): Map<String, Any?> {
        val di = c.deviceInfo ?: throw IOException("未取得设备信息，请重试")
        return mapOf(
            "manufacturer" to di.manufacturer,
            "model" to di.model,
            "deviceVersion" to di.deviceVersion,
            "serial" to di.serialNumber,
            "vendorDesc" to di.vendorExtensionDesc,
            "operations" to di.operationsSupported.toList(),
            "events" to di.eventsSupported.toList(),
            "supportsPartial" to di.supportsOperation(Ptp.OP_GET_PARTIAL_OBJECT),
            "supportsLargeThumb" to di.supportsOperation(Ptp.OP_NIKON_GET_LARGE_THUMB),
            "supportsObjectAdded" to di.supportsEvent(Ptp.EVT_OBJECT_ADDED),
            "cameraName" to c.cameraName,
            // 本次连上的地址（USB 会话是 `usb:` 伪地址，Dart 侧会据此排除）。
            // 必须暴露：智能连接（connectSmart）全在原生侧扫描并握手，Dart 根本不知道
            // 连的是哪个地址——不返回的话"记住设备/自动重连"就永远是空的。
            "ip" to cameraIp,
        )
    }

    /** 自动重连状态：仅意外断开时置位；用户手动断开/主动连接会取消。 */
    @Volatile private var autoReconnecting = false
    @Volatile private var reconnectThread: Thread? = null

    /**
     * 自动重连的退避序列。
     *
     * 为什么这么长：PTP/IP 同一时刻只允许一台主机，命令通道失同步后相机**仍持有
     * 上一个会话**，在它自己释放之前，我们对 15740 的每一次新连接都会被 RST。
     * 真机日志里这个窗口约 3 分钟（18:14:55 断 → 18:18:06 才连上），
     * 而"重连 3 次共 17.5 秒就放弃"必然撞在窗口内 → 用户看到"未发现相机"。
     * 累计约 2.8 分钟，覆盖实测窗口。
     */
    private val reconnectDelays = longArrayOf(2_000, 4_000, 8_000, 15_000, 20_000, 30_000, 30_000, 30_000, 30_000)

    private fun scheduleAutoReconnect(reason: String) {
        if (autoReconnecting) return
        val target = cameraIp
        if (target == null) {
            KeepAliveService.stop(appContext!!)
            client = null
            deviceInfo = null
            emit(mapOf("type" to "status", "state" to "disconnected", "reason" to reason))
            return
        }
        autoReconnecting = true
        // 死连接立即回收（保留 cameraIp 供重连），避免 dedup 判定"已连接"跳过重连。
        // 回收也会让相机更快看到 TCP FIN，从而更早释放会话。
        runCatching { client?.close() }
        client = null
        deviceInfo = null
        emit(
            mapOf(
                "type" to "status", "state" to "reconnecting", "reason" to reason,
                "attempt" to 0, "total" to reconnectDelays.size,
            ),
        )
        log("连接意外断开（$reason），开始自动重连 $target（最多 ${reconnectDelays.size} 次）")
        val t = Thread {
            reconnectThread = Thread.currentThread()
            try {
                var lastError: Exception? = null
                for ((i, d) in reconnectDelays.withIndex()) {
                    if (!autoReconnecting) return@Thread
                    emit(
                        mapOf(
                            "type" to "status", "state" to "reconnecting",
                            "reason" to reason, "attempt" to (i + 1),
                            "total" to reconnectDelays.size, "nextInMs" to d,
                        ),
                    )
                    Thread.sleep(d)
                    if (!autoReconnecting) return@Thread
                    try {
                        connect(target, DEFAULT_FRIENDLY_NAME)
                        log("自动重连成功（第 ${i + 1} 次尝试）")
                        return@Thread
                    } catch (e: Exception) {
                        lastError = e
                        log("自动重连第 ${i + 1} 次失败：${e.message}")
                    }
                }
                // 全部失败：置灰但**保留 cameraIp**，用户点一次「连接相机」即可用已知地址重试
                autoReconnecting = false
                KeepAliveService.stop(appContext!!)
                emit(
                    mapOf(
                        "type" to "status", "state" to "disconnected",
                        "reason" to (
                            "自动重连失败：${lastError?.message ?: reason}\n" +
                                "相机可能仍持有上一个会话（PTP/IP 单会话限制），稍后再点「连接相机」即可"
                            ),
                    ),
                )
            } finally {
                reconnectThread = null
                autoReconnecting = false
            }
        }
        t.isDaemon = true
        t.start()
    }

    fun disconnect() {
        autoReconnecting = false // 用户手动断开：取消进行中的自动重连
        disconnectQuiet()
        // 若之前是用"App 专属连接"加入的相机热点，断开时一并退出：
        // 否则手机会一直挂在那个没有互联网的热点上（系统通知也一直挂着）。
        leaveCameraAp()
        emit(mapOf("type" to "status", "state" to "disconnected", "reason" to "手动断开"))
    }

    private fun disconnectQuiet() {
        stopKeepAlive()
        liveViewOn = false
        KeepAliveService.stop(appContext!!)
        val c = client ?: return
        client = null
        deviceInfo = null
        runCatching { c.close() }
    }

    internal fun need(): PtpSession = client ?: throw IOException("尚未连接相机")

    /** 相机能力清单：操作码/事件码/属性码原始列表（名称映射在 Flutter 侧） */
    fun capabilities(): Map<String, Any?> {
        val di = deviceInfo ?: throw IOException("尚未连接相机")
        return mapOf(
            "operations" to di.operationsSupported.toList(),
            "events" to di.eventsSupported.toList(),
            "deviceProps" to di.devicePropsSupported.toList(),
            "captureFormats" to emptyList<Int>(),
            "model" to di.model,
        )
    }

    // ------------------------------------------------------------ 枚举

    /** GetObjectHandles 的父句柄值：0xFFFFFFFF 表示根目录。 */
    private const val ROOT_PARENT = 0xFFFFFFFFL

    /** 单次枚举的文件数上限，防御异常目录树。 */
    private const val MAX_ENUM_FILES = 5000

    private fun readHandles(c: PtpSession, storageId: Long, parent: Long, format: Int = 0): List<Long> =
        c.transact(Ptp.OP_GET_OBJECT_HANDLES, longArrayOf(storageId, format.toLong(), parent))
            .data.let { ByteReader(it).u32Array() }.toList()

    private fun getObjectInfo(c: PtpSession, handle: Long): ObjectInfo =
        PtpDatasets.parseObjectInfo(c.transact(Ptp.OP_GET_OBJECT_INFO, longArrayOf(handle)).data)

    private fun infoToMap(o: ObjectInfo): Map<String, Any?> = mapOf(
        "name" to o.filename,
        "format" to o.format,
        "formatName" to Ptp.fmtName(o.format),
        "size" to o.compressedSize,
        "width" to o.imageWidth,
        "height" to o.imageHeight,
        "date" to o.captureDateText,
        "captureDate" to o.captureDateRaw,
        "isVideo" to o.isVideo,
        "isJpeg" to o.isJpeg,
    )

    fun enumerate(): Map<String, Any?> {
        val c = need()
        val t0 = SystemClock.elapsedRealtime()
        val storageIds = runCatching {
            c.transact(Ptp.OP_GET_STORAGE_IDS).data.let { ByteReader(it).u32Array() }.toList()
        }.getOrDefault(emptyList())
        val scopes = if (storageIds.isEmpty()) listOf(ROOT_PARENT) else storageIds

        // Z50 II 的智能设备 profile 是目录式的：parent=0xFFFFFFFF 只返回根（DCIM），
        // 必须按目录句柄逐层下钻才能列出照片（与 gphoto2 在 Z8 上观察到的行为一致）
        val queue = ArrayDeque<Triple<Long, Long, Int>>() // storageId, parentHandle, depth
        scopes.forEach { queue.add(Triple(it, ROOT_PARENT, 0)) }
        val visited = HashSet<Long>()
        val files = ArrayList<Pair<Long, ObjectInfo>>()
        var folderCount = 0
        while (queue.isNotEmpty() && files.size < MAX_ENUM_FILES) {
            val (sid, parent, depth) = queue.removeFirst()
            val handles = runCatching { readHandles(c, sid, parent) }.getOrDefault(emptyList())
            for (h in handles) {
                if (!visited.add(h)) continue
                val info = runCatching { getObjectInfo(c, h) }.getOrNull() ?: continue
                if (info.format == Ptp.FMT_ASSOCIATION) {
                    folderCount++
                    if (depth < 8) queue.add(Triple(sid, h, depth + 1))
                } else {
                    files.add(h to info)
                }
            }
        }
        val ms = SystemClock.elapsedRealtime() - t0
        val jpeg = files.count { it.second.isJpeg }
        val video = files.count { it.second.isVideo }
        val raw = files.size - jpeg - video
        log("枚举完成：$folderCount 目录 / ${files.size} 文件（JPEG $jpeg · RAW $raw · 视频 $video），耗时 ${ms}ms")
        val fileMaps = files.take(200).map { (h, info) -> infoToMap(info) + mapOf("handle" to h) }
        return mapOf(
            "storageIds" to storageIds,
            "totalFiles" to files.size,
            "folderCount" to folderCount,
            "jpegCount" to jpeg,
            "rawCount" to raw,
            "videoCount" to video,
            "files" to fileMaps,
        )
    }

    fun objectInfo(handles: List<Long>): List<Map<String, Any?>> {
        val c = need()
        return handles.mapNotNull { h ->
            runCatching { infoToMap(getObjectInfo(c, h)) + mapOf("handle" to h) }.getOrNull()
        }
    }

    fun fileInfo(handle: Long): Map<String, Any?> =
        infoToMap(getObjectInfo(need(), handle)) + mapOf("handle" to handle)

    /** 单文件详情 + 缩略图（相册单元格按需加载用，一次通道调用省一半往返）。 */
    fun fileView(handle: Long): Map<String, Any?> {
        val c = need()
        val info = getObjectInfo(c, handle)
        val thumb = runCatching { c.getThumbnailBytes(handle) }.getOrDefault(ByteArray(0))
        return infoToMap(info) + mapOf("handle" to handle, "thumb" to thumb)
    }

    /**
     * 快速枚举：只走目录树拿句柄，不做逐文件 ObjectInfo（几千张照片 1 秒级）。
     * 文件详情与缩略图由上层按需拉取。
     *
     * 目录/文件区分：先按格式 0x3001（目录）查询做集合差；若相机忽略格式过滤
     * （assoc == all），用一次 ObjectInfo 探测决定整批归类。
     */
    fun listFolders(): Map<String, Any?> {
        val c = need()
        val t0 = SystemClock.elapsedRealtime()
        val storageIds = runCatching {
            c.transact(Ptp.OP_GET_STORAGE_IDS).data.let { ByteReader(it).u32Array() }.toList()
        }.getOrDefault(emptyList())
        val scopes = if (storageIds.isEmpty()) listOf(ROOT_PARENT) else storageIds

        val files = ArrayList<Long>()
        val fileFolders = ArrayList<Int>()
        val folderIdxByName = LinkedHashMap<String, Int>()
        var infoQueries = 0

        fun walk(sid: Long, parent: Long, depth: Int, curFolderIdx: Int) {
            if (depth > 8 || files.size >= MAX_ENUM_FILES) return
            val all = runCatching { readHandles(c, sid, parent, 0) }.getOrDefault(emptyList())
            if (all.isEmpty()) return
            val assoc = runCatching { readHandles(c, sid, parent, Ptp.FMT_ASSOCIATION) }.getOrDefault(emptyList())
            if (assoc.isNotEmpty() && assoc.size == all.size && assoc.containsAll(all)) {
                // 格式过滤可能被忽略（assoc == all）：探测第一个句柄决定整批归类
                val probe = runCatching { getObjectInfo(c, all.first()).format }.getOrDefault(-1)
                infoQueries++
                if (probe == Ptp.FMT_ASSOCIATION) {
                    for (h in all) {
                        val fmt = runCatching { getObjectInfo(c, h).format }.getOrDefault(-1)
                        infoQueries++
                        if (fmt == Ptp.FMT_ASSOCIATION) {
                            val name = runCatching { getObjectInfo(c, h).filename }.getOrDefault("?")
                            infoQueries++
                            val idx = folderIdxByName.getOrPut(name) { folderIdxByName.size }
                            walk(sid, h, depth + 1, idx)
                        } else {
                            files.add(h)
                            fileFolders.add(curFolderIdx)
                        }
                    }
                } else {
                    files.addAll(all)
                    repeat(all.size) { fileFolders.add(curFolderIdx) }
                }
            } else {
                val folderSet = assoc.toHashSet()
                for (h in all) {
                    if (h in folderSet) {
                        val name = runCatching { getObjectInfo(c, h).filename }.getOrDefault("?")
                        infoQueries++
                        val idx = folderIdxByName.getOrPut(name) { folderIdxByName.size }
                        walk(sid, h, depth + 1, idx)
                    } else {
                        files.add(h)
                        fileFolders.add(curFolderIdx)
                    }
                }
            }
        }
        scopes.forEach { walk(it, ROOT_PARENT, 0, -1) }

        val ms = SystemClock.elapsedRealtime() - t0
        log("快速枚举完成：${folderIdxByName.size} 目录 / ${files.size} 文件（ObjectInfo 查询 $infoQueries 次），耗时 ${ms}ms")
        return mapOf(
            "files" to files,
            "fileFolders" to fileFolders,
            "folders" to folderIdxByName.keys.toList(),
            "ms" to ms,
        )
    }

    fun thumbnail(handle: Long): ByteArray = need().getThumbnailBytes(handle)

    /**
     * 存储卡信息：总容量 / 剩余字节 / 还能拍多少张。
     *
     * GetStorageInfo(0x1005) 返回 PTPStorageInfo（libgphoto2 ptp.h 的结构定义）：
     * `[StorageType u16][FilesystemType u16][AccessCapability u16]`
     * `[MaxCapability u64][FreeSpaceInBytes u64][FreeSpaceInImages u32]`
     * `[StorageDescription str][VolumeLabel str]`
     *
     * 多卡机型（Z 系双卡）会有多个存储，返回第一张有容量的卡 + 全部卡片摘要。
     */
    fun storageInfo(): Map<String, Any?> {
        val c = need()
        val ids = runCatching {
            c.transact(Ptp.OP_GET_STORAGE_IDS).data.let { ByteReader(it).u32Array() }.toList()
        }.getOrDefault(emptyList())
        val scopes = if (ids.isEmpty()) listOf(ROOT_PARENT) else ids
        val cards = ArrayList<Map<String, Any?>>()
        for (sid in scopes) {
            val d = runCatching {
                c.transact(Ptp.OP_GET_STORAGE_INFO, longArrayOf(sid)).data
            }.getOrNull() ?: continue
            if (d.size < 26) continue
            val r = ByteReader(d)
            r.u16() // StorageType
            r.u16() // FilesystemType
            r.u16() // AccessCapability
            val maxBytes = r.u32() or (r.u32() shl 32)
            val freeBytes = r.u32() or (r.u32() shl 32)
            val freeImages = r.u32()
            val desc = runCatching { r.str() }.getOrDefault("")
            val label = runCatching { r.str() }.getOrDefault("")
            if (maxBytes <= 0) continue
            cards += mapOf(
                "id" to sid,
                "label" to label,
                "description" to desc,
                "maxBytes" to maxBytes,
                "freeBytes" to freeBytes,
                "freeImages" to freeImages,
            )
        }
        val primary = cards.maxByOrNull { (it["freeBytes"] as? Long) ?: 0L }
        log(
            "存储卡：${cards.size} 个" + (
                primary?.let {
                    "，剩余 ${(it["freeBytes"] as Long) / 1073741824}GB / 可拍 ${it["freeImages"]} 张"
                } ?: "（未取到容量信息）"
                ),
        )
        return mapOf("cards" to cards, "primary" to primary)
    }

    fun battery(): Int {
        val c = need()
        return runCatching {
            val data = c.transact(Ptp.OP_GET_DEVICE_PROP_VALUE, longArrayOf(0x5001)).data
            if (data.isNotEmpty()) data[0].toInt() and 0xFF else -1
        }.getOrDefault(-1)
    }

    // ------------------------------------------------------------ 下载

    private fun mimeFor(name: String): String = when {
        name.endsWith(".jpg", true) || name.endsWith(".jpeg", true) -> "image/jpeg"
        name.endsWith(".nef", true) -> "image/x-nikon-nef"
        name.endsWith(".nrw", true) -> "image/x-nikon-nrw"
        name.endsWith(".mov", true) -> "video/quicktime"
        name.endsWith(".mp4", true) -> "video/mp4"
        name.endsWith(".avi", true) -> "video/avi"
        else -> "application/octet-stream"
    }

    private fun emitProgress(received: Long, total: Long, t0: Long) {
        val now = SystemClock.elapsedRealtime()
        // 先记心跳再判断节流：节流只是少发几次事件，不能影响"链路上还有没有 I/O"的判断
        lastIoAt = now
        if (now - lastProgressEmit < 300 && received < total) return
        lastProgressEmit = now
        val speed = if (now > t0) (received / 1048576.0) / ((now - t0) / 1000.0) else 0.0
        emit(mapOf("type" to "progress", "received" to received, "total" to total, "speedMBps" to speed))
    }

    /** 下载画质变体 */
    const val VARIANT_ORIGINAL = "original"
    const val VARIANT_8M = "8M"
    const val VARIANT_2M = "2M"

    private fun longEdgeFor(variant: String): Int = when (variant) {
        VARIANT_2M -> 1920
        VARIANT_8M -> 3840
        else -> 0
    }

    private fun saveTreeUri(): Uri? {
        val s = appContext!!.getSharedPreferences("nikonsync", Context.MODE_PRIVATE)
            .getString("save_tree", null) ?: return null
        return runCatching { Uri.parse(s) }.getOrNull()
    }

    /**
     * 手机端等比缩放 JPEG 到指定长边。
     *
     * 用 `ImageDecoder`（API 28+，minSdk 29 下恒可用，不引入新依赖），一次解码同时解决
     * 旧实现（BitmapFactory + createScaledBitmap）的两个问题：
     *
     * 1. **Orientation**：`ImageDecoder` 会自动应用 EXIF 方向。旧实现把缩放后的像素直接
     *    `compress`，输出既不带 Orientation 标签、像素也没被摆正 —— 竖拍照片下成 8M/2M 档后
     *    会被相册显示成横的，属于**静默的数据质量缺陷**（原图档不受影响，因为原样落盘）。
     * 2. **内存峰值**：`setTargetSize` 直接按目标尺寸解码，不再需要先解出接近原图的位图
     *    （Z50 II 的 5568×3712 解成 RGBA 约 82MB，且缩放前新旧位图会同时存在）。
     */
    private fun resizeJpeg(src: File, longEdge: Int): ByteArray {
        val bmp = try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(src)) { decoder, info, _ ->
                val w = info.size.width
                val h = info.size.height
                val maxDim = maxOf(w, h)
                if (maxDim > 0 && maxDim > longEdge) {
                    val scale = longEdge.toFloat() / maxDim
                    decoder.setTargetSize(
                        (w * scale).roundToInt().coerceAtLeast(1),
                        (h * scale).roundToInt().coerceAtLeast(1),
                    )
                }
                // 必须是软件位图：硬件位图的像素不能直接读，compress 前会被强制拷贝一份
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        } catch (e: Exception) {
            throw IOException("JPEG 缩放失败：${e.message}")
        }
        val bos = java.io.ByteArrayOutputStream()
        try {
            // 编码失败不能返回半截字节数组（否则会写出损坏的 JPEG）
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, 90, bos)) {
                throw IOException("JPEG 编码失败")
            }
        } finally {
            bmp.recycle()
        }
        return bos.toByteArray()
    }

    /**
     * 下载一个对象。画质：original 原图；2M/8M 仅对 JPEG 生效（手机端缩放）。
     * 保存位置：用户在设置里用 SAF 选过目录则写入该目录，否则写系统相册。
     * 分块模式失败时自动降级整文件下载并重试一次。
     *
     * 该方法只负责置/清"下载进行中"标记，实际逻辑在 [downloadInner]——
     * 保活循环要靠这个标记决定"该不该发探针"（见 [downloadInFlight]）。
     */
    fun download(handle: Long, fileName: String, size: Long, variant: String = VARIANT_ORIGINAL): Map<String, Any?> {
        downloadInFlight = true
        lastIoAt = SystemClock.elapsedRealtime()
        try {
            return downloadInner(handle, fileName, size, variant)
        } finally {
            downloadInFlight = false
            lastIoAt = 0L
        }
    }

    private fun downloadInner(
        handle: Long,
        fileName: String,
        size: Long,
        variant: String = VARIANT_ORIGINAL,
    ): Map<String, Any?> {
        val c = need()
        val ctx = appContext!!
        val isVideo = fileName.endsWith(".mov", true) || fileName.endsWith(".mp4", true) ||
            fileName.endsWith(".avi", true)
        val isImage = fileName.endsWith(".jpg", true) || fileName.endsWith(".jpeg", true) ||
            fileName.endsWith(".nef", true) || fileName.endsWith(".nrw", true)
        val mime = mimeFor(fileName)
        val relPath = if (isVideo) "Movies/NikonSync" else "Pictures/NikonSync"
        val longEdge = longEdgeFor(variant)
        val needResize = longEdge > 0 && mime == "image/jpeg"
        val resolver = ctx.contentResolver
        val treeUri = saveTreeUri()
        log("开始下载 $fileName（%.1fMB${if (needResize) " · 缩放至 $longEdge px" else ""}）".format(size / 1048576.0))

        var tempFile: File? = null
        var attempt = 0
        while (true) {
            var created: Uri? = null
            var isSafDoc = false
            try {
                val t0 = SystemClock.elapsedRealtime()
                var resized: ByteArray? = null
                if (needResize) {
                    val tmp = File(ctx.cacheDir, "dl_${System.currentTimeMillis()}.jpg")
                    tempFile = tmp
                    java.io.FileOutputStream(tmp).use { out ->
                        c.getObjectToStream(handle, size, out) { r, t -> emitProgress(r, t, t0) }
                    }
                    resized = resizeJpeg(tmp, longEdge)
                    tmp.delete()
                    tempFile = null
                }

                if (treeUri != null) {
                    // SAF 自定义目录
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri, DocumentsContract.getTreeDocumentId(treeUri),
                    )
                    val doc = DocumentsContract.createDocument(resolver, docUri, mime, fileName)
                        ?: throw IOException("在所选目录创建文件失败")
                    created = doc
                    isSafDoc = true
                    val outSaf = resolver.openOutputStream(doc) ?: throw IOException("打开所选目录输出流失败")
                    // written 是实际落盘的字节数：分块模式少传时 getObjectToStream 会抛异常，
                    // 绝不会把截断的文件当成成功返回。
                    val written = outSaf.use { out ->
                        if (resized != null) {
                            out.write(resized)
                            resized.size.toLong()
                        } else {
                            c.getObjectToStream(handle, size, out) { r, t -> emitProgress(r, t, t0) }
                        }
                    }
                    val ms = SystemClock.elapsedRealtime() - t0
                    val speed = if (ms > 0) (written / 1048576.0) / (ms / 1000.0) else 0.0
                    log("下载完成：$fileName → 自定义目录（$written 字节，%.1f MB/s）".format(speed))
                    emit(mapOf("type" to "progress", "received" to written, "total" to written, "speedMBps" to speed))
                    return mapOf(
                        "uri" to doc.toString(),
                        "bytes" to written,
                        "ms" to ms,
                        "speedMBps" to speed,
                        "path" to "所选目录/$fileName",
                        "variant" to variant,
                    )
                }

                // 系统相册 MediaStore
                val collection = when {
                    isVideo -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    isImage -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                }
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore 创建文件失败")
                created = uri
                val outMs = resolver.openOutputStream(uri) ?: throw IOException("打开输出流失败")
                val written = outMs.use { out ->
                    if (resized != null) {
                        out.write(resized)
                        resized.size.toLong()
                    } else {
                        c.getObjectToStream(handle, size, out) { r, t -> emitProgress(r, t, t0) }
                    }
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                val ms = SystemClock.elapsedRealtime() - t0
                val speed = if (ms > 0) (written / 1048576.0) / (ms / 1000.0) else 0.0
                log("下载完成：$fileName → $relPath（$written 字节，%.1f MB/s）".format(speed))
                emit(mapOf("type" to "progress", "received" to written, "total" to written, "speedMBps" to speed))
                return mapOf(
                    "uri" to uri.toString(),
                    "bytes" to written,
                    "ms" to ms,
                    "speedMBps" to speed,
                    "path" to "$relPath/$fileName",
                    "variant" to variant,
                )
            } catch (e: CancelledException) {
                // 用户取消：删掉半成品后原样上抛，**不走降级重试**——
                // 若落到下面的通用分支，取消会变成"换个模式再传一遍"，与用户意图相反。
                runCatching { tempFile?.delete() }
                if (created != null) {
                    if (isSafDoc) runCatching { DocumentsContract.deleteDocument(resolver, created) }
                    else runCatching { resolver.delete(created, null, null) }
                }
                log("下载已取消：$fileName（半成品已删除）")
                throw e
            } catch (e: Exception) {
                runCatching { tempFile?.delete() }
                if (created != null) {
                    if (isSafDoc) runCatching { DocumentsContract.deleteDocument(resolver, created) }
                    else runCatching { resolver.delete(created, null, null) }
                }
                attempt++
                // 降级条件不能只看 PtpException：分块提前结束抛的是 IOException，
                // 而那恰恰是最该退回整文件下载的情形。
                if (attempt == 1 && c.effectiveDlMode != PtpSession.DlMode.FULL) {
                    log("下载失败（$fileName）：${e.message}；改用整文件下载重试")
                    c.degradeToFullDownload()
                    continue
                }
                throw e
            }
        }
    }

    /**
     * 请求取消当前下载。
     *
     * 中断发生在**传输层的分块/读块边界**（见 `PtpSession.requestCancelDownload`）：
     * `getObjectToStream` 是一次阻塞调用，Dart 侧传进来的取消回调到不了循环内部，
     * 所以取消标志必须设在 Kotlin 侧。返回 false 表示当前没有活动连接。
     */
    fun cancelDownload(): Boolean {
        val c = client ?: return false
        return runCatching {
            c.requestCancelDownload()
            true
        }.getOrDefault(false)
    }

    // ------------------------------------------------------------ 相机文件管理

    /** 删除相机上的文件（0x100B，下载验证成功后再调用）。 */
    fun deleteObject(handle: Long) {
        need().transact(Ptp.OP_DELETE_OBJECT, longArrayOf(handle))
        log("已删除相机文件 handle=$handle")
    }

    /** 保护/取消保护相机文件（0x1012，protection: 1=保护 0=取消）。 */
    fun protectObject(handle: Long, protection: Int) {
        need().transact(Ptp.OP_SET_OBJECT_PROTECTION, longArrayOf(handle, protection.toLong()))
        log("相机文件 handle=$handle ${if (protection == 1) "已保护" else "已取消保护"}")
    }

    // ------------------------------------------------------------ 遥控拍摄 / 实时取景

    @Volatile var liveViewOn = false
        internal set

    /** InitiateCapture 实际可用的参数形态（空参失败后尝试 全存储+默认格式）。 */
    @Volatile private var captureParams: LongArray? = null

    /** 驱动 AF 后留给镜头合焦的时间。发完 0x90C3 只代表指令被接受，不代表已合焦。 */
    private const val AF_SETTLE_MS = 1_200L

    /**
     * "相机忙"之后的退避间隔。
     * 不能短：对焦优先机型在 AF 搜索期间会一直返回 DeviceBusy，
     * 而**反复按快门会打断并重启 AF**——原来每 500ms 重试一次，
     * 结果是永远等不到合焦，连试 25 秒后报一句与真实原因无关的"相机忙碌"。
     */
    private const val BUSY_RETRY_MS = 1_500L

    /** 快门忙等总预算。原为 25s，太长且没有信息量；8s 足够覆盖一次正常的 AF 合焦。 */
    private const val CAPTURE_BUDGET_MS = 8_000L

    /** 中等图（0x920F）专用超时：相机要现渲染，但超过这个时间就回退缩略图，别让用户干等。 */
    private const val FHD_TIMEOUT_MS = 6_000

    /** 对焦优先导致拒拍的说明与处理办法（相机侧可关，所以要把菜单路径写清楚）。 */
    private const val FOCUS_PRIORITY_HINT =
        "原因通常是相机开启了「未对焦时禁止拍摄」（对焦优先）：对焦没锁定，相机就不会释放快门。\n" +
            "处理办法（任选其一）：\n" +
            "· 把相机对准有明暗/线条对比的目标再拍——对着纯色墙面或无纹理物体，AF 永远对不上\n" +
            "· 先点遥控页的「对焦」按钮，等画面合焦后再按拍摄\n" +
            "· 相机端改为释放优先：自定义设定菜单 → a1 AF-C 优先选择 / a2 AF-S 优先选择 → 选「释放」\n" +
            "· 或把镜头切到手动对焦（MF），相机就不再检查对焦"

    /**
     * 相机待机（屏幕灭）导致的拒绝。
     *
     * 真机证据（2026-09-15 23:28）：待机状态下 `0x100E` 连续 DeviceBusy 到预算耗尽，
     * 报出来的却是"未对焦"——**表象与对焦优先完全一样**，所以这条必须一起说，
     * 否则用户会一直去调对焦设置却始终拍不了。
     */
    private const val STANDBY_HINT =
        "另一种可能是相机已进入待机（屏幕熄灭）：此时快门同样会被拒。\n" +
            "· 按一下相机任意按钮唤醒后再拍；\n" +
            "· 长期方案：相机菜单把「电源关闭延迟」调长（本机 Wi-Fi 模式下 App 改不了它）"

    /** 向遥控页上报拍摄阶段，让等待过程有解释（对焦 / 快门）。 */
    private fun emitPhase(phase: String) = emit(mapOf("type" to "capturePhase", "phase" to phase))

    /** 实际生效的取景帧操作码（0x9202 / 0x9203 自动探测）。 */
    fun liveViewStart(): Map<String, Any?> {
        val c = need()
        if (liveViewOn) return mapOf("ok" to true)
        // 首次启动相机可能初始化较久（要切显示通道）：先 3s 快试，失败再用 8s。
        var last: Exception? = null
        for (timeout in intArrayOf(3_000, 8_000)) {
            try {
                c.transactShort(Ptp.OP_NIKON_LV_START, LongArray(0), timeout)
                liveViewOn = true
                log("实时取景已启动（0x9201，超时 ${timeout}ms）")
                return mapOf("ok" to true)
            } catch (e: Exception) {
                last = e
                log("实时取景启动未成功（超时 ${timeout}ms）：${e.message}")
            }
        }
        // 绝不吞掉失败：此前两次 runCatching 都失败仍置 liveViewOn=true 并返回 ok，
        // 于是遥控页永远停在"等待取景画面…"，用户拿不到任何可行动的信息（交接文档 §19）。
        throw IOException("实时取景启动失败：${last?.message ?: "相机未响应"}")
    }

    fun liveViewStop() {
        val c = client ?: return
        if (!liveViewOn) return
        // EndLiveView 按 libgphoto2 是 0x9202（旧代码用的 0x9206 实为 AfDriveCancel，
        // 不会真正结束取景，只取消 AF）。先 0x9202，被拒再退回 0x9206，并记录哪个生效。
        val primary = runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 2000) }
        var how = "0x9202"
        if (primary.isFailure) {
            val legacy = runCatching { c.transactShort(Ptp.OP_NIKON_AF_DRIVE_CANCEL, LongArray(0), 2000) }
            how = if (legacy.isFailure) {
                "两者均未确认（0x9202：${primary.exceptionOrNull()?.message}）"
            } else "0x9206（0x9202 被拒：${primary.exceptionOrNull()?.message}）"
        }
        // 无论相机是否应答都按"已关闭"处理：否则标志位留在 true，会挡住下一次启动
        liveViewOn = false
        log("实时取景已关闭（$how）")
    }

    /**
     * 强制重进取景：**先真的结束再启动**，忽略缓存的 [liveViewOn]。
     *
     * 为什么不能只重复发 0x9201：真机日志里出现过「0x9201 返回成功、但随后的
     * 0x9203 一直 NotLiveView」的半死状态——此时 `liveViewOn` 被置为 true，
     * 后续的 [liveViewStart] 直接短路返回 ok，取景永远回不来，而取帧循环还在
     * 以每秒 8 次的频率打错误日志（实测把 logcat 缓冲冲掉了，反而丢失证据）。
     */
    fun liveViewRestart(): Map<String, Any?> {
        val c = client ?: throw IOException("未连接相机")
        // 先叫一声：相机屏幕息屏后 0x9201 会"成功但不出帧"，DeviceReady 是
        // libgphoto2 里等相机从忙/休眠恢复用的操作。
        val woke = wakeUp()
        if (!woke) log("唤醒无应答，仍继续尝试重进取景")
        runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 2000) }
        liveViewOn = false
        // 250ms 太短：真机日志里出现过 EndLiveView 之后立刻 StartLiveView 被忽略
        // （0x9201 超时），而重试几次后又能成功——相机释放显示通道需要时间。
        Thread.sleep(600)
        var last: Exception? = null
        for (timeout in intArrayOf(4_000, 8_000, 8_000)) {
            try {
                c.transactShort(Ptp.OP_NIKON_LV_START, LongArray(0), timeout)
                liveViewOn = true
                log("实时取景已重启（0x9202 → 0x9201，超时 ${timeout}ms）")
                return mapOf("ok" to true)
            } catch (e: Exception) {
                last = e
                log("重进取景未成功（超时 ${timeout}ms）：${e.message}")
                Thread.sleep(400)
            }
        }
        throw IOException("重新进入实时取景失败：${last?.message ?: "相机未响应"}")
    }

    /** 拉取一帧实时取景 JPEG（0x9203；未启动时返回 NotLiveView 错误）。 */
    fun liveViewFrame(): ByteArray {
        val c = need()
        // 超时放宽到 3 秒：一次超时会让命令流永久错位、连接作废（见 PtpIpClient），
        // 不能因为取景热身期单帧慢就误杀整条连接。
        // 上层的取帧循环另有最小间隔，避免把相机逼到超时。
        val data = c.transactShort(Ptp.OP_NIKON_LV_FRAME, LongArray(0), 3000).data
        liveViewOn = true
        // 帧数据若带头部，从 JPEG SOI 标记截断
        val soi = indexOfSoi(data)
        // 头部诊断（每会话一次）：尼康取景帧在 JPEG 之前有一段头部，很可能带**实时
        // 拍摄信息**（相机自己算出来的 ISO/光圈/快门）。属性 0x500F 在 Auto ISO 下
        // 不反映实际值——真机上就是"相机屏幕显示 ISO AUTO 2500、App 停在 2000"。
        // 把这段 hex 与相机屏幕对齐，就能确认头部里有没有实时 ISO。
        if (!lvHeaderLogged) {
            lvHeaderLogged = true
            val head = data.copyOfRange(0, minOf(maxOf(soi, 0) + 2, 64).coerceAtMost(data.size))
            val dims = jpegSizeText(data)
            if (soi > 0) {
                parseLvHeader(data.copyOfRange(0, soi), dims)
            } else {
                log("取景帧无头部（第 0 字节就是 JPEG SOI，尺寸 $dims）：" +
                    head.joinToString(" ") { "%02X".format(it) })
            }
        }
        return if (soi > 0) data.copyOfRange(soi, data.size) else data
    }

    @Volatile private var lvHeaderLogged = false

    /**
     * 解析取景帧头部（实测 384 字节，**大端 u16**），算出对焦坐标倍数。
     *
     * 真机头部实测（APK 2037 日志，按 u16 大端逐字段读）：
     * ```
     * off  8: 640    off 10: 424     ← 取景帧尺寸（与 JPEG SOF 一致）
     * off 12: 5568   off 14: 3712    ← 相机图像尺寸（Z50 II 有效像素）
     * off 16: 5568   off 18: 3712    ← 重复一次
     * off 20: 2784   off 22: 1856    ← 相机图像的一半
     * off 28: 5160   off 30: 3331    ← AF 覆盖范围（约 93% × 90%，因此边缘几%会被夹到最近对焦点）
     * ```
     *
     * `0x9205 ChangeAfArea` 的坐标空间就是**相机图像尺寸**：
     * 用户实测"×8 大致与相机一致"（真值 5568/640 = 8.70），
     * 且日志里出现过 x=5831（>5568，说明超出会被夹边界而非报错）。
     * 所以倍数 = 相机图像尺寸 ÷ 取景帧尺寸，**x / y 各算一次**（两者并不完全相等：
     * 8.70 与 8.755，因为 640×424 不是 5568×3712 的严格等比缩放）。
     */
    private fun parseLvHeader(header: ByteArray, lvDims: String) {
        fun u16(i: Int) = ((header[i].toInt() and 0xFF) shl 8) or (header[i + 1].toInt() and 0xFF)
        val lvW = lvDims.substringBefore('×').toIntOrNull() ?: 0
        val lvH = lvDims.substringAfter('×').toIntOrNull() ?: 0
        if (lvW <= 0 || lvH <= 0) {
            log("取景头部解析：读不到取景帧尺寸（$lvDims），沿用人工标定倍数")
            return
        }
        var i = 0
        while (i + 4 <= header.size) {
            if (u16(i) == lvW && u16(i + 2) == lvH) {
                var j = i + 4
                while (j + 4 <= header.size) {
                    val w = u16(j)
                    val h = u16(j + 2)
                    // 取景帧尺寸之后的第一对"明显更大的合法尺寸" = 相机图像尺寸
                    if (w > lvW && h > lvH && w in 1000..30000 && h in 1000..30000) {
                        afAutoScaleX = w.toDouble() / lvW
                        afAutoScaleY = h.toDouble() / lvH
                        afAutoInfo = "取景帧 ${lvW}×${lvH} → 相机图像 ${w}×$h"
                        log(
                            "取景头部解析：$afAutoInfo，对焦坐标倍数 ×%.2f（x）×%.2f（y）"
                                .format(afAutoScaleX, afAutoScaleY),
                        )
                        return
                    }
                    j += 2
                }
            }
            i += 2
        }
        log("取景头部解析：未找到相机图像尺寸（头部 ${header.size}B），沿用人工标定倍数")
    }

    /** 自动算出的对焦倍数（0 = 未取到） */
    @Volatile private var afAutoScaleX = 0.0

    @Volatile private var afAutoScaleY = 0.0

    @Volatile private var afAutoInfo = ""

    /** 供 Dart 侧读取：自动对焦倍数（来自取景帧头部） */
    fun afScaleFromHeader(): Map<String, Any?> = mapOf(
        "ok" to (afAutoScaleX > 0 && afAutoScaleY > 0),
        "scaleX" to afAutoScaleX,
        "scaleY" to afAutoScaleY,
        "info" to afAutoInfo,
    )

    /**
     * 取景帧头部完整 dump（调试面板用，只读）。
     * 头部很可能带实时 ISO/光圈/快门（Auto ISO 下属性 0x500F 报的不是实时值），
     * 把 384 字节全打出来，与相机屏幕上的数字对齐即可确认字段位置。
     */
    fun probeLvHeader(): List<String> {
        val c = need()
        val data = c.transactShort(Ptp.OP_NIKON_LV_FRAME, LongArray(0), 3000).data
        val soi = indexOfSoi(data)
        if (soi <= 0) return listOf("本帧没有头部（第 0 字节即 JPEG SOI，尺寸 ${jpegSizeText(data)}）")
        val h = data.copyOfRange(0, soi)
        val out = ArrayList<String>()
        out += "头部 ${soi}B（u16 大端逐字段）："
        for (i in 0 until soi - 1 step 2) {
            val v = ((h[i].toInt() and 0xFF) shl 8) or (h[i + 1].toInt() and 0xFF)
            out += "  off $i = $v"
        }
        out += "JPEG 尺寸 ${jpegSizeText(data)}"
        out.forEach { CameraEngine.log("取景头部 $it") }
        return out
    }

    /** 取景帧 JPEG 的宽高（诊断日志用；解析不出返回空串）。 */
    internal fun jpegSizeText(d: ByteArray): String {
        var i = indexOfSoi(d)
        if (i < 0) return ""
        i += 2
        while (i + 9 < d.size) {
            if (d[i] != 0xFF.toByte()) {
                i++
                continue
            }
            val marker = d[i + 1].toInt() and 0xFF
            val len = ((d[i + 2].toInt() and 0xFF) shl 8) or (d[i + 3].toInt() and 0xFF)
            // SOF0~SOF15（排除 DHT/JPG/DAC 三个非 SOF 标记）
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                val h = ((d[i + 5].toInt() and 0xFF) shl 8) or (d[i + 6].toInt() and 0xFF)
                val w = ((d[i + 7].toInt() and 0xFF) shl 8) or (d[i + 8].toInt() and 0xFF)
                return "$w×$h"
            }
            if (len <= 0) break
            i += 2 + len
        }
        return ""
    }

    internal fun indexOfSoi(data: ByteArray): Int {
        for (i in 0 until data.size - 1) {
            if (data[i] == 0xFF.toByte() && data[i + 1] == 0xD8.toByte()) return i
        }
        return -1
    }

    /** 遥控快门（0x100E 拍到卡上）。实时取景中相机可能报忙：自动 停取景→拍→恢复取景。 */
    fun capture(): Map<String, Any?> {
        val c = need()
        drainCheckEvents()
        // 先叫一声。真机证据（2026-09-15 23:28）：相机待机（屏幕灭）后连快门也会被拒，
        // 日志是连续 DeviceBusy 到 9 秒预算耗尽、最终报"未对焦"，用户看到的是
        // "盲拍点不动"。待机与对焦失败的表象一样，先唤醒可以少一类误判。
        if (!wakeUp()) log("拍摄前唤醒无应答（相机可能已待机）")
        // 对焦优先机型：先驱动一次 AF 并**等它稳定**，再按快门。
        // 否则相机会在 AF 搜索期间返回 DeviceBusy，而重试又会打断 AF，形成死循环。
        if (isManualFocus() != true && afDriveBlocking(c)) {
            emitPhase("af")
            Thread.sleep(AF_SETTLE_MS)
        }
        emitPhase("shutter")
        var busyCount = 0
        var recovered = false
        val t0 = SystemClock.elapsedRealtime()
        while (true) {
            try {
                c.transact(Ptp.OP_INITIATE_CAPTURE, captureParams ?: LongArray(0))
                captureParams = captureParams ?: LongArray(0)
                break
            } catch (e: PtpException) {
                // 未对焦：相机已明确告知对焦没锁上，直接给结论，不再重试
                if (e.code == 0xA004) {
                    log("快门被拒：未完成对焦（0xA004）")
                    throw IOException("未完成对焦，快门未释放。\n$FOCUS_PRIORITY_HINT")
                }
                val busy = e.code == Ptp.RESP_DEVICE_BUSY || e.code == 0x2002
                if (busy) {
                    busyCount++
                    val elapsed = SystemClock.elapsedRealtime() - t0
                    if (elapsed > CAPTURE_BUDGET_MS) {
                        throw IOException(
                            "快门在 ${elapsed / 1000}s 内始终未被释放（相机一直处于忙碌/未对焦）。\n" +
                                STANDBY_HINT + "\n" + FOCUS_PRIORITY_HINT,
                        )
                    }
                    log("相机忙（${Ptp.respName(e.code)}）第 $busyCount 次，已 ${elapsed / 1000}s")
                    // SDRAM 待取图像假说：上一张未取走会让快门持续被拒
                    if (busyCount == 2) {
                        val info = runCatching {
                            c.transact(Ptp.OP_GET_OBJECT_INFO, longArrayOf(0xFFFF0001L)).data
                        }.getOrNull()
                        if (info != null && info.size > 8) {
                            log("发现 SDRAM 待取图像（0xFFFF0001），通知读取")
                            emit(mapOf("type" to "objectAdded", "handle" to 0xFFFF0001L))
                        }
                    }
                    // 疑似误入实时取景状态：尝试退出恢复拍摄
                    if (busyCount == 3 && !recovered) {
                        recovered = true
                        val ok = runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 2000) }.isSuccess
                        log(if (ok) "已尝试退出实时取景，恢复拍摄" else "退出取景无效，跳过恢复")
                    }
                    drainCheckEvents()
                    runCatching { c.transact(Ptp.OP_NIKON_DEVICE_READY) }
                    Thread.sleep(BUSY_RETRY_MS)
                    continue
                }
                if (captureParams == null && e.code in intArrayOf(0x2005, 0x2006, 0x2007)) {
                    log("空参快门被拒（${Ptp.respName(e.code)}），尝试 全存储+默认格式 参数")
                    captureParams = longArrayOf(0xFFFFFFFFL, 0)
                    continue
                }
                throw e
            }
        }
        emitPhase("done")
        log("遥控快门已触发")
        // 拍后异步排水：相机事件队列里通常有待处理的新照片事件
        Thread {
            var i = 0
            while (i < 15 && client != null) {
                drainCheckEvents()
                runCatching { Thread.sleep(800) }
                i++
            }
        }.apply { isDaemon = true; name = "post-capture-drain"; start() }
        return mapOf("ok" to true)
    }
    /**
     * 取景中拍摄：0x100E 标准快门优先（取景中实测可能仍可用），
     * 被拒则尝试 0x9405（疑似取景中 AF/拍摄），再回 0x100E 重试。
     * 0xA004 = 未对焦（对焦优先），明确提示。
     */
    fun lvCapture(): Map<String, Any?> {
        val c = need()
        if (!liveViewOn) throw IOException("实时取景未开启")
        // 与盲拍同一策略：先驱动一次 AF 并等它稳定，再按快门。
        // 取景中驱动 AF 后立刻按快门，会撞上相机正在对焦的忙碌窗口。
        if (isManualFocus() != true && afDriveBlocking(c)) {
            emitPhase("af")
            Thread.sleep(AF_SETTLE_MS)
        }
        emitPhase("shutter")
        var attempt = 0
        val t0 = SystemClock.elapsedRealtime()
        while (true) {
            try {
                c.transact(Ptp.OP_INITIATE_CAPTURE, captureParams ?: LongArray(0))
                captureParams = captureParams ?: LongArray(0)
                emitPhase("done")
                log("取景中快门已触发（0x100E）")
                return mapOf("ok" to true)
            } catch (e: PtpException) {
                if (e.code == 0xA004) {
                    throw IOException("相机对焦未锁定，快门未释放。\n$FOCUS_PRIORITY_HINT")
                }
                val busy = e.code == Ptp.RESP_DEVICE_BUSY || e.code == 0x2002
                val paramErr = captureParams == null && e.code in intArrayOf(0x2005, 0x2006, 0x2007)
                attempt++
                val elapsed = SystemClock.elapsedRealtime() - t0
                if (!busy && !paramErr) throw e
                if (elapsed > CAPTURE_BUDGET_MS) {
                    throw IOException(
                        "快门在 ${elapsed / 1000}s 内始终未被释放。\n$STANDBY_HINT\n$FOCUS_PRIORITY_HINT",
                    )
                }
                when (attempt) {
                    1 -> {
                        // 兜底改走 0x9207 InitiateCaptureRecInMedia（libgphoto2 注释：
                        // 参数 [0xFFFFFFFE=拍前对焦, 0=写卡]）。这是**真正会拍摄**的操作，
                        // 用在这里是正当的（用户按的就是快门），但绝不能当探针用。
                        // 旧代码这里发的是 0x9405 = MeasureSpotWb（点测白平衡），
                        // 既不会拍照也会启动白平衡测量，纯副作用。
                        val r = runCatching {
                            c.transact(
                                Ptp.OP_NIKON_CAPTURE_REC_IN_MEDIA,
                                longArrayOf(0xFFFFFFFEL, 0L),
                            )
                        }
                        log(
                            "取景中 0x9207（对焦后拍摄到卡）尝试 → " +
                                if (r.isSuccess) "OK" else
                                    Ptp.respName((r.exceptionOrNull() as? PtpException)?.code ?: -1),
                        )
                        if (r.isSuccess) {
                            captureParams = captureParams ?: LongArray(0)
                            emitPhase("done")
                            return mapOf("ok" to true)
                        }
                    }
                    2 -> {
                        // 再驱动一次 AF（0x90C1）
                        runCatching { c.transact(Ptp.OP_NIKON_AF_DRIVE) }
                    }
                    3 -> {
                        if (paramErr) {
                            captureParams = longArrayOf(0xFFFFFFFFL, 0)
                            log("尝试 全存储+默认格式 参数")
                        }
                    }
                }
                // 长间隔：与盲拍同理，短间隔重试会打断相机的对焦搜索
                Thread.sleep(BUSY_RETRY_MS)
            }
        }
    }


    // ---- 厂商事件队列排水（0x90C7 GetEvent / 0x941C GetEventEx 自适应）----

    @Volatile private var checkEventOp: Long = 0
    @Volatile private var drainFailLogged = false

    private fun drainCheckEvents() {
        val c = client ?: return
        // ⚠️ 候选表此前是 [0x90C1, 0x90C0]：**两个都是错的且都有副作用**——
        // 0x90C1 其实是 AF Drive（等于每次保活/拍摄都在驱动对焦），
        // 0x90C0 是"拍摄到 SDRAM"（拍摄类操作，绝不能放在探针候选里）。
        // 正确的取厂商事件队列是 0x90C7 GetEvent / 0x941C GetEventEx，均为只读。
        val candidates = linkedSetOf(
            if (checkEventOp != 0L) checkEventOp else Ptp.OP_NIKON_GET_EVENT.toLong(),
            Ptp.OP_NIKON_GET_EVENT.toLong(),
            Ptp.OP_NIKON_GET_EVENT_EX.toLong(),
        )
        for (op in candidates) {
            val d = runCatching { c.transact(op.toInt()).data }.getOrNull()
            if (d == null) continue
            checkEventOp = op
            parseCheckEvents(d)
            return
        }
        if (!drainFailLogged) {
            drainFailLogged = true
            log("事件排水：0x90C7/0x941C 均无响应（该模式不支持厂商事件队列，仅提示一次）")
        }
    }

    /**
     * 解析厂商事件队列（0x90C7 GetEvent）的返回数据。
     *
     * **格式（2026-09-15 第三轮真机实证，抄自日志 hex）**：
     * `[u16 条数] + N × ([u16 事件码][u32 参数])`
     *
     * ```
     * 04 00 | 06 40 A2 D1 00 00 | 06 40 BB D1 00 00 | 06 40 …
     *  ↑count=4   ↑ 0x4006 param=0xD1A2（厂商属性变化）
     * ```
     * 旧实现把条数按 u32 读 → 每次都得到 1074135044 这种垃圾值（那是
     * `0x4006` 与参数高 16 位被拼进了同一个 u32），于是这条队列一直"无法解析"、
     * 等于没有排水能力。修正后这条通道才真正可用。
     *
     * 日志策略：厂商属性变化（0x4006）在相机空闲时 1 秒能推好几条，逐条记会刷屏，
     * 因此只计数；其它事件逐条记并附带 ObjectAdded 转发。
     */
    private fun parseCheckEvents(data: ByteArray) {
        if (data.size < 2) return
        val r = ByteReader(data)
        val count = r.u16()
        // count=0 是最常见的情况（"当前没有事件"），真机上它占了排水日志的一大半，
        // 静默返回即可——它不是解析错误。
        if (count == 0) return
        if (count > 512) {
            val hex = data.take(16).joinToString(" ") { "%02X".format(it) }
            log("厂商事件队列无法解析（count=$count）：$hex")
            return
        }
        var i = 0
        var propChanges = 0
        val notable = ArrayList<String>()
        while (i < count && r.remaining >= 6) {
            val code = r.u16()
            val param = r.u32()
            i++
            if (code == Ptp.EVT_DEVICE_PROP_CHANGED) {
                propChanges++
                lastEventAt = SystemClock.elapsedRealtime()
            } else {
                notable += "${Ptp.evtName(code)} $param"
                if (code == Ptp.EVT_OBJECT_ADDED && param != 0L) {
                    emit(mapOf("type" to "objectAdded", "handle" to param))
                }
            }
        }
        if (notable.isNotEmpty()) {
            log("厂商事件队列：${notable.joinToString("，")}（另有 $propChanges 条属性变化）")
        }
    }

    // ---- 对焦辅助（对焦优先相机：未对焦时快门被拒，必须先驱动 AF）----

    @Volatile private var afDriveOp: Long = 0

    private fun ptpValue(r: ByteReader, dtype: Int): Long? = when (dtype) {
        0x0001, 0x0002 -> r.u8().toLong()
        0x0003, 0x0004 -> r.u16().toLong()
        0x0005, 0x0006 -> r.u32()
        0x0007 -> { r.u32(); r.u32() }
        else -> null
    }

    private fun propDescCurrent(c: PtpSession, code: Long): Long? = runCatching {
        val d = c.transact(Ptp.OP_GET_DEVICE_PROP_DESC, longArrayOf(code)).data
        if (d.size < 8) return@runCatching null
        val r = ByteReader(d)
        r.u16() // 属性码
        val dtype = r.u16()
        r.u8()  // GetSet
        ptpValue(r, dtype) // 出厂默认值（跳过）
        ptpValue(r, dtype) // 当前值
    }.getOrNull()

    /** 对焦模式：true=手动对焦（MF，跳过 AF），false=自动对焦，null=未知 */
    fun isManualFocus(): Boolean? {
        val c = need()
        return runCatching {
            propDescCurrent(c, 0x500A) == 1L // PTP FocusMode: 1=Manual
        }.getOrNull()
    }

    /**
     * AF 驱动，成功返回 true，失败把原因写成日志并返回 false。
     *
     * **操作码 = 0x90C1（libgphoto2 ptp.h: `PTP_OC_NIKON_AfDrive`，无参数）。**
     *
     * 两个历史误用（真机日志与属性 Dump 已双向确认）：
     * - `0x90C3` 是 DelImageSDRAM(1 参数)，无参调用必返回 ParameterNotSupported——
     *   这正是"点击取景框对焦"报 `PTP ParameterNotSupported: 操作 0x90C3` 的原因；
     * - `0x9125` 是佳能 EOS 的 BulbStart（我上一轮被 wmu_audit 里那行括号注释误导），
     *   尼康上不会生效。
     *
     * 失败不写进 [afDriveOp] 缓存：实测同一会话里"拍摄流可用 / 取景中被拒"，
     * 缓存一次失败会毒化整个会话的 AF（原实现就是这么坏的）。
     */
    private fun afDriveWithReason(c: PtpSession): String? {
        val attempts = ArrayList<Int>()
        if (afDriveOp != 0L) attempts.add(afDriveOp.toInt())
        attempts.add(Ptp.OP_NIKON_AF_DRIVE)
        // 兜底：取景中可先取消上一次 AF 再驱动（0x9206 是 AfDriveCancel，无参数）
        val lastReason = afTryAll(c, attempts)
        if (lastReason == null) return null
        if (liveViewOn) {
            val cancel = runCatching { c.transact(Ptp.OP_NIKON_AF_DRIVE_CANCEL) }
            if (cancel.isSuccess) {
                val again = runCatching { c.transact(Ptp.OP_NIKON_AF_DRIVE) }
                if (again.isSuccess) {
                    afDriveOp = Ptp.OP_NIKON_AF_DRIVE.toLong()
                    log("AF 驱动：取消上一次 AF 后 0x90C1 成功")
                    return null
                }
            }
        }
        return lastReason
    }

    /** 依次尝试候选操作码，成功返回 null，全部失败返回最后一个原因。 */
    private fun afTryAll(c: PtpSession, attempts: List<Int>): String? {
        var lastReason = "相机未响应"
        for (op in attempts.distinct()) {
            val r = runCatching { c.transact(op) }
            if (r.isSuccess) {
                if (afDriveOp != op.toLong()) {
                    afDriveOp = op.toLong()
                    log("AF 驱动：0x%04X 记录为可用".format(op))
                }
                return null
            }
            // PtpException.message 已含响应码名（Ptp.respName），足以区分
            // OperationNotSupported（码不对）与 ParameterNotSupported（缺参数）
            lastReason = r.exceptionOrNull()?.message ?: "未知错误"
            log("AF 驱动 0x%04X 被拒：%s".format(op, lastReason))
        }
        return lastReason
    }

    private fun afDriveBlocking(c: PtpSession): Boolean = afDriveWithReason(c) == null

    /**
     * 指定对焦区域并驱动 AF（点击取景画面）。
     *
     * `0x9205` ChangeAfArea（libgphoto2 ptp.h：**2 参数 x, y**）—— 此前只驱动 AF、
     * 不指定区域，所以"点哪儿都是中心对焦"，用户反馈的"点屏幕指定对焦不成功"正是这个。
     * 坐标系按取景画面的像素坐标传入（调用方已把屏幕点击点换算回帧坐标）。
     * 若相机拒绝坐标（InvalidParameter 等），回退为"驱动当前 AF 区域"并如实上报。
     */
    fun afArea(x: Int, y: Int): Map<String, Any?> {
        val c = need()
        val r = runCatching {
            c.transact(Ptp.OP_NIKON_CHANGE_AF_AREA, longArrayOf(x.toLong(), y.toLong()))
        }
        if (r.isFailure) {
            val why = r.exceptionOrNull()?.message ?: "未知错误"
            log("指定对焦区域 [$x,$y] 被拒：$why，回退为当前 AF 区域")
            val reason = afDriveWithReason(c)
            return mapOf(
                "ok" to (reason == null), "area" to false,
                "reason" to reason, "areaError" to why,
            )
        }
        log("已指定对焦区域 [$x,$y]（0x9205）")
        lastAfArea = longArrayOf(x.toLong(), y.toLong())
        val reason = afDriveWithReason(c)
        return mapOf("ok" to (reason == null), "area" to true, "reason" to reason)
    }

    /** 手动触发一次 AF（遥控页「对焦」按钮 / 取景窗点击对焦）。 */
    fun afDrive(): Map<String, Any?> {
        val c = need()
        val reason = afDriveWithReason(c)
        if (reason != null) log("手动对焦失败：$reason")
        return mapOf("ok" to (reason == null), "reason" to reason)
    }

    // ------------------------------------------------------------ 拍摄参数（描述符 + 设置）

    private data class PropDialect(
        val fNumber: Long, val exposureTime: Long, val iso: Long, val mode: Long?,
    )

    /**
     * 设备属性码方言。
     *
     * **2026-09-15 第三轮修正**：此前认为"Wi-Fi 智能设备模式是尼康裁剪方言
     * （0x500D=光圈 / 0x500E=快门 / 0x500F=ISO）"，这是**错的**——证据来自
     * 「属性码Dump」真机输出（交接文档 §20）：
     * ```
     * 0x5007 只读 当前=710  枚举[170,180,…,1600]        ← 光圈级数 ×100（f/1.7…f/16）
     * 0x500D 可写 当前=3333 枚举[2,3,…,300000]           ← 快门 1/10000 秒
     * 0x500E 只读 当前=4    枚举[1,2,3,4,32784,…]        ← ExposureProgramMode（档位）
     * 0x500F 可写 当前=2500 枚举[100,125,…,51200]        ← ISO
     * ```
     * 旧映射把 0x500D（快门值 3333）当光圈显示成 "f/33.3"、把 0x500E（档位值 4）
     * 当快门显示成 "1/2500s"——**两个数都是错的**，而且看着"很合理"所以一直没被发现。
     * 正确码与标准 PTP 一致，因此 Wi-Fi 与 USB 共用同一套，不再分方言。
     */
    private val propDialect: PropDialect
        get() = PropDialect(0x5007, 0x500D, 0x500F, 0x500E)

    /** 设备属性描述符：当前值 + 可选集/范围 + 是否可写。 */
    data class PropDesc(
        val code: Long,
        val dtype: Int,
        val writable: Boolean,
        val value: Long,
        val values: List<Long>,
        val range: List<Long>?,
    )

    /** 完整解析 GetDevicePropDesc（含可选枚举/范围表）。 */
    /** 属性描述符的一行摘要（探针用）：类型 + 可写性 + 当前值 + 取值表。 */
    internal fun propDescDebugLine(code: Long): String? {
        val c = client ?: return null
        val p = propDescFull(c, code) ?: return null
        val form = when {
            p.values.isNotEmpty() -> "枚举[${p.values.joinToString(",")}]"
            p.range != null -> "范围[${p.range.joinToString(",")}]"
            else -> "无表"
        }
        return "当前=${p.value} $form"
    }

    private fun propDescFull(c: PtpSession, code: Long): PropDesc? = runCatching {        val d = c.transact(Ptp.OP_GET_DEVICE_PROP_DESC, longArrayOf(code)).data
        val r = ByteReader(d)
        r.u16() // 属性码
        val dtype = r.u16()
        val getSet = r.u8()
        ptpValue(r, dtype) // 出厂默认值（跳过）
        val current = ptpValue(r, dtype) ?: return@runCatching null
        var values = emptyList<Long>()
        var range: List<Long>? = null
        when (r.u8()) { // FormFlag：0=无，1=Range，2=Enumeration
            1 -> {
                val min = ptpValue(r, dtype)
                val max = ptpValue(r, dtype)
                val step = ptpValue(r, dtype)
                if (min != null && max != null && step != null) range = listOf(min, max, step)
            }
            2 -> {
                val n = r.u16()
                values = (0 until n).mapNotNull { ptpValue(r, dtype) }
            }
        }
        PropDesc(code, dtype, getSet != 0, current, values, range)
    }.getOrNull()

    private fun descMap(p: PropDesc?): Map<String, Any?>? = p?.let {
        mapOf(
            "code" to it.code,
            "dtype" to it.dtype,
            "writable" to it.writable,
            "value" to it.value,
            "values" to it.values,
            "range" to it.range,
        )
    }

    /**
     * 当前拍摄参数（带描述符）：value 用于显示，values/range 供编辑器生成选项，
     * writable 供置灰。经 DevicePropDesc 按数据类型解析。
     */
    /** 参数名 → 属性码。0x5010 = ExposureBiasCompensation（属性 Dump 实测：1/1000 EV 单位）。 */
    private fun codeForParam(name: String): Long? = when (name) {
        "fNumber" -> propDialect.fNumber
        "exposureTime" -> propDialect.exposureTime
        "iso" -> propDialect.iso
        "exposureBias" -> 0x5010
        else -> null
    }

    fun shotParams(): Map<String, Any?> {
        val c = need()
        val dl = propDialect
        val mode = dl.mode?.let { propDescFull(c, it) }
        return mapOf(
            "fNumber" to descMap(propDescFull(c, dl.fNumber)),
            "exposureTime" to descMap(propDescFull(c, dl.exposureTime)),
            "iso" to descMap(propDescFull(c, dl.iso)),
            "exposureBias" to descMap(propDescFull(c, 0x5010)),
            "mode" to mode?.let {
                mapOf(
                    "code" to it.code,
                    "value" to it.value,
                    "values" to it.values,
                    "writable" to it.writable,
                )
            },
            "battery" to battery(),
        )
    }

    /**
     * 设置拍摄参数（SetDevicePropDesc，数据外发）。
     * 相机侧规则（档位不允许改的参数）以 PtpException 原样上抛，由 UI 提示。
     */
    /**
     * 设置拍摄参数。
     *
     * **用 0x1016 SetDevicePropValue：参数 = 属性码，数据 = 只有值**（按 dtype 长度）。
     * 不是 SetDevicePropDesc —— 后者要求把整条描述符（含出厂值/表单）回写，
     * 此前按那个语义拼了 `[code][dtype][值]` 当数据、还不传参数，相机一律拒绝。
     * 相机侧规则（档位不允许改的参数）以 PtpException 原样上抛，由 UI 提示。
     */
    fun setShotParam(name: String, value: Long): Map<String, Any?> {
        val c = need()
        val code = codeForParam(name) ?: throw IOException("未知参数：$name")
        val d = propDescFull(c, code) ?: throw IOException("相机未提供该参数")
        if (!d.writable) throw IOException("当前模式下该参数不可修改")
        val payload: ByteArray
        when (d.dtype) {
            0x0001, 0x0002 -> payload = byteArrayOf(value.toByte())
            // 0x0003 = INT16（曝光补偿就是它）：掩码后自然得到补码
            0x0003, 0x0004 -> {
                payload = ByteArray(2)
                PtpWire.putU16(payload, 0, value.toInt())
            }
            else -> {
                payload = ByteArray(4)
                PtpWire.putU32(payload, 0, value)
            }
        }
        c.transactWithDataOut(Ptp.OP_SET_DEVICE_PROP_VALUE, longArrayOf(code), payload)
        // 立即回读，UI 拿到相机确认后的真值
        return mapOf("name" to name, "desc" to descMap(propDescFull(c, code)))
    }

    /**
     * 属性码 Dump（调试面板）：读常见标准码 + 尼康厂商段的 GetDevicePropDesc，
     * 用于确认 Wi-Fi 方言的档位属性码（USB连接方案/交接文档均有记录）。
     */
    fun probeProps(): List<String> {
        val c = need()
        val out = ArrayList<String>()
        val codes = (0x5001..0x5017L) + (0xD100..0xD11FL)
        for (code in codes) {
            val p = propDescFull(c, code) ?: continue
            val form = when {
                p.values.isNotEmpty() -> "枚举[${p.values.joinToString(",")}]"
                p.range != null -> "范围[${p.range.joinToString(",")}]"
                else -> "无表"
            }
            out += "0x%04X dtype=0x%04X %s 当前=%d %s".format(
                code, p.dtype, if (p.writable) "可写" else "只读", p.value, form,
            )
        }
        if (out.isEmpty()) out += "（没有读到任何设备属性）"
        out.forEach { log("属性Dump $it") } // 同步进 logcat（NikonSync 标签），便于远程取证
        return out
    }


    // ------------------------------------------------------------ 协议探针（调试面板用）
    //
    // 探针实现已移到 CameraProbes.kt（原文件逾 1500 行，探针段约占 380 行）。
    // 这里只留门面供 NikonsyncPlugin 调用；CameraProbes 需要的那几个成员已放宽为 internal。

    fun probeHiSpeed(handle: Long): List<String> = CameraProbes.probeHiSpeed(handle)

    /** 无线链路基准测速（只读）：见 [CameraProbes.probeLinkThroughput] */
    fun probeLinkThroughput(handle: Long): List<String> = CameraProbes.probeLinkThroughput(handle)

    fun probeResize(handle: Long): List<String> = CameraProbes.probeResize(handle)

    fun probeLiveView(): List<String> = CameraProbes.probeLiveView()

    fun probeLvFrames(): List<String> = CameraProbes.probeLvFrames()

    fun probeLiveView2(): List<String> = CameraProbes.probeLiveView2()

    fun probeLiveView3(handle: Long): List<String> = CameraProbes.probeLiveView3(handle)

    fun probeLiveView4(handle: Long): List<String> = CameraProbes.probeLiveView4(handle)

    fun probeLiveView5(handle: Long): List<String> = CameraProbes.probeLiveView5(handle)

    fun probeLvAf(handle: Long): List<String> = CameraProbes.probeLvAf(handle)

    /** 取景对焦坐标标定（需已在取景态）：见 [CameraProbes.probeAfArea] */
    fun probeAfArea(frameW: Int, frameH: Int): List<String> =
        CameraProbes.probeAfArea(frameW, frameH)

    /** 休眠/自动关机属性探针（见 [CameraProbes.probeSleep]） */
    fun probeSleep(): List<String> = CameraProbes.probeSleep()

    /** 实时 ISO 发现探针（差分法，见 [CameraProbes.probeLiveIso]；约 15 秒） */
    fun probeLiveIso(): List<String> = CameraProbes.probeLiveIso()

    // ------------------------------------------------------------ 保持相机清醒

    /** 休眠相关属性的原始值（开启保活时记下，退出时还原）。 */
    private val sleepBackup = LinkedHashMap<Long, Long>()

    /**
     * 遥控期间**保持相机屏幕常亮**。
     *
     * 真机现象（2026-09-15）：相机空闲十几秒就息屏，之后 `0x9201` 仍返回成功但
     * `0x9203` 一直 NotLiveView、`0x9205` 被接受却不生效——**必须手动按相机快门
     * 才能把屏幕叫回来**，遥控拍摄因此完全不可用。
     *
     * 依据 libgphoto2：`PTP_DPC_NIKON_MonitorOff(0xD064) "LCD Off Time"` 与
     * `MeterOff(0xD062) "Auto Meter Off Time"` 都是**可写**属性。做法是：
     * 读描述符 → 取枚举/范围里**最大的那个值**（各机型语义不同，不猜具体数字）
     * → 写入并记住原值 → 退出遥控时还原。
     *
     * 相机不提供或写入被拒时**如实上报**，由 UI 提示用户改相机菜单，绝不假装成功。
     */
    fun keepAwake(enable: Boolean): Map<String, Any?> {
        val c = need()
        val codes = longArrayOf(0xD064L, 0xD062L)
        val changed = ArrayList<String>()
        val failed = ArrayList<String>()
        for (code in codes) {
            val d = propDescFull(c, code) ?: continue
            if (!d.writable) {
                failed += "0x%04X 只读".format(code)
                continue
            }
            if (enable) {
                val target = (d.values.maxOrNull() ?: d.range?.getOrNull(1)) ?: continue
                if (target <= d.value) {
                    changed += "0x%04X 已是最大值 %d".format(code, d.value)
                    continue
                }
                sleepBackup.putIfAbsent(code, d.value)
                val r = runCatching { writeProp(c, code, d, target) }
                if (r.isSuccess) changed += "0x%04X %d→%d".format(code, d.value, target)
                else failed += "0x%04X 写入被拒（${r.exceptionOrNull()?.message}）".format(code)
            } else {
                val original = sleepBackup.remove(code) ?: continue
                val r = runCatching { writeProp(c, code, d, original) }
                if (r.isSuccess) changed += "0x%04X 还原为 %d".format(code, original)
                else failed += "0x%04X 还原失败（${r.exceptionOrNull()?.message}）".format(code)
            }
        }
        if (changed.isNotEmpty()) log("相机屏幕常亮：${changed.joinToString("，")}")
        if (failed.isNotEmpty()) log("相机屏幕常亮未生效：${failed.joinToString("，")}")
        return mapOf(
            "ok" to failed.isEmpty(),
            "changed" to changed,
            "failed" to failed,
            "note" to if (changed.isEmpty() && failed.isEmpty()) "相机未提供相关属性" else null,
        )
    }

    /** 按属性的真实类型写入值（SetDevicePropValue：参数=属性码，数据=仅值）。 */
    private fun writeProp(c: PtpSession, code: Long, d: PropDesc, value: Long) {
        val payload = when (d.dtype) {
            0x0001, 0x0002 -> byteArrayOf(value.toByte())
            0x0003, 0x0004 -> ByteArray(2).also { PtpWire.putU16(it, 0, value.toInt()) }
            else -> ByteArray(4).also { PtpWire.putU32(it, 0, value) }
        }
        c.transactWithDataOut(Ptp.OP_SET_DEVICE_PROP_VALUE, longArrayOf(code), payload)
    }

    /**
     * 防待机"戳一下"（**实验性**）。
     *
     * 背景：Z50 II 在本机 Wi-Fi 连接下不支持 `0xD064 MonitorOff` / `0xD062 MeterOff`
     * / `0xD066 AutoOffTimers` / `0xD0B3 MonitorOffDelay`（休眠探针实测全部"不支持"），
     * 所以**改不了**它的息屏时间。唯一还能试的方向是"制造一点协议活动"，看相机会不会
     * 因此重置待机计时。
     *
     * 这里只做**无副作用**的两件事：`0x90C8 DeviceReady`（存在性询问）与重发上次对焦点
     * （`0x9205`，不改画面）。**不重发 0x9201**——那会打断取景帧流。
     * 是否有效需要真机观察：日志会记每次戳的时间，用户看屏幕有没有提前熄。
     */
    fun pokeActivity(): Map<String, Any?> {
        val c = client ?: return mapOf("ok" to false, "reason" to "未连接")
        val r1 = runCatching { c.transactShort(Ptp.OP_NIKON_DEVICE_READY, LongArray(0), 2000) }
        val last = lastAfArea
        val r2 = if (last != null) {
            runCatching {
                c.transactShort(Ptp.OP_NIKON_CHANGE_AF_AREA, longArrayOf(last[0], last[1]), 2000)
            }
        } else null
        val ok = r1.isSuccess || (r2?.isSuccess == true)
        return mapOf("ok" to ok, "af" to (last != null))
    }

    /** 最近一次指定的对焦点（防待机戳一下要重发它，不能改用户选的位置）。 */
    @Volatile private var lastAfArea: LongArray? = null

    /**
     * 尝试唤醒相机（屏幕已息屏时）。
     *
     * `0x90C8 DeviceReady` 在 libgphoto2 里就是"你准备好了吗/醒一醒"语义
     * （`nikon_wait_busy` 反复调它等相机从忙/休眠恢复）。返回是否应答。
     */
    /** 息屏后尝试唤醒（DeviceReady）。返回 `{ok, busy}`——busy 常意味着相机在忙/待机。 */
    fun wakeUp(): Boolean {
        val c = client ?: return false
        return runCatching {
            c.transactShort(Ptp.OP_NIKON_DEVICE_READY, LongArray(0), 3000)
            true
        }.getOrElse {
            log("唤醒尝试：${it.message}")
            false
        }
    }

    // ------------------------------------------------------------ 已下载媒体管理

    /** 本地媒体缩略图（优先 ContentResolver.loadThumbnail，失败则整图解码缩小）。 */
    fun mediaThumb(uriStr: String): ByteArray? {
        val ctx = appContext!!
        val uri = Uri.parse(uriStr)
        val direct = runCatching {
            val bmp = ctx.contentResolver.loadThumbnail(uri, android.util.Size(512, 512), null)
            val bos = java.io.ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
            bmp.recycle()
            bos.toByteArray()
        }.getOrNull()
        if (direct != null) return direct
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            ctx.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it, null, bounds) }
            val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (maxDim / (sample * 2) >= 512) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bmp = ctx.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it, null, opts) }
                ?: return@runCatching null
            val bos = java.io.ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
            bmp.recycle()
            bos.toByteArray()
        }.getOrNull()
    }

    /** 读取本地媒体完整字节（查看器用，图片场景）。 */
    fun mediaBytes(uriStr: String): ByteArray {
        val ctx = appContext!!
        ctx.contentResolver.openInputStream(Uri.parse(uriStr))?.use { return it.readBytes() }
        throw IOException("无法读取本地文件")
    }

    /** 按文件名在 MediaStore 中找回媒体 uri（修复旧版本下载记录）。 */
    fun findMediaByName(name: String): String? {
        val ctx = appContext!!
        for (collection in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            runCatching {
                ctx.contentResolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns._ID),
                    MediaStore.MediaColumns.DISPLAY_NAME + "=?",
                    arrayOf(name),
                    MediaStore.MediaColumns._ID + " DESC",
                )?.use { cur ->
                    if (cur.moveToFirst()) {
                        return ContentUris.withAppendedId(collection, cur.getLong(0)).toString()
                    }
                }
            }
        }
        return null
    }

    /**
     * 按文件名查媒体库里的**相对路径**（如 `Pictures/NikonSync`）。
     *
     * 早期版本的下载记录只有文件名、没有保存路径，于是本机页把它们统统归到
     * "未知位置"一组。这里用 MediaStore 的 RELATIVE_PATH 把位置补回来
     * （API 29+ 的标准列，本项目 minSdk=29；查不到就返回 null，调用方保持原样）。
     */
    fun mediaRelativePath(name: String): String? {
        val ctx = appContext!!
        for (collection in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            runCatching {
                ctx.contentResolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns.RELATIVE_PATH),
                    MediaStore.MediaColumns.DISPLAY_NAME + "=?",
                    arrayOf(name),
                    MediaStore.MediaColumns._ID + " DESC",
                )?.use { cur ->
                    if (cur.moveToFirst()) {
                        val p = cur.getString(0)
                        if (!p.isNullOrEmpty()) return p.trimEnd('/')
                    }
                }
            }
        }
        return null
    }

    /** 删除本地媒体文件（支持 MediaStore 与 SAF 文档 uri）。 */
    fun mediaDelete(uriStr: String): Boolean {
        val ctx = appContext!!
        val uri = Uri.parse(uriStr)
        return runCatching {
            if (uri.scheme == "content" && (uri.authority ?: "").endsWith("documents")) {
                DocumentsContract.deleteDocument(ctx.contentResolver, uri)
            } else {
                ctx.contentResolver.delete(uri, null, null) > 0
            }
        }.getOrDefault(false)
    }

    /** 用系统相册/查看器打开本地媒体。 */
    fun openMedia(uriStr: String): Boolean {
        val ctx = appContext!!
        val uri = Uri.parse(uriStr)
        val mime = ctx.contentResolver.getType(uri) ?: "image/jpeg"
        return runCatching {
            ctx.startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, mime)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        }.getOrDefault(false)
    }

    /** 拉取对象原始字节（大图查看用，JPEG ≤40MB；RAW 不走此路径）。 */
    fun fetchObject(handle: Long, size: Long): ByteArray {
        val c = need()
        if (size > 40L shl 20) throw IOException("文件过大，无法在线查看")
        return c.transact(Ptp.OP_GET_OBJECT, longArrayOf(handle)).data
    }

    /**
     * 取原图字节用于**在线查看**（不落盘），并逐块上报进度。
     *
     * 与 [fetchObject] 的唯一差别就是进度：后者一次性拿回数据，中途没有任何反馈，
     * 用户只能盯着一个转圈猜"是在下载还是已经卡住了"（本次反馈的正是这一点）。
     * 这里复用下载用的流式通道 [PtpSession.getObjectToStream]，走同一套 `progress`
     * 事件，大图页据此显示真实百分比、已接收量、速率与停滞时长。
     */
    fun fetchOriginal(handle: Long, size: Long): Map<String, Any?> {
        val c = need()
        if (size > 40L shl 20) throw IOException("文件过大，无法在线查看")
        val t0 = SystemClock.elapsedRealtime()
        val cap = if (size in 1..(40L shl 20)) size.toInt() else 1 shl 22
        val buf = java.io.ByteArrayOutputStream(cap)
        // getObjectToStream 内部已保证"少传即抛异常"，不会给出截断的 JPEG
        val written = c.getObjectToStream(handle, size, buf) { r, t -> emitProgress(r, t, t0) }
        val bytes = buf.toByteArray()
        val ms = SystemClock.elapsedRealtime() - t0
        val speed = if (ms > 0) (written / 1048576.0) / (ms / 1000.0) else 0.0
        log("原图已读取（仅查看，未保存）：$written 字节，%.1f MB/s".format(speed))
        emit(mapOf("type" to "progress", "received" to written, "total" to written, "speedMBps" to speed))
        return mapOf("bytes" to bytes, "bytesWritten" to written, "ms" to ms, "speedMBps" to speed)
    }

    /**
     * 轻量预览：查看器默认走这里，避免每翻一张都拉原图（一张 JPEG 原图可达 20MB+）。
     *
     * - `low`    = 大缩略图 0x90C4（实测 640×424 / 133KB；失败回退标准 GetThumb 0x100A）
     * - `medium` = GetFhdPicture 0x920F（实测 1620×1080 / 881KB，相机端出图）
     *
     * `medium` 不可用时**明确回退到 low 并在返回值里标注 fallback**，绝不静默降级成原图
     * （那会让用户以为"中等"却承担了原图的流量与耗时）。返回值：
     * `{bytes, quality(实际生效档位), fallback?, note?}`
     *
     * ⚠️ 真机踩坑（2026-09-15）：0x920F 相机端要现渲染这张图，**可能超过默认 30 秒**
     * 才应答；用默认超时会让查看器卡满 30 秒再回退，体验比"直接给缩略图"还差。
     * 因此这里用 6 秒专用超时，并记账：连续两次拿不到就在本次会话内不再尝试，
     * 直接回退 low（避免每张都等 6 秒）。
     */
    private var fhdFailCount = 0

    fun previewBytes(handle: Long, quality: String): Map<String, Any?> {
        val c = need()
        if (quality == "medium" && fhdFailCount < 2) {
            val r = runCatching {
                c.transactShort(Ptp.OP_NIKON_GET_FHD_PICTURE, longArrayOf(handle), FHD_TIMEOUT_MS)
            }
            val data = r.getOrNull()?.data
            if (data != null && data.size > 1024) {
                fhdFailCount = 0
                val soi = indexOfSoi(data)
                val jpeg = if (soi > 0) data.copyOfRange(soi, data.size) else data
                return mapOf("bytes" to jpeg, "quality" to "medium")
            }
            fhdFailCount++
            val why = r.exceptionOrNull()?.message ?: "相机返回空数据"
            log("中等图（0x920F）不可用（第 $fhdFailCount 次）：$why，回退大缩略图")
            return mapOf(
                "bytes" to c.getThumbnailBytes(handle),
                "quality" to "low",
                "fallback" to true,
                "note" to why,
            )
        }
        // low：与列表缩略图同源，通常已在缓存里
        return mapOf("bytes" to c.getThumbnailBytes(handle), "quality" to "low")
    }
}
