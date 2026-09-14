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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * USB 连接模式的 **U0 阶段实验**（见 `docs/USB连接方案.md`）。
 *
 * 只做一件事：把"能不能走 USB、能跑多快"这两个问题一次问清楚。
 * 它不是完整的传输层——枚举/下载/遥控等上层逻辑仍走 Wi-Fi 的 `PtpIpClient`。
 *
 * U0 要回答的问题（全部打进日志，便于一次性拿回结论）：
 * 1. 相机是否以 PTP 接口（class 6 / subclass 1 / protocol 1）暴露；只给 MTP 则本方案不成立
 * 2. 标准 OpenSession 是否能直接通过（USB 下**不需要**伪装 WMU GUID）
 * 3. USB 模式下的操作集有多大（Wi-Fi 智能设备模式实测 126 个，对比看是否被裁剪）
 * 4. **实际吞吐 MB/s**——这是整个方案的意义所在，达不到 10MB/s 就不值得继续投入
 *
 * PTP/USB 与 PTP/IP 的差别只在承载：容器头为 12 字节
 * `长度 u32 + 类型 u16 + 码 u16 + 事务号 u32`（小端），
 * 类型 1=命令 2=数据 3=响应。操作码与数据集解析完全复用 `Ptp.kt` / `PtpDatasets.kt`。
 */
internal object PtpUsbProbe {

    private const val ACTION_USB_PERMISSION = "com.nikan.nikonsync.USB_PERMISSION"

    // PTP 容器类型
    private const val CT_COMMAND = 1
    private const val CT_DATA = 2
    private const val CT_RESPONSE = 3

    private const val HEADER_BYTES = 12
    private const val BULK_TIMEOUT_MS = 5_000
    private const val STREAM_CHUNK = 1 shl 20 // 1MiB

    /** 单次容器载荷上限：防止对端长度字段异常导致巨量分配（与 PtpWire 同一考虑） */
    private const val MAX_PAYLOAD = 64 shl 20

    // PTP 操作码一律复用 Ptp.kt 的常量（U0 只用到这几个）。
    // 响应码同样复用，避免两份定义漂移。

    private class UsbHeader(val type: Int, val code: Int, val txn: Long, val payloadLen: Int)

    /** 找到的第一个 PTP 设备（一次实验内复用） */
    private var device: UsbDevice? = null
    private var conn: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private var txnId = 0L

    /**
     * U0 入口：跑完"探测 → 会话 → 操作集 → 测速"全流程，返回可读结论。
     * 需要用户在弹出的系统对话框里点一次"允许"。
     */
    fun run(ctx: Context, log: (String) -> Unit): List<String> {
        val out = ArrayList<String>()
        try {
            openDevice(ctx, log, out) ?: return out
            val conn = conn ?: return out
            val epIn = epIn ?: return out
            val epOut = epOut ?: return out

            // ---- 1) OpenSession（USB 下无需握手、无需伪装 GUID）----
            val open = command(conn, epIn, epOut, Ptp.OP_OPEN_SESSION, longArrayOf(1), log)
            out += "OpenSession → ${Ptp.respName(open.first)}"
            log("USB OpenSession → ${Ptp.respName(open.first)}")
            // 会话已存在（重连场景）继续跑
            if (open.first != Ptp.RESP_OK && open.first != Ptp.RESP_SESSION_ALREADY_OPEN) {
                out += "会话打开失败，后续步骤跳过"
                return out
            }

            // ---- 2) GetDeviceInfo：顺带对比操作集大小 ----
            val (code, payload) = command(conn, epIn, epOut, Ptp.OP_GET_DEVICE_INFO, LongArray(0), log)
            if (code != Ptp.RESP_OK) {
                out += "GetDeviceInfo 失败：${Ptp.respName(code)}"
                return out
            }
            val di = runCatching { PtpDatasets.parseDeviceInfo(payload) }.getOrNull()
            if (di == null) {
                out += "DeviceInfo 解析失败（${payload.size}B）"
                return out
            }
            out += "机型：${di.manufacturer} ${di.model} v${di.deviceVersion}"
            out += "操作集：${di.operationsSupported.size} 个（Wi-Fi 智能设备模式实测 126 个）"
            out += "事件集：${di.eventsSupported.size} 个"
            // 关键对照：Wi-Fi 下被拒的实时取景等能力，USB 下是否放行
            val lvOps = di.operationsSupported.filter { it in 0x9200..0x92FF }
            out += "0x92xx 段操作：" + if (lvOps.isEmpty()) "无" else
                lvOps.joinToString(" ") { "0x%04X".format(it) }
            log("USB 设备信息：${di.model} 操作 ${di.operationsSupported.size} 个")

            // ---- 3) 找最大的对象并计时下载（吞吐是 U0 的唯一关键指标）----
            val biggest = findBiggestObject(conn, epIn, epOut, di, log)
            if (biggest == null) {
                out += "未找到可测速的对象（存储卡为空？）"
                return out
            }
            val (handle, size) = biggest
            out += "测速对象：handle=0x${handle.toString(16)} ${size / 1048576.0}MB"
            val mbps = timedDownload(conn, epIn, epOut, handle, size, log)
            out += if (mbps > 0) {
                "实测吞吐：%.1f MB/s".format(mbps)
            } else {
                "测速失败（详见日志）"
            }
        } catch (e: Exception) {
            out += "USB 实验异常：${e.message}"
            log("USB 实验异常：$e")
        } finally {
            closeQuietly(log)
        }
        out.forEach { log("USB $it") }
        return out
    }

    // ------------------------------------------------------------ 设备与权限

    private fun openDevice(ctx: Context, log: (String) -> Unit, out: MutableList<String>): Unit? {
        val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager
        if (mgr == null) {
            out += "无法获取 UsbManager"
            return null
        }
        val devs = mgr.deviceList.values.toList()
        out += "USB 设备数：${devs.size}"
        devs.forEach { d ->
            out += "· ${d.deviceName} vid=0x%04X pid=0x%04X 接口=${d.interfaceCount}".format(
                d.vendorId, d.productId,
            )
        }
        // 优先找 PTP 接口的设备；找不到就报明原因——这决定方案是否成立
        val target = devs.firstOrNull { findPtpInterface(it) != null }
        if (target == null) {
            out += "未发现 PTP 接口设备。请确认：①相机 USB 模式已设为 PTP（不是 MTP）" +
                " ②相机已退出「连接至智能设备」 ③USB 线支持数据传输（不是纯充电线）"
            return null
        }
        device = target
        val ptp = findPtpInterface(target) ?: return null
        out += "找到 PTP 接口：${target.deviceName} 接口${ptp.id}"

        if (!ensurePermission(ctx, mgr, target, log, out)) return null
        val c = mgr.openDevice(target)
        if (c == null) {
            out += "openDevice 返回 null"
            return null
        }
        // force=true：系统自带的 MTP 服务可能已占用该接口
        if (!c.claimInterface(ptp, true)) {
            out += "claimInterface 失败（接口被系统 MTP 服务占用？）"
            runCatching { c.close() }
            return null
        }
        val ein = findBulk(ptp, UsbConstants.USB_DIR_IN)
        val eout = findBulk(ptp, UsbConstants.USB_DIR_OUT)
        if (ein == null || eout == null) {
            out += "未找到 Bulk 端点（in=${ein != null} out=${eout != null}）"
            runCatching { c.releaseInterface(ptp) }
            runCatching { c.close() }
            return null
        }
        conn = c
        iface = ptp
        epIn = ein
        epOut = eout
        out += "接口已占用，Bulk 端点就绪（in 0x%02X / out 0x%02X）".format(
            ein.address, eout.address,
        )
        return Unit
    }

    private fun findPtpInterface(d: UsbDevice): UsbInterface? {
        for (i in 0 until d.interfaceCount) {
            val it = d.getInterface(i)
            // PTP 静态接口：class 6 (Still Image) / subclass 1 / protocol 1
            if (it.interfaceClass == 6 && it.interfaceSubclass == 1 && it.interfaceProtocol == 1) {
                return it
            }
        }
        return null
    }

    private fun findBulk(it: UsbInterface, dir: Int): UsbEndpoint? {
        for (i in 0 until it.endpointCount) {
            val ep = it.getEndpoint(i)
            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == dir) return ep
        }
        return null
    }

    /**
     * 申请 USB 权限。系统会弹一次对话框，这里等用户点完（最长 60 秒）。
     * Android 13+ 注册接收器必须显式声明是否导出，否则会抛异常。
     */
    private fun ensurePermission(
        ctx: Context,
        mgr: UsbManager,
        dev: UsbDevice,
        log: (String) -> Unit,
        out: MutableList<String>,
    ): Boolean {
        if (mgr.hasPermission(dev)) return true
        val latch = CountDownLatch(1)
        var granted = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                if (intent?.action == ACTION_USB_PERMISSION) {
                    granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    latch.countDown()
                }
            }
        }
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, filter)
        }
        try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val pi = PendingIntent.getBroadcast(
                ctx, 0, Intent(ACTION_USB_PERMISSION).setPackage(ctx.packageName), flags,
            )
            out += "请求 USB 权限，请在系统弹窗中点「允许」…"
            mgr.requestPermission(dev, pi)
            if (!latch.await(60, TimeUnit.SECONDS)) {
                out += "等待授权超时（未点允许？）"
                return false
            }
        } catch (e: Exception) {
            out += "请求权限异常：${e.message}"
            log("USB 请求权限异常：$e")
            return false
        } finally {
            runCatching { ctx.unregisterReceiver(receiver) }
        }
        if (!granted) {
            out += "用户拒绝了 USB 权限"
            return false
        }
        log("USB 权限已授予")
        return true
    }

    private fun closeQuietly(log: (String) -> Unit) {
        runCatching {
            val c = conn
            val it = iface
            if (c != null && it != null) runCatching { c.releaseInterface(it) }
            c?.close()
        }
        conn = null
        iface = null
        epIn = null
        epOut = null
        device = null
        log("USB 资源已释放")
    }

    // ------------------------------------------------------------ 事务

    private fun nextTxn(): Long = (++txnId) and 0x7FFFFFFFL

    /**
     * 只发命令 + 收响应（数据阶段必须为空）。
     * 返回 (响应码, 响应载荷)，载荷为去掉 12 字节容器头之后的参数区。
     */
    private fun command(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        eout: UsbEndpoint,
        op: Int,
        params: LongArray,
        log: (String) -> Unit,
    ): Pair<Int, ByteArray> {
        val txn = nextTxn()
        val buf = ByteArray(HEADER_BYTES + params.size * 4)
        PtpWire.putU32(buf, 0, buf.size.toLong())
        PtpWire.putU16(buf, 4, CT_COMMAND)
        PtpWire.putU16(buf, 6, op)
        PtpWire.putU32(buf, 8, txn)
        params.forEachIndexed { i, v -> PtpWire.putU32(buf, HEADER_BYTES + i * 4, v) }
        val sent = c.bulkTransfer(eout, buf, buf.size, BULK_TIMEOUT_MS)
        if (sent != buf.size) throw IOException("命令发送不完整（$sent/${buf.size}）")

        while (true) {
            val h = readHeader(c, ein)
            when (h.type) {
                CT_RESPONSE -> {
                    val payload = readPayload(c, ein, h.payloadLen)
                    return h.code to payload
                }
                // 该操作不应有数据阶段；真有就丢掉，避免把流留在半路
                CT_DATA -> {
                    log("USB 意外数据阶段（${h.payloadLen}B），已跳过")
                    skip(c, ein, h.payloadLen.toLong())
                }
                else -> throw IOException("USB 收到未知容器类型 ${h.type}")
            }
        }
    }

    private fun readHeader(c: UsbDeviceConnection, ein: UsbEndpoint): UsbHeader {
        val h = ByteArray(HEADER_BYTES)
        readFully(c, ein, h, HEADER_BYTES)
        val len = PtpWire.getU32(h, 0)
        val type = PtpWire.getU16(h, 4)
        val code = PtpWire.getU16(h, 6)
        val txn = PtpWire.getU32(h, 8)
        if (len < HEADER_BYTES || len > MAX_PAYLOAD) {
            throw IOException("USB 容器长度非法：$len")
        }
        return UsbHeader(type, code, txn, (len - HEADER_BYTES).toInt())
    }

    private fun readPayload(c: UsbDeviceConnection, ein: UsbEndpoint, len: Int): ByteArray {
        if (len <= 0) return ByteArray(0)
        val b = ByteArray(len)
        readFully(c, ein, b, len)
        return b
    }

    /** Bulk 读可能少于请求长度，必须循环补齐 */
    private fun readFully(c: UsbDeviceConnection, ein: UsbEndpoint, buf: ByteArray, want: Int) {
        var off = 0
        while (off < want) {
            val n = c.bulkTransfer(ein, buf, off, want - off, BULK_TIMEOUT_MS)
            if (n <= 0) throw IOException("USB 读取失败（已收 $off/$want，超时或断开）")
            off += n
        }
    }

    /** 丢弃 n 字节（分块，避免为不需要的数据分配大内存） */
    private fun skip(c: UsbDeviceConnection, ein: UsbEndpoint, n: Long) {
        val buf = ByteArray(STREAM_CHUNK)
        var left = n
        while (left > 0) {
            val want = minOf(buf.size.toLong(), left).toInt()
            readFully(c, ein, buf, want)
            left -= want
        }
    }

    // ------------------------------------------------------------ 测速

    /** 从枚举结果里挑最大的 JPEG/NEF 用于测速 */
    private fun findBiggestObject(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        eout: UsbEndpoint,
        di: DeviceInfo,
        log: (String) -> Unit,
    ): Pair<Long, Long>? {
        val storageIds = runCatching {
            val (code, p) = command(c, ein, eout, Ptp.OP_GET_STORAGE_IDS, LongArray(0), log)
            if (code != Ptp.RESP_OK) return@runCatching LongArray(0)
            val r = ByteReader(p)
            val n = r.u32().toInt()
            LongArray(n) { r.u32() }
        }.getOrDefault(LongArray(0))
        if (storageIds.isEmpty()) return null

        var best: Pair<Long, Long>? = null
        for (sid in storageIds) {
            // GetObjectHandles(storage, formatCode=0(全部), parent=0xFFFFFFFF)
            val handles = runCatching {
                val (code, p) = command(c, ein, eout, Ptp.OP_GET_OBJECT_HANDLES, longArrayOf(sid, 0, 0xFFFFFFFFL), log)
                if (code != Ptp.RESP_OK) return@runCatching LongArray(0)
                val r = ByteReader(p)
                val n = r.u32().toInt()
                if (n < 0 || n > 100_000) return@runCatching LongArray(0)
                LongArray(n) { r.u32() }
            }.getOrDefault(LongArray(0))
            log("USB 存储 $sid：${handles.size} 个对象")
            // 只抽查前若干个，取最大的——U0 不需要枚举完整
            for (h in handles.take(40)) {
                val info = runCatching {
                    val (code, p) = command(c, ein, eout, Ptp.OP_GET_OBJECT_INFO, longArrayOf(h), log)
                    if (code != Ptp.RESP_OK) return@runCatching null
                    PtpDatasets.parseObjectInfo(p)
                }.getOrNull() ?: continue
                val size = info.compressedSize
                if (size > (best?.second ?: 0L)) best = h to size
            }
        }
        return best
    }

    /** 计时完整拉取一个对象，返回 MB/s（只统计字节数，不落内存） */
    private fun timedDownload(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        eout: UsbEndpoint,
        handle: Long,
        declaredSize: Long,
        log: (String) -> Unit,
    ): Double {
        val txn = nextTxn()
        val cmd = ByteArray(HEADER_BYTES + 4)
        PtpWire.putU32(cmd, 0, cmd.size.toLong())
        PtpWire.putU16(cmd, 4, CT_COMMAND)
        PtpWire.putU16(cmd, 6, Ptp.OP_GET_OBJECT)
        PtpWire.putU32(cmd, 8, txn)
        PtpWire.putU32(cmd, HEADER_BYTES, handle)
        if (c.bulkTransfer(eout, cmd, cmd.size, BULK_TIMEOUT_MS) != cmd.size) {
            throw IOException("GetObject 命令发送不完整")
        }

        var total = 0L
        var firstBytes: ByteArray? = null
        val buf = ByteArray(STREAM_CHUNK)
        val t0 = System.currentTimeMillis()
        while (true) {
            val h = readHeader(c, ein)
            if (h.type == CT_RESPONSE) {
                if (h.code != Ptp.RESP_OK) {
                    log("USB GetObject 响应：${Ptp.respName(h.code)}")
                    return 0.0
                }
                break
            }
            if (h.type != CT_DATA) throw IOException("USB 非预期容器类型 ${h.type}")
            var left = h.payloadLen.toLong()
            while (left > 0) {
                val want = minOf(buf.size.toLong(), left).toInt()
                readFully(c, ein, buf, want)
                if (firstBytes == null) firstBytes = buf.copyOf(minOf(16, want))
                total += want
                left -= want
            }
        }
        val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1)
        val mbps = (total / 1048576.0) / (ms / 1000.0)
        // 校验确实是 JPEG（SOI 0xFFD8），防止"测得很快但数据是错的"
        val soi = firstBytes != null && firstBytes.size >= 2 &&
            firstBytes[0] == 0xFF.toByte() && firstBytes[1] == 0xD8.toByte()
        log(
            "USB 测速：$total 字节 / ${ms}ms = %.1f MB/s，头两字节%s JPEG".format(
                mbps, if (soi) "是" else "不是",
            ),
        )
        if (!soi) log("⚠️ 数据不像 JPEG，测速结果不可信")
        if (declaredSize > 0 && total != declaredSize) {
            log("⚠️ 实际字节 $total 与 ObjectInfo 声明 $declaredSize 不一致")
        }
        return if (soi) mbps else 0.0
    }
}
