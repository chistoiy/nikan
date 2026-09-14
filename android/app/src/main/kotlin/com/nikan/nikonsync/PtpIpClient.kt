package com.nikan.nikonsync

import android.os.SystemClock
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicInteger
import javax.net.SocketFactory

/**
 * PTP/IP 客户端：持有命令与事件两条 TCP 连接（端口 15740），
 * 串行化 PTP 事务，后台线程读取相机事件。
 *
 * 握手使用尼康 WMU 官方 App 的固定 GUID（见 [Ptp.WMU_INITIATOR_GUID]），
 * 相机据此把本客户端识别为已配对主机，跳过配对直接提供完整操作集。
 */
class PtpIpClient(
    private val socketFactory: SocketFactory?,
    private val log: (String) -> Unit,
) {
    companion object {
        const val PORT = 15740
        const val DIAL_TIMEOUT_MS = 10_000
        const val IO_TIMEOUT_MS = 30_000
        private const val RECV_BUFFER_BYTES = 4 shl 20
        private const val SEND_BUFFER_BYTES = 1 shl 20
        private const val STREAM_BUFFER_BYTES = 1 shl 20
        /** GetPartialObject 每次请求的块大小：4MiB，减少往返提高 Wi-Fi 吞吐。 */
        const val PARTIAL_CHUNK_BYTES = 4L shl 20

        private const val PROGRESS_STEP = 1L shl 20

        /** DevicePropChanged 汇总输出间隔 */
        private const val PROP_FLUSH_MS = 2_000L
    }

    class TransactResult(val responseCode: Int, val params: LongArray, val data: ByteArray)

    private var cmd: Socket? = null
    private var evt: Socket? = null
    private var cmdIn: InputStream? = null
    private var cmdOut: OutputStream? = null
    private val txnCounter = AtomicInteger(0)
    private val txnLock = Any()
    @Volatile private var closing = false
    @Volatile private var linkDeadNotified = false

    /** 事务超时后命令流已错位且无法安全恢复，此连接作废（需重新连接）。 */
    @Volatile private var streamDesynced = false

    var deviceInfo: DeviceInfo? = null
        private set
    var cameraName: String = ""
        private set

    @Volatile var eventHandler: ((Int, LongArray) -> Unit)? = null
    @Volatile var disconnectHandler: ((String) -> Unit)? = null

    val isConnected: Boolean get() = cmd != null && deviceInfo != null

    // ---------------------------------------------------------------- 连接

    private fun newSocket(): Socket {
        val s = socketFactory?.createSocket() ?: Socket()
        s.tcpNoDelay = true
        s.keepAlive = true
        s.receiveBufferSize = RECV_BUFFER_BYTES
        s.sendBufferSize = SEND_BUFFER_BYTES
        return s
    }

    /**
     * 完整连接流程：命令连接握手 → 事件连接绑定 → 启动事件读取 →
     * OpenSession → GetDeviceInfo。任何一步失败都会清理并抛出 IOException。
     */
    fun connect(host: String, friendlyName: String) {
        synchronized(txnLock) {
            check(cmd == null) { "客户端已连接" }
            closing = false
            linkDeadNotified = false
            streamDesynced = false
            log("连接 $host:$PORT …")
            try {
                connectLocked(host, friendlyName)
            } catch (t: Throwable) {
                // 握手任一步失败都要回收已建立的 socket：上层会重试多次，
                // 泄漏的连接会持续占用相机侧的连接槽位。
                abortConnectLocked()
                throw t
            }
        }
    }

    /** 连接流程主体，必须持有 txnLock。 */
    private fun connectLocked(host: String, friendlyName: String) {
        val c = newSocket()
        try {
            c.connect(InetSocketAddress(host, PORT), DIAL_TIMEOUT_MS)
        } catch (e: Exception) {
            closeQuietly(c)
            throw IOException("无法连接 $host:$PORT（${e.message}）。请确认手机已连上相机热点。")
        }
        c.soTimeout = IO_TIMEOUT_MS
        val cin = BufferedInputStream(c.getInputStream(), STREAM_BUFFER_BYTES)
        val cout = BufferedOutputStream(c.getOutputStream(), STREAM_BUFFER_BYTES)

        val initPayload = Ptp.WMU_INITIATOR_GUID +
            PtpWire.encodeUtf16LeNullTerm(friendlyName) +
            ByteArray(4).also { PtpWire.putU32(it, 0, Ptp.PROTOCOL_VERSION_10) }
        PtpWire.writePacket(cout, Ptp.PKT_INIT_CMD_REQ, initPayload)
        val ack = PtpWire.readPacket(cin)
        if (ack.type == Ptp.PKT_INIT_FAIL) {
            throw IOException("相机拒绝连接（InitFail）— 是否已有 SnapBridge 或其他主机在连接？")
        }
        if (ack.type != Ptp.PKT_INIT_CMD_ACK) {
            throw IOException("握手异常：期待 InitCommandAck(2)，收到包类型 ${ack.type}")
        }
        val connNumber = PtpWire.getU32(ack.payload, 0)
        val (name, _) = PtpWire.decodeUtf16Le(ack.payload, 20)
        cameraName = name
        log("命令握手成功：连接号=$connNumber 相机名=\"$name\"")

        val e = newSocket()
        try {
            e.connect(InetSocketAddress(host, PORT), DIAL_TIMEOUT_MS)
        } catch (ex: Exception) {
            closeQuietly(e)
            throw IOException("无法建立事件连接（${ex.message}）")
        }
        e.soTimeout = 0
        val ein = BufferedInputStream(e.getInputStream(), 1 shl 16)
        val eout = BufferedOutputStream(e.getOutputStream(), 1 shl 16)
        PtpWire.writePacket(
            eout, Ptp.PKT_INIT_EVT_REQ,
            ByteArray(4).also { PtpWire.putU32(it, 0, connNumber) },
        )
        val eack = PtpWire.readPacket(ein)
        if (eack.type == Ptp.PKT_INIT_FAIL) {
            closeQuietly(e)
            throw IOException("相机拒绝事件连接（InitFail）")
        }
        if (eack.type != Ptp.PKT_INIT_EVT_ACK) {
            closeQuietly(e)
            throw IOException("事件握手异常：期待 InitEventAck(4)，收到包类型 ${eack.type}")
        }
        log("事件握手成功")

        cmd = c
        evt = e
        cmdIn = cin
        cmdOut = cout

        startEventReader(ein, eout)

        try {
            transact(Ptp.OP_OPEN_SESSION, longArrayOf(1))
        } catch (ex: PtpException) {
            if (ex.code != Ptp.RESP_SESSION_ALREADY_OPEN) {
                throw IOException("OpenSession 失败：${ex.message}")
            }
            log("会话已打开（重连场景），继续")
        }
        deviceInfo = PtpDatasets.parseDeviceInfo(transact(Ptp.OP_GET_DEVICE_INFO).data)
        log("设备信息：$deviceInfo")
    }

    /** 握手失败时的清理：只关底层 socket，不发协议层结束会话，并抑制断线回调。 */
    private fun abortConnectLocked() {
        closing = true
        closeQuietly(cmd)
        closeQuietly(evt)
        cmd = null
        evt = null
        cmdIn = null
        cmdOut = null
        deviceInfo = null
    }

    fun close() {
        val c: Socket?
        synchronized(txnLock) {
            c = cmd
            closing = true
            if (c != null) {
                try {
                    c.soTimeout = 3_000
                    doTransactLocked(Ptp.OP_CLOSE_SESSION, LongArray(0), null)
                    log("会话已关闭")
                } catch (_: Exception) {
                }
            }
            closeQuietly(cmd)
            closeQuietly(evt)
            cmd = null
            evt = null
            cmdIn = null
            cmdOut = null
            deviceInfo = null
        }
    }

    // ---------------------------------------------------------------- 事务

    /** 内存式事务：返回响应参数与完整数据。 */
    fun transact(op: Int, params: LongArray = LongArray(0)): TransactResult {
        val bos = ByteArrayOutputStream(1 shl 16)
        val res = doTransact(op, params) { chunk, _, _ -> bos.write(chunk) }
        return TransactResult(res.responseCode, res.params, bos.toByteArray())
    }

    /** 流式事务：数据阶段分块写入 out（用于大文件下载）。 */
    fun transactStream(
        op: Int,
        params: LongArray,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): TransactResult = doTransact(op, params) { chunk, received, total ->
        out.write(chunk)
        out.flush()
        onProgress(received, total)
    }

    /** 下载模式：运行时探测后锁定，失败可降级。 */
    enum class DlMode { HISPEED, PARTIAL, FULL }

    @Volatile private var dlMode: DlMode? = null

    /** 高速通道实际生效的操作码（0x9400~0x9406 之一）。 */
    @Volatile private var hiSpeedOp: Int = 0

    val effectiveDlMode: DlMode get() = dlMode ?: DlMode.PARTIAL

    /** 分块下载失败后强制降级为整文件下载。 */
    fun degradeToFullDownload() {
        if (dlMode != DlMode.FULL) log("下载模式已降级为整文件 GetObject")
        dlMode = DlMode.FULL
    }

    /** 用一次小规模探测确定相机实际支持的下载模式。 */
    private fun resolveDlMode(handle: Long, size: Long): DlMode {
        dlMode?.let { return it }
        if (size > 0) {
            val probeLen = minOf(65536L, size)
            // 1) 高速通道：0x9400~0x9406 三参数形态，输出必须与 0x101B 一致才启用
            if (deviceInfo?.supportsOperation(0x9400) == true) {
                var op = 0x9400
                while (op <= 0x9406) {
                    if (deviceInfo?.supportsOperation(op) == true) {
                        val hi = runCatching { transact(op, longArrayOf(handle, 0, probeLen)).data }.getOrNull()
                        if (hi != null && hi.isNotEmpty()) {
                            val ref = runCatching {
                                transact(Ptp.OP_GET_PARTIAL_OBJECT, longArrayOf(handle, 0, probeLen)).data
                            }.getOrNull()
                            if (ref != null && ref.contentEquals(hi)) {
                                log("下载模式：0x%04X 高速通道验证通过".format(op))
                                hiSpeedOp = op
                                dlMode = DlMode.HISPEED
                                return dlMode!!
                            }
                            log("0x%04X 有响应但输出与 0x101B 不一致，跳过".format(op))
                        }
                    }
                    op++
                }
            }
            // 2) 标准分块
            if (deviceInfo?.supportsOperation(Ptp.OP_GET_PARTIAL_OBJECT) == true) {
                try {
                    doTransact(Ptp.OP_GET_PARTIAL_OBJECT, longArrayOf(handle, 0, probeLen), null)
                    log("下载模式探测：GetPartialObject (0x101B) 可用")
                    dlMode = DlMode.PARTIAL
                    return dlMode!!
                } catch (e: PtpException) {
                    log("0x101B 探测失败（${e.message}），改用整文件下载")
                }
            }
        }
        dlMode = DlMode.FULL
        return DlMode.FULL
    }

    /**
     * 下载对象并写入 out，返回**实际写入的字节数**。
     *
     * 返回值必须由调用方与 GetObjectInfo 得到的 size 比对：分块模式下相机可能
     * 少传数据就结束，若按请求长度推进偏移就会静默丢数据，而文件被当成完整保存。
     */
    fun getObjectToStream(
        handle: Long,
        size: Long,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): Long {
        if (size <= 0) throw IOException("对象大小无效（$size），拒绝下载以免生成空文件")
        lastProgressNotified = 0L
        val written = when (resolveDlMode(handle, size)) {
            DlMode.HISPEED -> downloadChunked(size, out, onProgress) { off, want ->
                writeChunk(out, hiSpeedOp, handle, off, want)
            }
            DlMode.PARTIAL -> downloadChunked(size, out, onProgress) { off, want ->
                writeChunk(out, Ptp.OP_GET_PARTIAL_OBJECT, handle, off, want)
            }
            DlMode.FULL -> transactToStream(Ptp.OP_GET_OBJECT, longArrayOf(handle), out, size, onProgress)
        }
        if (written != size) throw IOException("传输不完整：期望 $size 字节，实际收到 $written 字节")
        return written
    }

    /**
     * 取一个分块写入 out，返回本次实际写入字节数。
     * 相机在响应参数里声明了长度时，必须与实际写入量一致——否则不能以声明值推进偏移。
     */
    private fun writeChunk(out: OutputStream, op: Int, handle: Long, offset: Long, want: Long): Long {
        var written = 0L
        val res = doTransact(op, longArrayOf(handle, offset, want)) { chunk, _, _ ->
            out.write(chunk)
            written += chunk.size
        }
        out.flush()
        if (res.params.isNotEmpty()) {
            val declared = res.params[0]
            if (declared != written) {
                throw IOException("分块长度不一致：相机声明 $declared 字节，实际收到 $written 字节（offset=$offset）")
            }
        }
        return written
    }

    /** 整文件下载：数据阶段直接落流，返回实际写入字节数。 */
    private fun transactToStream(
        op: Int,
        params: LongArray,
        out: OutputStream,
        size: Long,
        onProgress: (received: Long, total: Long) -> Unit,
    ): Long {
        var written = 0L
        doTransact(op, params) { chunk, _, total ->
            out.write(chunk)
            written += chunk.size
            val span = if (total > 0) total else size
            if (written - lastProgressNotified >= PROGRESS_STEP || written >= span) {
                lastProgressNotified = written
                onProgress(written, span)
            }
        }
        out.flush()
        return written
    }

    private var lastProgressNotified = 0L

    /** 循环拉取分块直到累计写入 size 字节，返回实际写入总量。 */
    private inline fun downloadChunked(
        size: Long,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
        chunk: (offset: Long, want: Long) -> Long,
    ): Long {
        var offset = 0L
        while (offset < size) {
            val want = minOf(PARTIAL_CHUNK_BYTES, size - offset)
            val read = chunk(offset, want)
            if (read <= 0L) throw IOException("分块读取提前结束（offset=$offset/$size）")
            if (read > want) throw IOException("分块返回超出请求长度（请求 $want，返回 $read）")
            offset += read
            onProgress(offset, size)
        }
        return offset
    }

    /**
     * 短超时事务：用于探针等"相机可能不应答"的场景。
     *
     * ⚠️ 超时即意味着命令流里可能残留半个包，之后每个事务都会解析错位。
     * 命令流无法安全恢复，因此**一次超时就会把该连接标记为作废**并触发断线回调，
     * 需要重新连接。调用方要接受"这次调用之后连接可能已失效"。
     */
    fun transactShort(op: Int, params: LongArray = LongArray(0), timeoutMs: Int = 3000): TransactResult =
        synchronized(txnLock) {
            val c = cmd ?: throw IOException("未连接相机")
            val prev = c.soTimeout
            c.soTimeout = timeoutMs
            try {
                val bos = ByteArrayOutputStream(1 shl 16)
                val res = doTransactLocked(op, params) { chunk, _, _ -> bos.write(chunk) }
                TransactResult(res.responseCode, res.params, bos.toByteArray())
            } finally {
                c.soTimeout = prev
            }
        }

    fun getThumbnailBytes(handle: Long): ByteArray = try {
        transact(Ptp.OP_NIKON_GET_LARGE_THUMB, longArrayOf(handle)).data
    } catch (e: PtpException) {
        log("大缩略图不可用（${e.message}），回退 GetThumb")
        transact(Ptp.OP_GET_THUMB, longArrayOf(handle)).data
    }

    private fun doTransact(
        op: Int,
        params: LongArray,
        onChunk: ((ByteArray, Long, Long) -> Unit)?,
    ): TransactResult = synchronized(txnLock) {
        doTransactLocked(op, params, onChunk)
    }

    /** 必须持有 txnLock（连接流程内为可重入调用）。 */
    private fun doTransactLocked(
        op: Int,
        params: LongArray,
        onChunk: ((ByteArray, Long, Long) -> Unit)?,
    ): TransactResult {
        // 一次超时就会让流里残留半个包，之后每个事务都解析错位。
        // 继续用只会拿到静默错误的结果（比断开更危险），因此直接拒绝后续请求。
        if (streamDesynced) throw IOException("上次事务超时后命令流已失同步，需重新连接相机")
        val cin = cmdIn ?: throw IOException("未连接相机")
        val cout = cmdOut ?: throw IOException("未连接相机")
        val txn = txnCounter.incrementAndGet() and 0x7FFFFFFF
        val req = ByteArray(10 + params.size * 4)
        PtpWire.putU32(req, 0, 1) // data phase: 无 / 仅数据入
        PtpWire.putU16(req, 4, op)
        PtpWire.putU32(req, 6, txn.toLong())
        params.forEachIndexed { i, v -> PtpWire.putU32(req, 10 + i * 4, v) }
        PtpWire.writePacket(cout, Ptp.PKT_OPERATION_REQUEST, req)

        var total = -1L
        var received = 0L
        while (true) {
            val pkt = try {
                PtpWire.readPacket(cin)
            } catch (e: SocketTimeoutException) {
                // 关键：超时后无法知道流里还剩多少字节，无法安全恢复。
                // 此前只是把异常抛给上层，连接表面还"活着"，于是：
                // 取景帧请求超时（1500ms）→ 流错位 → 保活探针排在后面
                // 读到 30 秒超时 → 判定断线 → 相机侧也放弃主机、关闭热点。
                streamDesynced = true
                log("命令通道读超时（操作 0x%04X）：流已失同步，连接作废".format(op))
                notifyLinkDead("命令通道读超时，流已失同步")
                throw IOException("事务超时（操作 0x%04X），命令流已失同步".format(op), e)
            }
            when (pkt.type) {
                Ptp.PKT_START_DATA -> total = PtpWire.getU64(pkt.payload, 4)
                Ptp.PKT_DATA, Ptp.PKT_END_DATA -> if (pkt.payload.size >= 4) {
                    val chunk = pkt.payload.copyOfRange(4, pkt.payload.size)
                    received += chunk.size
                    onChunk?.invoke(chunk, received, total)
                }
                Ptp.PKT_OPERATION_RESPONSE -> {
                    val code = PtpWire.getU16(pkt.payload, 0)
                    if (code != Ptp.RESP_OK) throw PtpException(code, "操作 0x%04X".format(op))
                    val respParams = ArrayList<Long>()
                    var off = 6
                    while (off + 4 <= pkt.payload.size) {
                        respParams.add(PtpWire.getU32(pkt.payload, off))
                        off += 4
                    }
                    return TransactResult(code, respParams.toLongArray(), ByteArray(0))
                }
                Ptp.PKT_EVENT -> log("命令通道收到事件包（忽略）")
                else -> log("命令通道收到未知包类型 ${pkt.type}（${pkt.payload.size}B）")
            }
        }
    }

    // ---------------------------------------------------------------- 事件

    /** 主动通知连接已死（保活探针等场景），每次连接只触发一次断线回调。 */
    fun notifyLinkDead(reason: String) {
        if (!linkDeadNotified && !closing) {
            linkDeadNotified = true
            log("连接失效：$reason")
            disconnectHandler?.invoke(reason)
        }
    }

    // ---- DevicePropChanged 聚合 ----

    private val propChanges = LinkedHashMap<Int, Int>()
    private var propFlushAt = 0L
    private val propLock = Any()

    /** 记录一次属性变化，最多每 2 秒汇总输出一行。 */
    private fun notePropChange(code: Int) {
        synchronized(propLock) { propChanges[code] = (propChanges[code] ?: 0) + 1 }
        val now = SystemClock.elapsedRealtime()
        if (now - propFlushAt < PROP_FLUSH_MS) return
        propFlushAt = now
        flushPropChanges()
    }

    private fun flushPropChanges() {
        val snapshot: LinkedHashMap<Int, Int>
        synchronized(propLock) {
            if (propChanges.isEmpty()) return
            snapshot = LinkedHashMap(propChanges)
            propChanges.clear()
        }
        log("属性变化：" + snapshot.entries.joinToString(" ") { "0x%04X×%d".format(it.key, it.value) })
    }

    private fun startEventReader(ein: InputStream, eout: OutputStream) {
        Thread {
            try {
                while (true) {
                    val pkt = PtpWire.readPacket(ein)
                    when (pkt.type) {
                        Ptp.PKT_EVENT -> if (pkt.payload.size >= 6) {
                            val code = PtpWire.getU16(pkt.payload, 0)
                            val params = ArrayList<Long>()
                            var off = 6
                            while (off + 4 <= pkt.payload.size) {
                                params.add(PtpWire.getU32(pkt.payload, off))
                                off += 4
                            }
                            // 属性变化事件按码聚合：相机每秒推 1~3 次且多个属性交替出现，
                            // 逐条记日志会在两分钟内刷满 App 侧 300 条环形缓冲，
                            // 把真正有用的协议日志挤掉。
                            if (code == Ptp.EVT_DEVICE_PROP_CHANGED && params.isNotEmpty()) {
                                notePropChange(params[0].toInt())
                            } else {
                                log("相机事件：${Ptp.evtName(code)} ${params.joinToString()}")
                            }
                            eventHandler?.invoke(code, params.toLongArray())
                        }
                        Ptp.PKT_PROBE_REQUEST -> runCatching {
                            PtpWire.writePacket(eout, Ptp.PKT_PROBE_RESPONSE, ByteArray(0))
                        }
                        else -> log("事件通道：包类型 ${pkt.type}（忽略）")
                    }
                }
            } catch (t: Throwable) {
                // 必须是 Throwable：解析异常里的 OutOfMemoryError 等 Error 若逃逸，
                // 线程会静默死亡且不触发断线回调，UI 将永远停在"已连接"却收不到事件。
                if (!closing) {
                    notifyLinkDead(t.message ?: "事件连接丢失")
                }
            }
        }.apply {
            isDaemon = true
            name = "ptp-event-reader"
            start()
        }
    }

    private fun closeQuietly(s: Socket?) {
        try {
            s?.close()
        } catch (_: Exception) {
        }
    }
}
