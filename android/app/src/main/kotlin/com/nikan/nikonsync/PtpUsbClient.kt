package com.nikan.nikonsync

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.io.IOException
import java.io.OutputStream

/**
 * PTP over USB 传输层（U1）。把 U0 探针（PtpUsbProbe）验证过的全部经验产品化：
 *
 * - **IN 端点按 maxPacket 整包读 + 余料缓冲**（§7.3：12 字节读头是九轮排查的真因）；
 * - **事务串行 + 单调事务号**（事务号归零会与 OpenSession 撞号，§7.4）；
 * - **绝不对 IN 端点 clearHalt**（清一次丢一次）；OUT 发送失败清一次 STALL 重试；
 * - **恢复**：设备从总线消失时轮询等待重现（≤10s）、重新授权、重发，恢复失败才判死；
 * - 下载走 GetObject 整文件流式（实测 27.1 MB/s），64KB 分块落流。
 *
 * 空闲期相机会周期性重枚举（§7.2，严格 3.4s 断/3.65s 挂）；活跃传输期间连接
 * 保持住。因此每次 I/O 失败都先走恢复，不能把一次 -1 当作连接死亡。
 */
class PtpUsbClient(
    private val appCtx: () -> Context,
    private val log: (String) -> Unit,
) : PtpSession {

    companion object {
        private const val HEADER_BYTES = 12
        private const val BULK_TIMEOUT_MS = 5_000
        private const val CT_COMMAND = 1
        private const val CT_DATA = 2
        private const val CT_RESPONSE = 3
        private const val CT_EVENT = 4

        /** 单次分配上限（readPayload 会 new 等长数组）；流式下载不经过它。 */
        private const val MAX_PAYLOAD = 64 shl 20

        /** 下载/响应读取的分块：AOSP 注明 USB 读 >16K 有坑，64KB 为稳妥折中。 */
        private const val STREAM_CHUNK = 64 shl 10

        private const val ACTION_USB_PERMISSION = "com.nikan.nikonsync.USB_PERMISSION"

        /** 设备从总线上消失到重新挂上的离线窗（实测约 3.4s），轮询上限留足余量。 */
        private const val REAPPEAR_WAIT_MS = 10_000L

        /** 事务内"无数据"重读：间隔 200ms（密集重试会打断设备正要送出的数据，§7.4）。 */
        private const val EMPTY_RETRY_MS = 200L
        private const val EMPTY_RETRY_MAX = 15
    }

    private var device: UsbDevice? = null
    private var conn: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private var epInt: UsbEndpoint? = null
    private var txnId = 0L
    private val txnLock = Any()

    /** 上次整包读多出的字节（跨容器背靠背到达），按序供后续读取，绝不丢弃。 */
    private var inLeftover: ByteArray = ByteArray(0)

    /** 事件端点独立余料（与 bulk IN 的 leftover 互不干扰）。 */
    private var evtLeftover: ByteArray = ByteArray(0)

    @Volatile private var closing = false
    @Volatile private var deadNotified = false
    @Volatile private var eventThread: Thread? = null

    override var deviceInfo: DeviceInfo? = null
        private set
    override var cameraName: String = ""
        private set
    @Volatile override var eventHandler: ((Int, LongArray) -> Unit)? = null
    @Volatile override var disconnectHandler: ((String) -> Unit)? = null
    override val isConnected: Boolean get() = conn != null && deviceInfo != null
    override val effectiveDlMode: PtpSession.DlMode get() = PtpSession.DlMode.FULL

    // ---------------------------------------------------------------- 连接

    override fun connect(arg: String, friendlyName: String) {
        val ctx = appCtx()
        val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager
            ?: throw IOException("无法获取 USB 服务")
        closing = false
        deadNotified = false

        val dev = pickPtpDevice(mgr) ?: throw IOException("未找到 USB 相机（请确认已用数据线连接并在相机菜单选择 MTP/PTP）")
        if (!ensurePermission(ctx, mgr, dev)) throw IOException("USB 权限被拒绝")

        val c = mgr.openDevice(dev) ?: throw IOException("打开 USB 设备失败")
        val ptp = pickStillImageInterface(dev)
        if (ptp == null) {
            runCatching { c.close() }
            throw IOException("设备没有 Still Image 接口（class=6）")
        }
        if (!c.claimInterface(ptp, true)) {
            runCatching { c.close() }
            throw IOException("占用 USB 接口失败（可能被系统 MTP 服务占用）")
        }
        val ein = findBulk(ptp, UsbConstants.USB_DIR_IN)
        val eout = findBulk(ptp, UsbConstants.USB_DIR_OUT)
        val eint = findInterrupt(ptp)
        if (ein == null || eout == null) {
            runCatching { c.releaseInterface(ptp) }
            runCatching { c.close() }
            throw IOException("未找到 Bulk 端点")
        }
        device = dev
        conn = c
        iface = ptp
        epIn = ein
        epOut = eout
        epInt = eint
        inLeftover = ByteArray(0)
        evtLeftover = ByteArray(0)
        log("USB 会话就绪：${dev.deviceName}（in 0x%02X / out 0x%02X）".format(ein.address, eout.address))

        // OpenSession：沿用相机上已打开的会话（残留会话多为上次中断所留）。
        // transactInner 对非 OK 响应抛 PtpException，这里只放行 SessionAlreadyOpen。
        try {
            transactInner(Ptp.OP_OPEN_SESSION, longArrayOf(1L))
        } catch (e: PtpException) {
            if (e.code != Ptp.RESP_SESSION_ALREADY_OPEN) throw IOException("OpenSession 失败：${Ptp.respName(e.code)}")
        }
        val di = transactInner(Ptp.OP_GET_DEVICE_INFO, LongArray(0))
        if (di.responseCode != Ptp.RESP_OK) throw IOException("GetDeviceInfo 失败：${Ptp.respName(di.responseCode)}")
        deviceInfo = PtpDatasets.parseDeviceInfo(di.data)
            ?: throw IOException("DeviceInfo 解析失败（${di.data.size}B）")
        cameraName = deviceInfo?.model ?: friendlyName
        startEventThread()
    }

    override fun getThumbnailBytes(handle: Long): ByteArray = try {
        transact(Ptp.OP_NIKON_GET_LARGE_THUMB, longArrayOf(handle)).data
    } catch (e: PtpException) {
        log("大缩略图不可用（${e.message}），回退 GetThumb")
        transact(Ptp.OP_GET_THUMB, longArrayOf(handle)).data
    }

    override fun close() {
        closing = true
        eventThread = null
        closeQuietly()
    }

    private fun closeQuietly() {
        runCatching { conn?.releaseInterface(iface) }
        runCatching { conn?.close() }
        conn = null
        iface = null
        epIn = null
        epOut = null
        epInt = null
    }

    /** 挑 Still Image 接口（class=6/sub=1，优先 proto=1）。 */
    private fun pickStillImageInterface(dev: UsbDevice): UsbInterface? {
        var fallback: UsbInterface? = null
        for (i in 0 until dev.interfaceCount) {
            val f = dev.getInterface(i)
            if (f.interfaceClass == 6 && f.interfaceSubclass == 1) {
                if (f.interfaceProtocol == 1) return f
                if (fallback == null) fallback = f
            }
        }
        return fallback
    }

    private fun pickPtpDevice(mgr: UsbManager): UsbDevice? =
        mgr.deviceList.values.firstOrNull { pickStillImageInterface(it) != null }

    private fun findBulk(f: UsbInterface, direction: Int): UsbEndpoint? {
        for (i in 0 until f.endpointCount) {
            val e = f.getEndpoint(i)
            if (e.type == UsbConstants.USB_ENDPOINT_XFER_BULK && e.direction == direction) return e
        }
        return null
    }

    private fun findInterrupt(f: UsbInterface): UsbEndpoint? {
        for (i in 0 until f.endpointCount) {
            val e = f.getEndpoint(i)
            if (e.type == UsbConstants.USB_ENDPOINT_XFER_INT && e.direction == UsbConstants.USB_DIR_IN) return e
        }
        return null
    }

    /** 请求 USB 权限（系统弹窗），阻塞等待用户选择。 */
    private fun ensurePermission(ctx: Context, mgr: UsbManager, dev: UsbDevice): Boolean {
        if (mgr.hasPermission(dev)) return true
        val latch = java.util.concurrent.CountDownLatch(1)
        var granted = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                granted = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                latch.countDown()
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION), Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, IntentFilter(ACTION_USB_PERMISSION))
        }
        try {
            val pi = PendingIntent.getBroadcast(
                ctx, 0,
                Intent(ACTION_USB_PERMISSION).setPackage(ctx.packageName),
                if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0,
            )
            mgr.requestPermission(dev, pi)
            log("USB 权限请求已弹出，等待用户允许…")
            latch.await()
        } finally {
            runCatching { ctx.unregisterReceiver(receiver) }
        }
        return granted
    }

    // ---------------------------------------------------------------- 事务

    private fun nextTxn(): Long = (++txnId) and 0x7FFFFFFFL

    override fun transact(op: Int, params: LongArray): PtpSession.TransactResult {
        if (closing) throw IOException("连接已关闭")
        synchronized(txnLock) {
            val first = runCatching { transactInner(op, params) }
            if (first.isSuccess) return first.getOrThrow()
            val err = first.exceptionOrNull() ?: IOException("未知错误")
            // 响应码异常（相机明确拒绝）不是传输故障：像 Wi-Fi 侧一样原样上抛，
            // 让上层的重试策略（如未对焦 0xA004、忙 0x2019）按语义处理
            if (err is PtpException) throw err
            if (closing) throw err
            val why = err.message ?: err.javaClass.simpleName
            log("USB 0x%04X 传输失败（$why），尝试重枚举恢复".format(op))
            // 恢复：等设备重现 → 重新授权 → 重试一次（新事务号）
            if (!reopenAfterEnumeration()) {
                notifyDead("USB 恢复失败：$why")
                throw err
            }
            val second = runCatching { transactInner(op, params) }
            if (second.isSuccess) return second.getOrThrow()
            notifyDead("USB 重试仍失败：${second.exceptionOrNull()?.message}")
            throw second.exceptionOrNull() ?: err
        }
    }

    override fun transactWithDataOut(op: Int, params: LongArray, data: ByteArray): PtpSession.TransactResult {
        if (closing) throw IOException("连接已关闭")
        synchronized(txnLock) {
            val first = runCatching { transactInner(op, params, data) }
            if (first.isSuccess) return first.getOrThrow()
            val err = first.exceptionOrNull() ?: IOException("未知错误")
            if (err is PtpException) throw err
            if (closing) throw err
            if (!reopenAfterEnumeration()) {
                notifyDead("USB 恢复失败：${err.message}")
                throw err
            }
            return transactInner(op, params, data)
        }
    }

    /** 单次事务（无恢复）：发命令 → [数据外发] → 收 DATA/事件/RESPONSE。 */
    private fun transactInner(op: Int, params: LongArray, dataOut: ByteArray? = null): PtpSession.TransactResult {
        // 取消下载会中断数据相位、留下未读完的字节。此时绝不能复用连接：
        // 残留的 DATA 容器会被下一笔事务当成自己的数据读走（并按载荷长度分配内存）。
        // 抛 IOException 让调用方的恢复路径重建连接。
        if (needsReopen) throw IOException("取消下载后连接已作废，需重建后再操作")
        val c = conn ?: throw IOException("USB 连接未建立")
        val ein = epIn ?: throw IOException("USB 连接未建立")
        val eout = epOut ?: throw IOException("USB 连接未建立")
        val txn = nextTxn()
        val buf = ByteArray(HEADER_BYTES + params.size * 4)
        PtpWire.putU32(buf, 0, buf.size.toLong())
        PtpWire.putU16(buf, 4, CT_COMMAND)
        PtpWire.putU16(buf, 6, op)
        PtpWire.putU32(buf, 8, txn)
        params.forEachIndexed { i, v -> PtpWire.putU32(buf, HEADER_BYTES + i * 4, v) }
        sendContainer(c, eout, buf, "命令 0x%04X".format(op))
        if (dataOut != null) {
            // 数据外发：Data 容器（12B 头 + 载荷）。载荷极小（≤5B），不会触及 ZLP 边界
            val d = ByteArray(HEADER_BYTES + dataOut.size)
            PtpWire.putU32(d, 0, d.size.toLong())
            PtpWire.putU16(d, 4, CT_DATA)
            PtpWire.putU16(d, 6, op)
            PtpWire.putU32(d, 8, txn)
            dataOut.copyInto(d, HEADER_BYTES)
            sendContainer(c, eout, d, "数据 0x%04X".format(op))
        }

        var data: ByteArray = ByteArray(0)
        while (true) {
            val h = readHeader(c, ein)
            when (h.type) {
                CT_RESPONSE -> {
                    val payload = readPayload(c, ein, h.payloadLen)
                    if (h.code != Ptp.RESP_OK) throw PtpException(h.code, "操作 0x%04X".format(op))
                    return PtpSession.TransactResult(h.code, parseParams(payload), if (data.isNotEmpty()) data else payload)
                }
                CT_DATA -> data = readPayload(c, ein, h.payloadLen)
                CT_EVENT -> skip(c, ein, h.payloadLen) // 事件可能插在响应之前，丢掉继续等
                else -> throw IOException("USB 收到未知容器类型 ${h.type}")
            }
        }
    }

    private fun parseParams(payload: ByteArray): LongArray {
        val n = payload.size / 4
        val r = LongArray(n)
        for (i in 0 until n) r[i] = PtpWire.getU32(payload, i * 4)
        return r
    }

    /** 发送容器；失败清 OUT 端点 STALL 后重试一次（USB 设备会 STALL 不接受的包）。 */
    private fun sendContainer(c: UsbDeviceConnection, eout: UsbEndpoint, buf: ByteArray, what: String) {
        var sent = runCatching { c.bulkTransfer(eout, buf, buf.size, BULK_TIMEOUT_MS) }.getOrDefault(-1)
        if (sent != buf.size) {
            clearHalt(c, eout)
            Thread.sleep(200)
            sent = runCatching { c.bulkTransfer(eout, buf, buf.size, BULK_TIMEOUT_MS) }.getOrDefault(-1)
        }
        if (sent != buf.size) {
            throw IOException("$what 发送不完整（$sent/${buf.size}）")
        }
    }

    private fun clearHalt(c: UsbDeviceConnection, ep: UsbEndpoint) {
        runCatching {
            c.controlTransfer(0x02, 0x01, 0x0000, ep.address, null, 0, 1_000)
        }
    }

    /**
     * IN 端点整包读 + 余料。三条铁律见类注释：
     * 缓冲 ≥ maxPacket、不清 IN 端点 STALL、无数据时 200ms 间隔重读。
     */
    private fun readFully(c: UsbDeviceConnection, ein: UsbEndpoint, buf: ByteArray, want: Int) {
        var off = 0
        if (inLeftover.isNotEmpty()) {
            val take = minOf(inLeftover.size, want)
            System.arraycopy(inLeftover, 0, buf, 0, take)
            inLeftover = if (take == inLeftover.size) ByteArray(0) else inLeftover.copyOfRange(take, inLeftover.size)
            off = take
        }
        val maxPkt = maxOf(ein.maxPacketSize, HEADER_BYTES)
        var attempt = 0
        while (off < want) {
            // URB 尺寸取整到 maxPacket 整数倍，避免尾部装不下整包 EOVERFLOW
            val raw = minOf(want - off, STREAM_CHUNK)
            val size = if (raw >= maxPkt) raw / maxPkt * maxPkt else maxPkt
            val tmp = ByteArray(size)
            val n = runCatching { c.bulkTransfer(ein, tmp, 0, size, BULK_TIMEOUT_MS) }.getOrDefault(-1)
            if (n > 0) {
                val take = minOf(n, want - off)
                System.arraycopy(tmp, 0, buf, off, take)
                off += take
                if (n > take) inLeftover = tmp.copyOfRange(take, n)
                attempt = 0
                continue
            }
            if (closing) throw IOException("连接已关闭")
            attempt++
            if (attempt > EMPTY_RETRY_MAX) {
                throw IOException("USB 读取失败（已收 $off/$want，等待约 3s 仍无数据）")
            }
            Thread.sleep(EMPTY_RETRY_MS)
        }
    }

    private fun readHeaderOnce(c: UsbDeviceConnection, ein: UsbEndpoint): UsbHeader {
        val h = ByteArray(HEADER_BYTES)
        readFully(c, ein, h, HEADER_BYTES)
        val len = PtpWire.getU32(h, 0)
        val type = PtpWire.getU16(h, 4)
        val code = PtpWire.getU16(h, 6)
        val txn = PtpWire.getU32(h, 8)
        if (len < HEADER_BYTES) throw IOException("USB 容器长度非法：$len")
        return UsbHeader(type, code, txn, len - HEADER_BYTES)
    }

    private fun readHeader(c: UsbDeviceConnection, ein: UsbEndpoint): UsbHeader {
        var last: IOException? = null
        for (attempt in 1..3) {
            try {
                return readHeaderOnce(c, ein)
            } catch (e: IOException) {
                last = e
                if (attempt < 3 && !closing) Thread.sleep(250)
            }
        }
        throw last ?: IOException("USB 读取失败")
    }

    private fun readPayload(c: UsbDeviceConnection, ein: UsbEndpoint, len: Long): ByteArray {
        if (len <= 0) return ByteArray(0)
        if (len > MAX_PAYLOAD) {
            throw IOException("载荷 ${len}B 超过单次分配上限 ${MAX_PAYLOAD / 1048576}MB（大文件应走流式下载）")
        }
        val b = ByteArray(len.toInt())
        readFully(c, ein, b, len.toInt())
        return b
    }

    private fun skip(c: UsbDeviceConnection, ein: UsbEndpoint, n: Long) {
        val buf = ByteArray(STREAM_CHUNK)
        var left = n
        while (left > 0) {
            val want = minOf(buf.size.toLong(), left).toInt()
            readFully(c, ein, buf, want)
            left -= want
        }
    }

    private class UsbHeader(val type: Int, val code: Int, val txn: Long, val payloadLen: Long)

    // ---------------------------------------------------------------- 下载

    override fun getObjectToStream(
        handle: Long,
        size: Long,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): Long {
        requireValidSize(size)
        cancelRequested = false // 上一次的取消不能影响这一次
        synchronized(txnLock) {
            var written = 0L
            try {
                written = downloadOnce(handle, size, out, onProgress)
            } catch (e: CancelledException) {
                // 取消发生在数据相位中途：流里还留着相机没发完的字节，无法安全复用——
                // 下一笔事务会把残留的 DATA 容器当成自己的数据读（甚至尝试按 GB 分配）。
                // 因此把连接标为待重建，由下一次事务走 reopenAfterEnumeration 自愈。
                needsReopen = true
                log("下载已取消：连接作废，下次操作时自动重建")
                throw e
            } catch (e: PtpException) {
                throw e // 相机明确拒绝（句柄无效等），重传无意义
            } catch (e: IOException) {
                if (closing) throw e
                // 断点续传：恢复连接后从断点用 GetPartialObject 拉剩余部分，
                // 已落流的字节不浪费（空闲期重枚举随时可能打断大文件传输）
                log("USB 下载中断（已收 $written/$size）：${e.message}；恢复连接后续传剩余部分")
                if (!reopenAfterEnumeration()) {
                    notifyDead("USB 恢复失败：${e.message}")
                    throw e
                }
                out.flush()
                written += resumeWithPartial(handle, written, size, out, onProgress)
            }
            if (written != size) throw IOException("传输不完整：期望 $size 字节，实际收到 $written 字节")
            return written
        }
    }

    @Volatile private var cancelRequested = false

    /** 取消下载后连接已不可用，下一笔事务必须先重建（见 [reopenAfterEnumeration]）。 */
    @Volatile private var needsReopen = false

    override fun requestCancelDownload() {
        cancelRequested = true
        log("收到取消下载请求，将在当前读块结束时中止")
    }

    /**
     * 断点续传：GetPartialObject(0x101B) 从 offset 分块拉到 size。
     * 续传阶段每笔事务的响应参数[0]声明了实际长度，与写入量不符即失败
     * （阶段 0 的教训：绝不按声明值推进偏移）。
     * 注意 0x101B 的偏移是 u32，仅支持 4GB 内文件；整文件流式是主路径，
     * 续传只发生在被重枚举打断时，此时已传部分 < 4GB 恒成立。
     */
    private fun resumeWithPartial(
        handle: Long,
        offset: Long,
        size: Long,
        out: OutputStream,
        onProgress: (Long, Long) -> Unit,
    ): Long {
        val chunk = 4L shl 20 // 与 Wi-Fi 侧 PARTIAL_CHUNK_BYTES 同尺寸
        var pos = offset
        while (pos < size) {
            if (cancelRequested) throw CancelledException("已收到取消请求（续传至 ${pos / 1048576}MB）")
            val want = minOf(chunk, size - pos)
            val res = transactInner(Ptp.OP_GET_PARTIAL_OBJECT, longArrayOf(handle, pos, want))
            if (res.data.isEmpty()) throw IOException("续传第 $pos 字节处相机未返回数据")
            if (res.params.isNotEmpty() && res.params[0] != res.data.size.toLong()) {
                throw IOException("续传分块长度不一致：相机声明 ${res.params[0]} 字节，实际 ${res.data.size}（offset=$pos）")
            }
            out.write(res.data)
            pos += res.data.size
            onProgress(pos, size)
        }
        out.flush()
        return pos - offset
    }

    /** 一轮 GetObject 整文件流式下载。 */
    private fun downloadOnce(
        handle: Long,
        size: Long,
        out: OutputStream,
        onProgress: (Long, Long) -> Unit,
    ): Long {
        val c = conn ?: throw IOException("USB 连接未建立")
        val ein = epIn ?: throw IOException("USB 连接未建立")
        val eout = epOut ?: throw IOException("USB 连接未建立")
        val txn = nextTxn()
        val cmd = ByteArray(HEADER_BYTES + 4)
        PtpWire.putU32(cmd, 0, cmd.size.toLong())
        PtpWire.putU16(cmd, 4, CT_COMMAND)
        PtpWire.putU16(cmd, 6, Ptp.OP_GET_OBJECT)
        PtpWire.putU32(cmd, 8, txn)
        PtpWire.putU32(cmd, HEADER_BYTES, handle)
        sendContainer(c, eout, cmd, "GetObject")

        var total = 0L
        var nextProgress = 0L
        val buf = ByteArray(STREAM_CHUNK)
        while (true) {
            val h = readHeader(c, ein)
            if (h.type == CT_RESPONSE) {
                if (h.code != Ptp.RESP_OK) throw PtpException(h.code, "GetObject")
                break
            }
            if (h.type != CT_DATA) throw IOException("USB 收到未知容器类型 ${h.type}")
            var left = h.payloadLen
            while (left > 0) {
                // 取消检查放在读块边界：一个读块（最多 STREAM_CHUNK）在 USB 下远小于 1 秒，
                // 用户点取消不会等整个文件传完（曾出现"取消 4GB 视频要等 150 秒"）
                if (cancelRequested) throw CancelledException("已收到取消请求（已收 ${total / 1048576}MB）")
                val want = minOf(buf.size.toLong(), left).toInt()
                readFully(c, ein, buf, want)
                out.write(buf, 0, want)
                total += want
                left -= want
                if (total >= nextProgress) {
                    onProgress(total, size)
                    nextProgress = total + (1L shl 20)
                }
            }
        }
        out.flush()
        return total
    }

    // ---------------------------------------------------------------- 恢复

    /**
     * 重枚举恢复：设备从总线消失时轮询等待重现（离线窗实测 ~3.4s），
     * 重现后重新授权（权限按设备实例失效）、重新 claim。
     */
    private fun reopenAfterEnumeration(): Boolean {
        val ctx = appCtx()
        val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        val vid = device?.vendorId
        val pid = device?.productId
        closeQuietly()
        var dev: UsbDevice? = null
        val deadline = System.currentTimeMillis() + REAPPEAR_WAIT_MS
        while (System.currentTimeMillis() < deadline && !closing) {
            dev = mgr.deviceList.values.firstOrNull {
                (vid == null || it.vendorId == vid) && (pid == null || it.productId == pid)
            }
            if (dev != null) break
            if (deadline - System.currentTimeMillis() > REAPPEAR_WAIT_MS - 600) {
                log("USB 设备不在总线上，等待其重新出现（最多 ${REAPPEAR_WAIT_MS / 1000}s）…")
            }
            Thread.sleep(500)
        }
        if (dev == null || closing) {
            log("USB 重枚举恢复失败：等待期内未见到设备")
            return false
        }
        if (!mgr.hasPermission(dev) && !ensurePermission(ctx, mgr, dev)) {
            log("USB 重枚举恢复失败：未获授权")
            return false
        }
        val ptp = pickStillImageInterface(dev) ?: return false
        val c = mgr.openDevice(dev) ?: return false
        if (!c.claimInterface(ptp, true)) {
            runCatching { c.close() }
            return false
        }
        val ein = findBulk(ptp, UsbConstants.USB_DIR_IN)
        val eout = findBulk(ptp, UsbConstants.USB_DIR_OUT)
        if (ein == null || eout == null) {
            runCatching { c.releaseInterface(ptp) }
            runCatching { c.close() }
            return false
        }
        device = dev
        conn = c
        iface = ptp
        epIn = ein
        epOut = eout
        epInt = findInterrupt(ptp)
        inLeftover = ByteArray(0)
        evtLeftover = ByteArray(0)
        // 连接已干净重建，取消留下的作废标记随之解除
        needsReopen = false
        log("USB 设备已重枚举并重新打开成功（${dev.deviceName}）")
        return true
    }

    override fun notifyLinkDead(reason: String) {
        // 供保活探针调用；内部有去重，重复调用安全
        notifyDead(reason)
    }

    private fun notifyDead(reason: String) {
        if (deadNotified || closing) return
        deadNotified = true
        closeQuietly()
        log("USB 连接死亡：$reason")
        disconnectHandler?.invoke(reason)
    }

    // ---------------------------------------------------------------- 事件

    /** 事件线程：轮询中断端点（0x83），解析事件容器后转给 eventHandler。 */
    private fun startEventThread() {
        val t = Thread({
            val buf = ByteArray(64)
            while (!closing && Thread.currentThread() === eventThread) {
                val c = conn ?: break
                val e = epInt ?: break
                try {
                    val evt = readEvent(c, e, buf) ?: continue
                    val code = PtpWire.getU16(evt, 4)
                    val paramCount = (evt.size - 8) / 4
                    val params = LongArray(paramCount) { PtpWire.getU32(evt, 8 + it * 4) }
                    eventHandler?.invoke(code, params)
                } catch (_: InterruptedException) {
                    break
                } catch (_: Exception) {
                    // fd 死亡或偶发竞态：下次循环重试；连接真正断开由事务路径判死
                    if (closing) break
                    Thread.sleep(500)
                }
            }
        }, "usb-evt")
        eventThread = t
        t.isDaemon = true
        t.start()
    }

    /** 从中断端点读一个完整事件容器；无事件返回 null。 */
    private fun readEvent(c: UsbDeviceConnection, e: UsbEndpoint, buf: ByteArray): ByteArray? {
        var data = evtLeftover
        evtLeftover = ByteArray(0)
        if (data.size < 4) {
            data = ByteArray(0)
            val n = runCatching { c.bulkTransfer(e, buf, 0, buf.size, 300) }.getOrDefault(-1)
            if (n <= 0) return null
            data = buf.copyOf(n)
        }
        val len = PtpWire.getU32(data, 0).toInt()
        if (len < 10 || len > 64) return null // 非法头：丢弃这批字节，防止流持续错位
        while (data.size < len) {
            val n = runCatching { c.bulkTransfer(e, buf, 0, buf.size, 300) }.getOrDefault(-1)
            if (n <= 0) {
                evtLeftover = data // 不完整事件缓存待续
                return null
            }
            data += buf.copyOf(n)
        }
        if (data.size > len) evtLeftover = data.copyOfRange(len, data.size)
        return data.copyOf(len)
    }
}
