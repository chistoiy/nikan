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
    private var client: PtpIpClient? = null
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
            if (client === c && code == Ptp.EVT_OBJECT_ADDED && params.isNotEmpty()) {
                emit(mapOf("type" to "objectAdded", "handle" to params[0]))
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

    private fun need(): PtpIpClient = client ?: throw IOException("尚未连接相机")

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
        private set

    /** InitiateCapture 实际可用的参数形态（空参失败后尝试 全存储+默认格式）。 */
    @Volatile private var captureParams: LongArray? = null

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

    private fun indexOfSoi(data: ByteArray): Int {
        for (i in 0 until data.size - 1) {
            if (data[i] == 0xFF.toByte() && data[i + 1] == 0xD8.toByte()) return i
        }
        return -1
    }

    /** 遥控快门（0x100E 拍到卡上）。实时取景中相机可能报忙：自动 停取景→拍→恢复取景。 */
    fun capture(): Map<String, Any?> {
        val c = need()
        drainCheckEvents()
        var attempt = 0
        var recovered = false
        val t0 = SystemClock.elapsedRealtime()
        while (true) {
            try {
                c.transact(Ptp.OP_INITIATE_CAPTURE, captureParams ?: LongArray(0))
                captureParams = captureParams ?: LongArray(0)
                break
            } catch (e: PtpException) {
                // 未对焦（相机设置"未对焦时禁止拍摄"）：明确提示并结束本次拍摄
                if (e.code == 0xA004) {
                    log("快门被拒：未完成对焦（0xA004）")
                    throw IOException(
                        "未完成对焦，快门已锁定（相机开启了「未对焦时禁止拍摄」）。" +
                            "请半按相机快门完成对焦后再试",
                    )
                }
                if (e.code == Ptp.RESP_DEVICE_BUSY || e.code == 0x2002 || e.code == 0xA004) {
                    attempt++
                    val elapsed = SystemClock.elapsedRealtime() - t0
                    if (elapsed > 25_000) {
                        throw IOException(
                            "相机持续忙碌，无法拍摄（已重试 $attempt 次 / ${elapsed / 1000}s）。" +
                                "请查看相机屏幕是否有待处理提示",
                        )
                    }
                    log("相机忙（${Ptp.respName(e.code)}），重试 $attempt（已 ${elapsed / 1000}s）")
                    // 第 6 次起探测 SDRAM 待取图像：上一张未取走会导致快门持续被拒
                    if (attempt >= 6) {
                        val info = runCatching {
                            c.transact(Ptp.OP_GET_OBJECT_INFO, longArrayOf(0xFFFF0001L)).data
                        }.getOrNull()
                        if (info != null && info.size > 8) {
                            log("发现 SDRAM 待取图像（0xFFFF0001），通知读取")
                            emit(mapOf("type" to "objectAdded", "handle" to 0xFFFF0001L))
                        }
                    }
                    // 疑似误入实时取景状态：尝试退出恢复拍摄
                    if (attempt == 8 && !recovered) {
                        recovered = true
                        val ok = runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 2000) }.isSuccess
                        log(if (ok) "已尝试退出实时取景（0x9201 成功），恢复拍摄" else "0x9201 无效，跳过恢复")
                    }
                    drainCheckEvents()
                    runCatching { c.transact(Ptp.OP_NIKON_DEVICE_READY) }
                    Thread.sleep(500)
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
        var attempt = 0
        val t0 = SystemClock.elapsedRealtime()
        while (true) {
            try {
                c.transact(Ptp.OP_INITIATE_CAPTURE, captureParams ?: LongArray(0))
                captureParams = captureParams ?: LongArray(0)
                log("取景中快门已触发（0x100E）")
                return mapOf("ok" to true)
            } catch (e: PtpException) {
                if (e.code == 0xA004) {
                    throw IOException(
                        "相机对焦未锁定（对焦优先）。请半按相机快门对焦后再试，" +
                            "或在相机菜单关闭「未对焦时禁止拍摄」",
                    )
                }
                val busy = e.code == Ptp.RESP_DEVICE_BUSY || e.code == 0x2002
                val paramErr = captureParams == null && e.code in intArrayOf(0x2005, 0x2006, 0x2007)
                attempt++
                val elapsed = SystemClock.elapsedRealtime() - t0
                if (!busy && !paramErr) throw e
                if (elapsed > 20_000) {
                    throw IOException(
                        "相机持续忙碌（${elapsed / 1000}s）。请半按相机快门对焦后再试，" +
                            "或检查相机屏幕是否有待处理提示",
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
                        // AF 驱动（0x90C3，取景中可能被拒）
                        runCatching { c.transact(0x90C3.toInt()) }
                    }
                    3 -> {
                        if (paramErr) {
                            captureParams = longArrayOf(0xFFFFFFFFL, 0)
                            log("尝试 全存储+默认格式 参数")
                        }
                    }
                }
                Thread.sleep(400)
            }
        }
    }

    /** 取景中 AF/拍摄通道探针（调试面板用）。 */
    fun probeLvAf(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()
        fun t(label: String, op: Int, params: LongArray): String {
            val r = runCatching { c.transactShort(op, params, 2500) }
            return if (r.isSuccess) {
                val d = r.getOrThrow().data
                "$label → OK ${d.size}B 头: ${d.take(12).joinToString(" ") { "%02X".format(it) }}"
            } else {
                "$label → ${Ptp.respName((r.exceptionOrNull() as? PtpException)?.code ?: -1)}"
            }
        }
        out += t("0x9405 无参（疑似LV AF/拍摄）", Ptp.OP_NIKON_LV_CAPTURE, LongArray(0))
        out += t("0x100E 标准快门（会实拍！）", Ptp.OP_INITIATE_CAPTURE, LongArray(0))
        out += t("0x9205 AF区域[128,128]", 0x9205, longArrayOf(128L, 128L))
        out += t("0x9204 MF驱动[1,0]", 0x9204, longArrayOf(1L, 0L))
        out += t("0x90C3 AF驱动", 0x90C3, LongArray(0))
        out += t("0x9209 状态", 0x9209, LongArray(0))
        out.forEach { log("LV对焦探针 $it") }
        return out
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

    /**
     * 高速下载探针：0x9400~0x9406 逐个尝试多种参数形态，
     * 记录响应码/数据量，用于定位新一代高速读取操作。
     */
    fun probeHiSpeed(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()
        val shapes = listOf(
            "句柄,偏移,长度" to longArrayOf(handle, 0, 65536),
            "句柄,长度" to longArrayOf(handle, 65536),
            "句柄" to longArrayOf(handle),
        )
        var op = 0x9400
        while (op <= 0x9406) {
            for ((label, params) in shapes) {
                val result = try {
                    val data = c.transact(op, params).data
                    "OK ${data.size}B"
                } catch (e: PtpException) {
                    Ptp.respName(e.code)
                } catch (e: Exception) {
                    e.message ?: "异常"
                }
                out += "0x%04X [%s] → %s".format(op, label, result)
            }
            op++
        }
        out.forEach { log("探针 $it") }
        return out
    }

    /** 相机端缩放探针：0x9207 GetObjectResize 的参数形态尝试。 */
    fun probeResize(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()
        val shapes = listOf(
            "句柄" to longArrayOf(handle),
            "句柄,1920" to longArrayOf(handle, 1920),
            "句柄,1920,1280" to longArrayOf(handle, 1920, 1280),
            "句柄,2" to longArrayOf(handle, 2),
        )
        for ((label, params) in shapes) {
            val result = try {
                val data = c.transact(Ptp.OP_NIKON_GET_OBJECT_RESIZE, params).data
                "OK ${data.size}B"
            } catch (e: PtpException) {
                Ptp.respName(e.code)
            } catch (e: Exception) {
                e.message ?: "异常"
            }
            out += "0x9207 [$label] → $result"
        }
        out.forEach { log("探针 $it") }
        return out
    }

    /** 实时取景探针：0x9200~0x9203 逐个试探（不包含会真拍照的操作）。 */
    fun probeLiveView(): List<String> {
        val c = need()
        val out = ArrayList<String>()
        for (op in intArrayOf(0x9200, 0x9201, 0x9202, 0x9203)) {
            val r = try {
                val d = c.transact(op).data
                "OK ${d.size}B"
            } catch (e: PtpException) {
                Ptp.respName(e.code)
            } catch (e: Exception) {
                e.message ?: "异常"
            }
            out += "0x%04X → %s".format(op, r)
        }
        out.forEach { log("取景探针 $it") }
        return out
    }

    /**
     * 取景帧尺寸探针：在取景状态下逐个尝试候选帧通道，报告字节数与 JPEG 像素尺寸。
     *
     * 目的：实测 0x9203 只给 640×424 / 33KB，放大到手机屏后既糊又发闷。
     * 本探针用来定论"是否存在更大的取景帧通道"——若全部返回 640×424，
     * 说明这是相机在智能设备 Wi-Fi 模式下的硬上限，不必再追。
     *
     * 候选码只含本项目已验证过的只读取帧操作，不含 0x100E / 0x9400 / 0x9405
     * 等拍摄类操作（交接文档 §7 记载 0x920A 等会真拍照）。
     */
    fun probeLvFrames(): List<String> {
        val c = need()
        val out = ArrayList<String>()
        var startedHere = false
        try {
            if (!liveViewOn) {
                // 启动失败必须让用户看到，不能吞掉：
                // 吞掉之后会在"未知状态"下继续发探针指令，把相机留在取景态
                val start = runCatching { c.transactShort(Ptp.OP_NIKON_LV_START, LongArray(0), 4000) }
                if (start.isFailure) {
                    out += "启动取景失败：${start.exceptionOrNull()?.message}"
                    return out
                }
                startedHere = true
                Thread.sleep(1200) // 等取景热身，首帧可能为空
            }
            // 只探测有证据支持的只读取帧通道：0x9203 是生产路径在用的，
            // 0x9403 是取景热身探针实测能出帧的。
            // 0x9202/0x9204/0x9205/0x9209 语义未知（本项目审计已标注 0x9204 属"未知码"），
            // 不放进这个探针——此前放进去过，用户实测用完后相机退出取景、屏幕熄灭并关闭热点断连。
            for (op in intArrayOf(0x9203, 0x9403)) {
                val line = runCatching { c.transactShort(op, LongArray(0), 2500) }.fold(
                    onSuccess = { r -> "0x%04X → OK %dB %s".format(op, r.data.size, jpegDims(r.data)) },
                    onFailure = { e ->
                        val code = (e as? PtpException)?.code ?: -1
                        "0x%04X → %s".format(op, Ptp.respName(code))
                    },
                )
                out += line
                log("取景帧探针 $line")
            }
        } finally {
            // 无论上面发生什么都要关闭取景：绝不能把相机留在取景态
            if (startedHere) {
                runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 3000) }
                    .onFailure { log("结束取景失败：${it.message}") }
                liveViewOn = false
                log("取景帧尺寸探针结束，已关闭取景")
            }
        }
        return out
    }

    /** 从 JPEG 字节里找 SOF 段读出像素尺寸，返回 "宽×高" 或失败原因。 */
    private fun jpegDims(d: ByteArray): String {
        val soi = indexOfSoi(d)
        if (soi < 0) return "非JPEG"
        var i = soi + 2
        while (i + 4 <= d.size) {
            if (d[i] != 0xFF.toByte()) return "段结构异常"
            val marker = d[i + 1].toInt() and 0xFF
            if (marker == 0xDA) return "尺寸未知"
            if (marker == 0xD8 || marker in 0xD0..0xD7) {
                i += 2
                continue
            }
            val len = ((d[i + 2].toInt() and 0xFF) shl 8) or (d[i + 3].toInt() and 0xFF)
            if (len < 2) return "长度异常"
            val isSof = marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if (isSof && i + 8 < d.size) {
                val h = ((d[i + 5].toInt() and 0xFF) shl 8) or (d[i + 6].toInt() and 0xFF)
                val w = ((d[i + 7].toInt() and 0xFF) shl 8) or (d[i + 8].toInt() and 0xFF)
                return "${w}×$h"
            }
            i += 2 + len
        }
        return "尺寸未知"
    }

    /**
     * 实时取景链路探针 v3（短超时，总时长 ≤30s，不会卡死）：
     * 0x9206 疑似 StartLiveView（响应可能迟到，3s 内未回也继续）；
     * 随后 12 秒内轮询帧候选 0x9403~0x9406/0x9202/0x9203；
     * 最后 0x9201 疑似 EndLiveView 恢复。全部结果写日志。
     */
    fun probeLiveView2(): List<String> {
        val c = need()
        val out = ArrayList<String>()

        fun tryOp(op: Long, params: LongArray, timeoutMs: Int): Pair<Boolean, Int> {
            val r = runCatching { c.transactShort(op.toInt(), params, timeoutMs) }
            return if (r.isSuccess) {
                true to r.getOrThrow().data.size
            } else {
                false to ((r.exceptionOrNull() as? PtpException)?.code ?: -1)
            }
        }

        val (startOk, startInfo) = tryOp(0x9206L, LongArray(0), 3000)
        out += "0x9206(疑似Start) → " + if (startOk) "OK ${startInfo}B" else "无响应/失败(0x%04X)".format(startInfo)

        if (startOk || startInfo == -1) {
            // 启动疑似成功（或状态未知）：12 秒内轮询帧候选
            val frameOps = longArrayOf(0x9403L, 0x9404L, 0x9405L, 0x9406L, 0x9202L, 0x9203L)
            val t0 = SystemClock.elapsedRealtime()
            var found = false
            while (SystemClock.elapsedRealtime() - t0 < 12_000 && !found && client != null) {
                for (op in frameOps) {
                    val (ok, n) = tryOp(op, LongArray(0), 2000)
                    if (ok && n > 0) {
                        out += "帧候选 0x%04X → OK %dB ★".format(op, n)
                        found = true
                    }
                }
            }
            if (!found) out += "12s 内未发现返回帧数据的操作"
        }
        val (endOk, endInfo) = tryOp(Ptp.OP_NIKON_LV_END.toLong(), LongArray(0), 2000)
        out += "0x9201(疑似End) → " + if (endOk) "OK ${endInfo}B" else "无响应/失败(0x%04X)".format(endInfo)
        liveViewOn = false
        out.forEach { log("取景2 $it") }
        return out
    }

    /**
     * 实时取景探针 v3：启动取景后，对候选操作在"取景中"状态下的响应码全量记录。
     * 对比基线（未取景：0x9403~06=0xA00B NotLiveView、0x9400~02=ParameterNotSupported），
     * 响应码发生变化的操作即为取景帧/状态通道。最后恢复并验证。
     */
    fun probeLiveView3(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()

        fun tryOp(op: Long, params: LongArray, timeoutMs: Int = 2000): Pair<Boolean, Int> {
            val r = runCatching { c.transactShort(op.toInt(), params, timeoutMs) }
            return if (r.isSuccess) {
                true to r.getOrThrow().data.size
            } else {
                false to ((r.exceptionOrNull() as? PtpException)?.code ?: -1)
            }
        }

        fun fmt(op: Long, ok: Boolean, info: Int): String =
            "0x%04X → %s".format(op, if (ok) "OK ${info}B" else Ptp.respName(info))

        // 启动取景（首次可能耗时较长，短超时重试）
        val (s1, _) = tryOp(0x9206L, LongArray(0), 3000)
        if (!s1) tryOp(0x9206L, LongArray(0), 5000)
        out += "start 0x9206 → $s1"

        // 取景中状态下的候选操作响应码全量记录
        val candidates = listOf(
            Triple(0x9400L, longArrayOf(handle, 0L, 65536L), "句柄,偏移,长度"),
            Triple(0x9401L, longArrayOf(handle), "句柄"),
            Triple(0x9402L, longArrayOf(handle), "句柄"),
            Triple(0x9403L, LongArray(0), "无参"),
            Triple(0x9404L, LongArray(0), "无参"),
            Triple(0x9405L, LongArray(0), "无参"),
            Triple(0x9406L, LongArray(0), "无参"),
            Triple(0x9202L, LongArray(0), "无参"),
            Triple(0x9203L, LongArray(0), "无参"),
            Triple(0x9204L, LongArray(0), "无参"),
            Triple(0x9205L, LongArray(0), "无参"),
            Triple(0x9209L, LongArray(0), "无参"),
        )
        for ((op, params, label) in candidates) {
            val (ok, info) = tryOp(op, params)
            out += "LV 0x%04X [%s] → %s".format(op, label, fmt(op, ok, info).substringAfter("→ "))
        }

        // 关闭取景并验证回到基线
        tryOp(Ptp.OP_NIKON_LV_END.toLong(), LongArray(0), 2000)
        val (ok2, info2) = tryOp(0x9403L, LongArray(0), 2000)
        out += "end 0x9201 → 已执行；验证 0x9403 → ${Ptp.respName(info2)}"

        liveViewOn = false
        out.forEach { log("取景3 $it") }
        return out
    }

    /**
     * 实时取景探针 v4：状态机完整探索。
     * 已知：0x9201 后 0x9403 从 NotLiveView 变 OK；0x9400 三参数稳定返回 OutOfFocus（疑似带对焦检查的拍摄类操作）。
     * 本探针：对焦 → 0x9400 对比 → 0x9201/0x9206 双向状态翻转 → 每个 OK 响应输出数据头 16 字节 hex。
     * 注意：0x9400 若为拍摄类操作，对焦后调用可能会实拍一张测试照。
     */
    fun probeLiveView4(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()

        fun hexHead(data: ByteArray): String =
            data.take(16).joinToString(" ") { "%02X".format(it) }

        fun tryOp(label: String, op: Long, params: LongArray): String {
            val r = runCatching { c.transactShort(op.toInt(), params, 2500) }
            return if (r.isSuccess) {
                val d = r.getOrThrow().data
                "$label → OK ${d.size}B 头: ${hexHead(d)}"
            } else {
                val code = (r.exceptionOrNull() as? PtpException)?.code ?: -1
                "$label → ${Ptp.respName(code)}"
            }
        }

        // 0) 先对焦（0x90C3），排除未对焦干扰
        runCatching { c.transact(0x90C3.toInt()) }
        out += "0x90C3 AF 已驱动"
        out += tryOp("基线 0x9403", 0x9403L, LongArray(0))

        // 1) 对焦后的 0x9400：若为拍摄类操作会在此现形
        out += tryOp("对焦后 0x9400[句柄,偏移,长度]", 0x9400L, longArrayOf(handle, 0L, 65536L))

        // 2) 0x9201 后的全家族状态
        out += tryOp("0x9201", 0x9201L, LongArray(0))
        out += tryOp("0x9201后 0x9403", 0x9403L, LongArray(0))
        out += tryOp("0x9201后 0x9403再来一次", 0x9403L, LongArray(0))
        out += tryOp("0x9201后 0x9404", 0x9404L, LongArray(0))
        out += tryOp("0x9201后 0x9405", 0x9405L, LongArray(0))
        out += tryOp("0x9201后 0x9406", 0x9406L, LongArray(0))
        out += tryOp("0x9201后 0x9202", 0x9202L, LongArray(0))
        out += tryOp("0x9201后 0x9209", 0x9209L, LongArray(0))
        out += tryOp("0x9201后 0x9400[句柄,偏移,长度]", 0x9400L, longArrayOf(handle, 0L, 65536L))

        // 3) 0x9206 后的状态（若 0x9206=end 则回到基线）
        out += tryOp("0x9206", 0x9206L, LongArray(0))
        out += tryOp("0x9206后 0x9403", 0x9403L, LongArray(0))

        // 4) 再次 0x9201，验证可重复开启
        out += tryOp("再次 0x9201", 0x9201L, LongArray(0))
        out += tryOp("再次后 0x9403", 0x9403L, LongArray(0))
        out += tryOp("收尾 0x9206", 0x9206L, LongArray(0))
        out += tryOp("收尾后 0x9403", 0x9403L, LongArray(0))

        liveViewOn = false
        out.forEach { log("取景4 $it") }
        return out
    }

    /**
     * 实时取景探针 v5：候机唤醒 → 启动取景 → 耐心轮询等取景热身（最长 30s） → 抳焦后测试 LV 拍摄 → 关闭。
     * 已知：0x9201=开启取景状态、0x9206=关闭、0x9403 在取景中返回 OK（首先 0B，可能热身后出帧）、
     *       0x9405 在取景中返回 OutOfFocus（疑似取景中拍摄，对焦优先）、0x9209 返回状态字节。
     */
    fun probeLiveView5(handle: Long): List<String> {
        val c = need()
        val out = ArrayList<String>()

        fun tryOp(op: Long, params: LongArray, timeoutMs: Int = 2500): Pair<Boolean, Int> {
            val r = runCatching { c.transactShort(op.toInt(), params, timeoutMs) }
            return if (r.isSuccess) {
                true to r.getOrThrow().data.size
            } else {
                false to ((r.exceptionOrNull() as? PtpException)?.code ?: -1)
            }
        }

        fun hexHead(data: ByteArray): String = data.take(16).joinToString(" ") { "%02X".format(it) }

        // 0) 唤醒相机：DeviceReady 轮询直到就绪
        var wake = 0
        while (wake < 10) {
            val r = runCatching { c.transact(Ptp.OP_NIKON_DEVICE_READY) }
            if (r.isSuccess) break
            wake++
            Thread.sleep(500)
        }
        out += "唤醒：${
            if (wake == 0) "立即就绪" else "等待 ${wake * 500}ms 后就绪"
        }"

        // 1) 基线
        out += "基线 0x9203 → " + tryOp(0x9203L, LongArray(0)).let { (ok, n) -> if (ok) "OK ${n}B" else Ptp.respName(n) }
        out += "基线 0x9209 → " + tryOp(0x9209L, LongArray(0)).let { (ok, n) -> if (ok) "OK ${n}B" else Ptp.respName(n) }

        // 2) 启动取景
        val (sOk, _) = tryOp(0x9201L, LongArray(0), 3000)
        out += "0x9201 启动 → $sOk"

        // 3) 耐心轮询 30s：等 0x9403/0x9203 出帧
        var frameOp: Long = 0
        var frames = 0
        val t0 = SystemClock.elapsedRealtime()
        var lastSizes = ""
        var afDone = false
        while (SystemClock.elapsedRealtime() - t0 < 30_000 && client != null) {
            val (ok3, n3) = tryOp(0x9403L, LongArray(0), 1500)
            val (ok2, n2) = tryOp(0x9203L, LongArray(0), 1500)
            lastSizes = "0x9403=${if (ok3) "${n3}B" else Ptp.respName(n3)} 0x9203=${if (ok2) "${n2}B" else Ptp.respName(n2)}"
            if (ok3 && n3 > 0 && frameOp == 0L) frameOp = 0x9403L
            if (ok2 && n2 > 0 && frameOp == 0L) frameOp = 0x9203L
            if (frameOp != 0L) {
                // 拿到帧：连续采样 5 次记录帧大小曲线
                var i = 0
                while (i < 5 && client != null) {
                    val (okF, nF) = tryOp(frameOp, LongArray(0), 1500)
                    out += "帧#${frames + 1} 0x%04X → ${if (okF) "${nF}B" else Ptp.respName(nF)}".format(frameOp)
                    if (okF) frames++
                    i++
                    Thread.sleep(300)
                }
                break
            }
            // 第 6 轮后驱动一次 AF（取景中对焦可能是出帧前提）
            if (attempt_marker(t0)) {
                runCatching { c.transact(0x90C3.toInt()) }
                out += "取景中驱动 AF"
            }
        }
        out += "轮询结果：$lastSizes，帧数=$frames，帧通道=0x%04X".format(frameOp)

        // 4) 取景中拍摄测试（先 AF 再 0x9405）
        if (frameOp != 0L || frames > 0) {
            runCatching { c.transact(0x90C3.toInt()) }
            val (ok5, n5) = tryOp(0x9405L, LongArray(0), 2500)
            out += "取景中 0x9405 拍摄测试 → " + if (ok5) "OK ${n5}B" else Ptp.respName(n5)
        }

        // 5) 关闭并验证
        tryOp(0x9206L, LongArray(0), 2000)
        val (okF2, nF2) = tryOp(0x9403L, LongArray(0), 2000)
        out += "关闭后 0x9403 → " + if (okF2) "OK ${nF2}B" else Ptp.respName(nF2)

        liveViewOn = false
        out.forEach { log("取景5 $it") }
        return out
    }

    private fun attempt_marker(t0: Long): Boolean =
        SystemClock.elapsedRealtime() - t0 > 6_000 && (SystemClock.elapsedRealtime() - t0) % 3000 < 700

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
