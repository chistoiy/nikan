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
import java.util.concurrent.atomic.AtomicInteger
import javax.net.SocketFactory

/** 兼容旧引用：事务结果统一为 [PtpSession.TransactResult]。 */
typealias TransactResult = PtpSession.TransactResult

/** 兼容旧引用：下载模式统一为 [PtpSession.DlMode]。 */
typealias DlMode = PtpSession.DlMode


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
) : PtpSession {
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

        /**
         * 数据外发（data-OUT）单包上限。
         * 与 libgphoto2 的 `WRITE_BLOCKSIZE`（64KiB）保持一致——相机端按这个量级
         * 组包最稳妥，属性写入这类几字节的数据只会产生一包 EndData。
         */
        private const val DATA_OUT_BLOCK = 64 * 1024

        /** DevicePropChanged 汇总输出间隔 */
        private const val PROP_FLUSH_MS = 2_000L

        /** 放弃一个事务后，等待它那笔迟到响应的预算（超时到就继续，不再等） */
        private const val ABANDON_DRAIN_MS = 1_200L

        /** 被放弃的是"数据相位可能很大"的操作时用的预算（等不到就必须作废连接） */
        private const val ABANDON_DRAIN_HEAVY_MS = 4_000L
    }

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

    /**
     * 超时发生在包边界时被"放弃"的事务号：它的响应可能稍后才到，
     * 下一笔事务开始前要把它读掉（否则会被当成自己的响应）。
     * 只有确认相机回显事务号（[txnEcho] == true）时才启用这条恢复路径。
     */
    @Volatile private var abandonedTxn: Long = 0L

    /** 被放弃事务的操作码：用于判断它的数据相位有多大（决定清理预算与是否必须成功）。 */
    @Volatile private var abandonedOp: Int = 0

    /**
     * 相机是否在 OperationResponse 里回显事务号（null = 尚未观测到）。
     * 标准 PTP/IP 要求回显；一旦发现不回显，就退回"超时即作废"的老行为，
     * 因为那时无法区分迟到响应与自己的响应。
     */
    @Volatile private var txnEcho: Boolean? = null

    override var deviceInfo: DeviceInfo? = null
        private set
    override var cameraName: String = ""
        private set

    @Volatile override var eventHandler: ((Int, LongArray) -> Unit)? = null
    @Volatile override var disconnectHandler: ((String) -> Unit)? = null

    override val isConnected: Boolean get() = cmd != null && deviceInfo != null

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
    override fun connect(host: String, friendlyName: String) {
        synchronized(txnLock) {
            check(cmd == null) { "客户端已连接" }
            closing = false
            linkDeadNotified = false
            streamDesynced = false
            abandonedTxn = 0L
            abandonedOp = 0
            txnEcho = null
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
        // 连上时报一次链路信号：UI 的信号格若与这行不符，一眼能看出取数有问题
        runCatching {
            val w = CameraEngine.wifiInfo()
            log("链路信号：${w["signalLevel"]}/4 格（${w["rssi"]} dBm）· 速率 ${w["linkSpeed"]} Mbps")
        }
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

    override fun close() {
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
    override fun transact(op: Int, params: LongArray): TransactResult {
        val bos = ByteArrayOutputStream(1 shl 16)
        val res = doTransact(op, params, { chunk, _, _ -> bos.write(chunk) })
        return TransactResult(res.responseCode, res.params, bos.toByteArray())
    }

    /** 流式事务：数据阶段分块写入 out（用于大文件下载）。 */
    fun transactStream(
        op: Int,
        params: LongArray,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): TransactResult = doTransact(op, params, { chunk, received, total ->
        out.write(chunk)
        out.flush()
        onProgress(received, total)
    })

    /** 下载模式：运行时探测后锁定，失败可降级。 */
    override fun transactWithDataOut(op: Int, params: LongArray, data: ByteArray): TransactResult =
        doTransact(op, params, null, data)

    @Volatile private var dlMode: DlMode? = null

    /** 高速通道实际生效的操作码（0x9400~0x9406 之一）。 */
    @Volatile private var hiSpeedOp: Int = 0

    override val effectiveDlMode: DlMode get() = dlMode ?: DlMode.PARTIAL

    /** 分块下载失败后强制降级为整文件下载。 */
    override fun degradeToFullDownload() {
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
    override fun getObjectToStream(
        handle: Long,
        size: Long,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): Long {
        if (size <= 0) throw IOException("对象大小无效（$size），拒绝下载以免生成空文件")
        lastProgressNotified = 0L
        val written = when (resolveDlMode(handle, size)) {
            DlMode.HISPEED -> downloadChunked(size, out, onProgress) { off, want ->
                writeChunk(out, hiSpeedOp, handle, off, want, off, size, onProgress)
            }
            DlMode.PARTIAL -> downloadChunked(size, out, onProgress) { off, want ->
                writeChunk(out, Ptp.OP_GET_PARTIAL_OBJECT, handle, off, want, off, size, onProgress)
            }
            DlMode.FULL -> transactToStream(Ptp.OP_GET_OBJECT, longArrayOf(handle), out, size, onProgress)
        }
        if (written != size) throw IOException("传输不完整：期望 $size 字节，实际收到 $written 字节")
        return written
    }

    /**
     * 取一个分块写入 out，返回本次实际写入字节数。
     * 相机在响应参数里声明了长度时，必须与实际写入量一致——否则不能以声明值推进偏移。
     *
     * [base]/[total]/[onProgress] 用于**分块内部的进度上报**：一个 4MiB 分块在
     * 1.5MB/s 的 Wi-Fi 上要 2.7 秒，若只在分块结束时才报一次，UI 的进度条会
     * 长时间不动——看起来就像卡死（用户完全无法区分两者）。按 1MiB 上报后
     * 进度条是连续走的。
     */
    private fun writeChunk(
        out: OutputStream,
        op: Int,
        handle: Long,
        offset: Long,
        want: Long,
        base: Long = 0L,
        total: Long = 0L,
        onProgress: ((Long, Long) -> Unit)? = null,
    ): Long {
        var written = 0L
        val res = doTransact(op, longArrayOf(handle, offset, want), { chunk, _, _ ->
            out.write(chunk)
            written += chunk.size
            if (onProgress != null && written - lastProgressNotified >= PROGRESS_STEP) {
                lastProgressNotified = written
                onProgress(base + written, total)
            }
        })
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
        doTransact(op, params, { chunk, _, total ->
            out.write(chunk)
            written += chunk.size
            val span = if (total > 0) total else size
            if (written - lastProgressNotified >= PROGRESS_STEP || written >= span) {
                lastProgressNotified = written
                onProgress(written, span)
            }
        })
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
     * 短超时事务：用于探针、取景帧等"相机可能不应答"的场景。
     *
     * 超时处理分两种情况（见 [doTransactLocked]）：
     * - **超时落在包边界**（相机只是没答）→ 放弃这笔事务，但**连接保留**，
     *   迟到的响应会在下一笔事务前被读掉并丢弃；
     * - **半个包留在流里**，或相机不回显事务号 → 无法安全恢复，作废连接 + 断线回调。
     *
     * 因此调用方仍然要容忍"这次调用失败"，但不必再假定"这次调用之后连接一定已死"。
     */
    override fun transactShort(op: Int, params: LongArray, timeoutMs: Int): TransactResult =
        synchronized(txnLock) {
            val c = cmd ?: throw IOException("未连接相机")
            val prev = c.soTimeout
            c.soTimeout = timeoutMs
            try {
                val bos = ByteArrayOutputStream(1 shl 16)
                val res = doTransactLocked(op, params, { chunk, _, _ -> bos.write(chunk) })
                TransactResult(res.responseCode, res.params, bos.toByteArray())
            } finally {
                c.soTimeout = prev
            }
        }

    override fun getThumbnailBytes(handle: Long): ByteArray = try {
        transact(Ptp.OP_NIKON_GET_LARGE_THUMB, longArrayOf(handle)).data
    } catch (e: PtpException) {
        log("大缩略图不可用（${e.message}），回退 GetThumb")
        transact(Ptp.OP_GET_THUMB, longArrayOf(handle)).data
    }

    private fun doTransact(
        op: Int,
        params: LongArray,
        onChunk: ((ByteArray, Long, Long) -> Unit)?,
        dataOut: ByteArray? = null,
    ): TransactResult = synchronized(txnLock) {
        doTransactLocked(op, params, onChunk, dataOut)
    }

    /** 必须持有 txnLock（连接流程内为可重入调用）。 */
    private fun doTransactLocked(
        op: Int,
        params: LongArray,
        onChunk: ((ByteArray, Long, Long) -> Unit)?,
        dataOut: ByteArray? = null,
    ): TransactResult {
        // 一次超时就会让流里残留半个包，之后每个事务都解析错位。
        // 继续用只会拿到静默错误的结果（比断开更危险），因此直接拒绝后续请求。
        if (streamDesynced) throw IOException("上次事务超时后命令流已失同步，需重新连接相机")
        val cin = cmdIn ?: throw IOException("未连接相机")
        val cout = cmdOut ?: throw IOException("未连接相机")
        // 上一笔被放弃的事务若已回包，先把它读掉，避免它的数据被算进本笔
        drainAbandonedLocked(cin)
        // 清理过程中若读到半个包，流已失同步，本笔不能再发
        if (streamDesynced) throw IOException("上次事务超时后命令流已失同步，需重新连接相机")
        val txn = (txnCounter.incrementAndGet() and 0x7FFFFFFF).toLong()
        val req = ByteArray(10 + params.size * 4)
        PtpWire.putU32(req, 0, if (dataOut != null) 2 else 1) // data phase: 无/数据入=1，数据出=2
        PtpWire.putU16(req, 4, op)
        PtpWire.putU32(req, 6, txn.toLong())
        params.forEachIndexed { i, v -> PtpWire.putU32(req, 10 + i * 4, v) }
        PtpWire.writePacket(cout, Ptp.PKT_OPERATION_REQUEST, req)
        // 数据外发（PTP_DP_SENDDATA）。
        //
        // 报文格式按 libgphoto2 `ptpip.c` 的 `ptp_ptpip_senddata()` 实现，**两处关键**：
        // 1) StartData 载荷 = [事务号 u32][总长度 u32][未知 u32=0]，共 12 字节（整包 20）；
        // 2) Data / EndData 载荷 = [事务号 u32][数据]，**这里是事务号，不是偏移量**；
        //    最后一块必须是 EndData（即使数据很小、只有一包）。
        //
        // 此前实现写的是 [总长度 u64] 与 [偏移 u32]：相机读到的"事务号"分别等于
        // 数据长度和 0，与请求里的事务号对不上 → 相机一律回
        // `TransactionCancelled(0x2017)`。这就是"改光圈/快门/ISO 永远失败"的根因，
        // 也是 SetDevicePropValue 修好之后仍旧失败的原因（症状相同、层次不同）。
        if (dataOut != null) {
            val start = ByteArray(12)
            PtpWire.putU32(start, 0, txn)
            PtpWire.putU32(start, 4, dataOut.size.toLong())
            PtpWire.putU32(start, 8, 0)
            PtpWire.writePacket(cout, Ptp.PKT_START_DATA, start)
            var off = 0
            do {
                val n = minOf(DATA_OUT_BLOCK, dataOut.size - off)
                val isLast = off + n >= dataOut.size
                val pkt = ByteArray(4 + n)
                PtpWire.putU32(pkt, 0, txn)
                if (n > 0) dataOut.copyInto(pkt, 4, off, off + n)
                PtpWire.writePacket(cout, if (isLast) Ptp.PKT_END_DATA else Ptp.PKT_DATA, pkt)
                off += n
            } while (off < dataOut.size)
        }

        var total = -1L
        var received = 0L
        while (true) {
            val pkt = try {
                PtpWire.readPacketTracked(cin)
            } catch (e: PacketTimeoutException) {
                if (e.partialBytes == 0 && abandonedTxn == 0L && txnEcho == true) {
                    // 超时落在包边界：流位置仍然合法，只是这笔事务的响应还没来。
                    // 记下事务号，下一笔事务开始前会把它读掉并丢弃，连接继续可用。
                    // 这正是"取景帧慢 → 整条连接作废 → 相机三分钟不认新连接"的破局点。
                    abandonedTxn = txn
                    abandonedOp = op
                    log(
                        "命令通道读超时（操作 0x%04X）：超时在包边界，放弃该事务、连接保留"
                            .format(op),
                    )
                    throw IOException(
                        "事务 0x%04X 超时（相机未在超时内应答），已放弃该事务，连接仍可用"
                            .format(op),
                        e,
                    )
                }
                // 半个包留在流里（或相机不回显事务号，无法安全归属迟到响应）：
                // 无法安全恢复，一次超时就把连接标记为作废并触发断线回调。
                streamDesynced = true
                log(
                    "命令通道读超时（操作 0x%04X）：已收 ${e.partialBytes} 字节，流已失同步，连接作废"
                        .format(op),
                )
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
                    // 事务号在响应载荷的偏移 2（响应码 u16 之后）。
                    val respTxn = if (pkt.payload.size >= 6) PtpWire.getU32(pkt.payload, 2) else -1L
                    if (txnEcho == null) {
                        txnEcho = respTxn == txn
                        log(
                            if (txnEcho == true) "事务号回显校验通过（$respTxn）"
                            else "相机不回显事务号（回显 $respTxn / 发送 $txn）：超时恢复退化为作废重连",
                        )
                    }
                    if (txnEcho == true && respTxn != txn) {
                        // 迟到/无法归属的响应：丢弃后继续等自己的那一笔。
                        // 这是放弃事务后"不把别人的响应当自己的"的最后一道保险。
                        if (respTxn == abandonedTxn) abandonedTxn = 0L
                        log("丢弃过期响应（事务号 $respTxn ≠ 当前 $txn）")
                        continue
                    }
                    val code = PtpWire.getU16(pkt.payload, 0)
                    if (code != Ptp.RESP_OK) throw PtpException(code, "操作 0x%04X".format(op))
                    val respParams = ArrayList<Long>()
                    var off = 6
                    while (off + 4 <= pkt.payload.size) {
                        respParams.add(PtpWire.getU32(pkt.payload, off))
                        off += 4
                    }
                    abandonedTxn = 0L
                    return TransactResult(code, respParams.toLongArray(), ByteArray(0))
                }
                Ptp.PKT_EVENT -> log("命令通道收到事件包（忽略）")
                else -> log("命令通道收到未知包类型 ${pkt.type}（${pkt.payload.size}B）")
            }
        }
    }

    /**
     * 读掉上一笔被放弃事务的迟到响应（含它的数据相位），使流回到"只属于当前事务"的状态。
     *
     * 必须在发送新请求之前、持有 txnLock 时调用。做法：短超时轮询，
     * 依次丢弃收到的报文，直到看见该事务号的 OperationResponse（PTP/IP 规定数据
     * 相位一定在终结响应之前，所以看到它就代表这笔事务彻底结束了）。
     *
     * **预算按"被放弃操作的数据量"分级**（真机教训 2026-09-15）：0x920F 中等图
     * 单张就有 881KB，超时后它的响应会稍后涌入；若按小操作的 1.2s 预算草率放弃，
     * 这 881KB 就可能被算进紧接着开始的下载里。因此数据相位可能很大的操作给 4s，
     * 而且**等不到就明确作废连接**——宁可让用户重连，也不能把数据混进大文件传输。
     * 小操作（探针/取景帧）仍按 1.2s 软放弃：最坏只是多一帧旧画面。
     */
    private fun drainAbandonedLocked(cin: InputStream) {
        val t = abandonedTxn
        if (t == 0L) return
        val op = abandonedOp
        val c = cmd
        abandonedTxn = 0L
        abandonedOp = 0
        if (c == null || txnEcho != true) return
        val heavy = isDataHeavy(op)
        val budget = if (heavy) ABANDON_DRAIN_HEAVY_MS else ABANDON_DRAIN_MS
        val prev = c.soTimeout
        val deadline = SystemClock.elapsedRealtime() + budget
        try {
            while (SystemClock.elapsedRealtime() < deadline) {
                c.soTimeout = 250
                val pkt = try {
                    PtpWire.readPacketTracked(cin)
                } catch (e: PacketTimeoutException) {
                    if (e.partialBytes > 0) {
                        streamDesynced = true
                        log("清理迟到响应时读到半个包，流已失同步，连接作废")
                        notifyLinkDead("清理迟到响应时流失同步")
                        return
                    }
                    continue // 250ms 内没有数据：还在等，继续轮询
                } catch (e: Exception) {
                    return // socket 异常交给后续事务路径处理
                }
                if (pkt.type == Ptp.PKT_OPERATION_RESPONSE && pkt.payload.size >= 6 &&
                    PtpWire.getU32(pkt.payload, 2) == t
                ) {
                    log("已清理上一笔超时事务（0x%s）的迟到响应".format(t.toString(16)))
                    return
                }
            }
            if (heavy) {
                streamDesynced = true
                log(
                    "放弃的事务 0x%04X（数据相位较大）在 ${budget}ms 内未收到终结响应，" +
                        "无法保证后续大文件传输不被混入，连接作废".format(op),
                )
                notifyLinkDead("大事务的迟到响应未清理，为避免数据混淆作废连接")
            } else {
                log("超时事务 0x%s 的响应在 ${budget}ms 内未到达，继续后续事务".format(t.toString(16)))
            }
        } finally {
            c.soTimeout = prev
        }
    }

    /** 数据相位可能很大的操作：放弃它们之后必须确认清理干净，否则不能开始大传输。 */
    private fun isDataHeavy(op: Int): Boolean {
        if (op in 0x9400..0x9406) return true // 厂商高速读取族
        return op == Ptp.OP_GET_OBJECT ||
            op == Ptp.OP_GET_PARTIAL_OBJECT ||
            op == Ptp.OP_NIKON_GET_FHD_PICTURE
    }

    // ---------------------------------------------------------------- 事件

    /** 主动通知连接已死（保活探针等场景），每次连接只触发一次断线回调。 */
    override fun notifyLinkDead(reason: String) {
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
