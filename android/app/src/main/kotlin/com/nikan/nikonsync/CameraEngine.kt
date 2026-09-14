package com.nikan.nikonsync

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

/**
 * 相机引擎：单例。管理 PTP/IP 连接生命周期、Wi-Fi 网络绑定、
 * 网段扫描、枚举、缩略图、下载（MediaStore 落盘）与事件转发。
 */
object CameraEngine {
    private const val TAG = "NikonSync"
    const val DEFAULT_FRIENDLY_NAME = "Nikon Wireless Mobile Utility"

    /** 拆除旧会话后、发起新握手前留给相机释放会话的时间 */
    private const val SESSION_SETTLE_MS = 1500L

    private var appContext: Context? = null
    internal var client: PtpIpClient? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var sink: EventChannel.EventSink? = null
    private var lastProgressEmit = 0L

    // ---- 保活：DeviceReady 轮询（相机响应即视为存活；socket 异常即断线）----
    private val keepAliveExecutor = Executors.newSingleThreadExecutor()
    private val keepAliveHandler = Handler(Looper.getMainLooper())
    private var keepAliveRunning = false

    private fun startKeepAlive() {
        stopKeepAlive()
        keepAliveRunning = true
        val task = object : Runnable {
            override fun run() {
                if (!keepAliveRunning) return
                keepAliveExecutor.execute {
                    val c = client ?: return@execute
                    try {
                        c.transact(Ptp.OP_NIKON_DEVICE_READY)
                        drainCheckEvents()
                    } catch (e: PtpException) {
                        // 相机响应了 PTP 错误（如忙），链路仍在
                    } catch (e: Exception) {
                        c.notifyLinkDead(e.message ?: "保活探针失败")
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

    fun log(line: String) {
        Log.d(TAG, line)
        emit(mapOf("type" to "log", "line" to line))
    }

    // ------------------------------------------------------------ 网络

    private fun cm(): ConnectivityManager =
        appContext!!.getSystemService(ConnectivityManager::class.java)

    /** 当前 Wi-Fi 网络（相机热点没有互联网，也不能要求有）。 */
    fun wifiNetwork(): Network? = cm().allNetworks.firstOrNull { n ->
        cm().getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
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
        runCatching {
            @Suppress("DEPRECATION")
            val wm = appContext!!.getSystemService(WifiManager::class.java)
            val raw = wm?.connectionInfo?.ssid?.removeSurrounding("\"")
            if (raw != null && raw != "<unknown ssid>" && raw != "0x") ssid = raw
        }
        return mapOf("onWifi" to (net != null), "ssid" to ssid, "ip" to ip, "gateway" to gateway)
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
        // 兜底：网段扫描 + 握手
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

    // ------------------------------------------------------------ 连接

    fun connect(ip: String, friendlyName: String): Map<String, Any?> {
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
        val c = PtpIpClient(socketFactory(), ::log)
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
                KeepAliveService.stop(appContext!!)
                client = null
                deviceInfo = null
                cameraIp = null
                emit(mapOf("type" to "status", "state" to "disconnected", "reason" to reason))
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

    /** 相机信息（连接结果与"已连接"快路径共用）。 */
    private fun describeCamera(c: PtpIpClient): Map<String, Any?> {
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
        )
    }

    fun disconnect() {
        disconnectQuiet()
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

    internal fun need(): PtpIpClient = client ?: throw IOException("尚未连接相机")

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

    private fun readHandles(c: PtpIpClient, storageId: Long, parent: Long, format: Int = 0): List<Long> =
        c.transact(Ptp.OP_GET_OBJECT_HANDLES, longArrayOf(storageId, format.toLong(), parent))
            .data.let { ByteReader(it).u32Array() }.toList()

    private fun getObjectInfo(c: PtpIpClient, handle: Long): ObjectInfo =
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

    /** 手机端等比缩放 JPEG 到指定长边 */
    private fun resizeJpeg(src: File, longEdge: Int): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(src.absolutePath, bounds)
        if (bounds.outWidth <= 0) throw IOException("JPEG 解码失败")
        val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (maxDim / (sample * 2) >= longEdge) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val srcBmp = BitmapFactory.decodeFile(src.absolutePath, opts) ?: throw IOException("JPEG 解码失败")
        val scale = longEdge.toFloat() / maxOf(srcBmp.width, srcBmp.height)
        val bmp = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                srcBmp,
                (srcBmp.width * scale).toInt().coerceAtLeast(1),
                (srcBmp.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        } else srcBmp
        val bos = java.io.ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 90, bos)
        if (bmp !== srcBmp) bmp.recycle()
        srcBmp.recycle()
        return bos.toByteArray()
    }

    /**
     * 下载一个对象。画质：original 原图；2M/8M 仅对 JPEG 生效（手机端缩放）。
     * 保存位置：用户在设置里用 SAF 选过目录则写入该目录，否则写系统相册。
     * 分块模式失败时自动降级整文件下载并重试一次。
     */
    fun download(handle: Long, fileName: String, size: Long, variant: String = VARIANT_ORIGINAL): Map<String, Any?> {
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
            } catch (e: Exception) {
                runCatching { tempFile?.delete() }
                if (created != null) {
                    if (isSafDoc) runCatching { DocumentsContract.deleteDocument(resolver, created) }
                    else runCatching { resolver.delete(created, null, null) }
                }
                attempt++
                // 降级条件不能只看 PtpException：分块提前结束抛的是 IOException，
                // 而那恰恰是最该退回整文件下载的情形。
                if (attempt == 1 && c.effectiveDlMode != PtpIpClient.DlMode.FULL) {
                    log("下载失败（$fileName）：${e.message}；改用整文件下载重试")
                    c.degradeToFullDownload()
                    continue
                }
                throw e
            }
        }
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

    /** 对焦优先导致拒拍的说明与处理办法（相机侧可关，所以要把菜单路径写清楚）。 */
    private const val FOCUS_PRIORITY_HINT =
        "原因通常是相机开启了「未对焦时禁止拍摄」（对焦优先）：对焦没锁定，相机就不会释放快门。\n" +
            "处理办法（任选其一）：\n" +
            "· 把相机对准有明暗/线条对比的目标再拍——对着纯色墙面或无纹理物体，AF 永远对不上\n" +
            "· 先点遥控页的「对焦」按钮，等画面合焦后再按拍摄\n" +
            "· 相机端改为释放优先：自定义设定菜单 → a1 AF-C 优先选择 / a2 AF-S 优先选择 → 选「释放」\n" +
            "· 或把镜头切到手动对焦（MF），相机就不再检查对焦"

    /** 向遥控页上报拍摄阶段，让等待过程有解释（对焦 / 快门）。 */
    private fun emitPhase(phase: String) = emit(mapOf("type" to "capturePhase", "phase" to phase))

    /** 实际生效的取景帧操作码（0x9202 / 0x9203 自动探测）。 */
    fun liveViewStart(): Map<String, Any?> {
        val c = need()
        if (!liveViewOn) {
            // 首次启动相机可能初始化较久：先 3s 快试，失败再用 8s
            runCatching { c.transactShort(Ptp.OP_NIKON_LV_START, LongArray(0), 3000) }
                .onFailure { runCatching { c.transactShort(Ptp.OP_NIKON_LV_START, LongArray(0), 8000) } }
            liveViewOn = true
            log("实时取景启动指令已发送（0x9201）")
        }
        return mapOf("ok" to true)
    }

    fun liveViewStop() {
        val c = client ?: return
        if (liveViewOn) {
            runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 2000) }
            liveViewOn = false
            log("实时取景已关闭")
        }
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
        return if (soi > 0) data.copyOfRange(soi, data.size) else data
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
                                FOCUS_PRIORITY_HINT,
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
                        "快门在 ${elapsed / 1000}s 内始终未被释放。\n$FOCUS_PRIORITY_HINT",
                    )
                }
                when (attempt) {
                    1 -> {
                        // 疑似取景中 AF 驱动（0x9405）：若它其实是拍摄操作会实拍一张
                        val r = runCatching { c.transactShort(Ptp.OP_NIKON_LV_CAPTURE, LongArray(0), 2500) }
                        log("取景中 0x9405 尝试 → " + if (r.isSuccess) "OK ${r.getOrThrow().data.size}B" else
                            Ptp.respName((r.exceptionOrNull() as? PtpException)?.code ?: -1))
                    }
                    2 -> {
                        // 再驱动一次 AF（0x90C3，取景中可能被拒）
                        runCatching { c.transact(0x90C3.toInt()) }
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


    // ---- 厂商事件队列排水（0x90C1 / 0x90C0 自适应）----

    @Volatile private var checkEventOp: Long = 0
    @Volatile private var drainFailLogged = false

    private fun drainCheckEvents() {
        val c = client ?: return
        val candidates = linkedSetOf(
            if (checkEventOp != 0L) checkEventOp else Ptp.OP_NIKON_CHECK_EVENT.toLong(),
            Ptp.OP_NIKON_CHECK_EVENT.toLong(),
            0x90C0L,
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
            log("事件排水：0x90C0/0x90C1 均无响应（该模式不支持厂商事件队列，仅提示一次）")
        }
    }

    private fun parseCheckEvents(data: ByteArray) {
        if (data.size < 4) return
        val r = ByteReader(data)
        val count = r.u32().toInt()
        if (count <= 0 || count > 128) {
            val hex = data.take(16).joinToString(" ") { "%02X".format(it) }
            log("CheckEvent 数据无法解析（count=$count）：$hex")
            return
        }
        var i = 0
        while (i < count && r.remaining >= 6) {
            val code = r.u16()
            val param = r.u32()
            i++
            log("CheckEvent: ${Ptp.evtName(code)} $param")
            if (code == Ptp.EVT_OBJECT_ADDED) {
                emit(mapOf("type" to "objectAdded", "handle" to param))
            }
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

    private fun propDescCurrent(c: PtpIpClient, code: Long): Long? = runCatching {
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
     * AF 驱动（试验）：仅尝试 0x90C3。
     * ⚠️ 0x9206 疑似为本代机型的 StartLiveView，调用后快门会被持续拒绝，已移除。
     */
    private fun afDriveBlocking(c: PtpIpClient): Boolean {
        if (afDriveOp == -1L) return false
        if (afDriveOp != 0L) {
            return runCatching { c.transact(afDriveOp.toInt()) }.isSuccess
        }
        val ok = runCatching { c.transact(0x90C3.toInt()) }.isSuccess
        if (ok) {
            afDriveOp = 0x90C3L
            log("AF 驱动：0x90C3 可用")
        } else {
            afDriveOp = -1L
            log("AF 驱动 0x90C3 被拒绝，跳过")
        }
        return ok
    }

    /** 手动触发一次 AF（遥控页“对焦”按钮）。 */
    fun afDrive(): Map<String, Any?> {
        val c = need()
        val ok = afDriveBlocking(c)
        return mapOf("ok" to ok)
    }

    /** 当前拍摄参数（光圈/快门/ISO，只读展示）。经 DevicePropDesc 按数据类型解析。 */
    fun shotParams(): Map<String, Any?> {
        val c = need()

        fun propDesc(code: Long): Long? = propDescCurrent(c, code)
        return mapOf(
            "fNumber" to propDesc(0x500D),
            "exposureTime" to propDesc(0x500E),
            "iso" to propDesc(0x500F),
            "battery" to battery(),
        )
    }


    // ------------------------------------------------------------ 协议探针（调试面板用）
    //
    // 探针实现已移到 CameraProbes.kt（原文件逾 1500 行，探针段约占 380 行）。
    // 这里只留门面供 NikonsyncPlugin 调用；CameraProbes 需要的那几个成员已放宽为 internal。

    fun probeHiSpeed(handle: Long): List<String> = CameraProbes.probeHiSpeed(handle)

    fun probeResize(handle: Long): List<String> = CameraProbes.probeResize(handle)

    fun probeLiveView(): List<String> = CameraProbes.probeLiveView()

    fun probeLvFrames(): List<String> = CameraProbes.probeLvFrames()

    fun probeLiveView2(): List<String> = CameraProbes.probeLiveView2()

    fun probeLiveView3(handle: Long): List<String> = CameraProbes.probeLiveView3(handle)

    fun probeLiveView4(handle: Long): List<String> = CameraProbes.probeLiveView4(handle)

    fun probeLiveView5(handle: Long): List<String> = CameraProbes.probeLiveView5(handle)

    fun probeLvAf(handle: Long): List<String> = CameraProbes.probeLvAf(handle)

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
}
