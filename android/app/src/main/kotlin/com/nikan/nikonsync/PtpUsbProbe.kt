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
    private const val CT_EVENT = 4

    private const val HEADER_BYTES = 12
    private const val BULK_TIMEOUT_MS = 5_000
    private const val STREAM_CHUNK = 1 shl 20 // 1MiB

    /** 单次分配上限：readPayload 会 new 等长数组，异常长度字段在这里把守；
     *  容器头校验不做此限制（大文件的数据容器本来就超），流式下载不经过 readPayload。 */
    private const val MAX_PAYLOAD = 64 shl 20

    // PTP 操作码一律复用 Ptp.kt 的常量（U0 只用到这几个）。
    // 响应码同样复用，避免两份定义漂移。

    private class UsbHeader(val type: Int, val code: Int, val txn: Long, val payloadLen: Long)

    /** 找到的第一个 PTP 设备（一次实验内复用） */
    private var device: UsbDevice? = null
    private var conn: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private var txnId = 0L

    /**
     * 上一次整包读"多读出"的字节（跨容器边界部分）。
     * USB 是包式协议，一次 bulkTransfer 收到的是整个 USB 包，可能包含
     * 下一笔容器的开头；这些字节不能丢，必须按序供给后续读取。
     * drainInput（清端点残留）时一并清空，否则新事务会从陈余料开始解析。
     */
    private var inLeftover: ByteArray = ByteArray(0)

    /** 本次运行的日志出口（run() 开头设置）。供深层读写函数使用，避免层层透传。 */
    private var probeLog: (String) -> Unit = {}

    /** 运行期持有的 Context（重枚举恢复时需要重新枚举设备） */
    private var ctxRef: Context? = null

    /**
     * 设备重新枚举后的恢复。
     *
     * 实测：相机在探测过程中会从 `/dev/bus/usb/001/003` 换到 `004`
     * （`dumpsys usb` 的 host_manager 里能看到 mode=0 → mode=-1 → mode=0 的换址）。
     * **设备地址一变，手里的 UsbDeviceConnection 即失效**，此后所有 bulkTransfer
     * 返回 -1，且清除端点 STALL 无效——因为根本不是端点的问题。
     * 唯一出路是按 VID/PID 重新找到设备、重新 claim。
     */
    private fun reopenAfterEnumeration(log: (String) -> Unit): Boolean {
        val ctx = ctxRef ?: return false
        val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return false
        val vid = device?.vendorId
        val pid = device?.productId
        closeQuietly(log)
        // 相机断开到重新挂上有约 3.4 秒的离线窗（§7.2），设备不在总线时轮询等待，
        // 而不是立刻放弃——离线窗里放弃等于每次断开都终结整轮探测
        var dev: UsbDevice? = null
        for (i in 1..20) { // 20 × 500ms = 10s
            dev = mgr.deviceList.values.firstOrNull {
                (vid == null || it.vendorId == vid) && (pid == null || it.productId == pid)
            }
            if (dev != null) break
            if (i == 1) log("USB 设备不在总线上，等待其重新出现（最多 10s）…")
            Thread.sleep(500)
        }
        if (dev == null) {
            log("USB 重枚举恢复失败：等了 10s 仍未见到设备（可能已拔出）")
            return false
        }
        val ptp = pickStillImageInterface(dev)
        if (ptp == null) {
            log("USB 重枚举恢复失败：新设备没有 Still Image 接口")
            return false
        }
        if (!mgr.hasPermission(dev)) {
            // 重枚举后权限按设备实例失效——主动请求（用户在弹窗点允许即可继续）
            log("USB 新设备实例需要授权，请在系统弹窗中点「允许」…")
            if (!ensurePermission(ctx, mgr, dev, log, mutableListOf())) {
                log("USB 重枚举恢复失败：未获授权")
                return false
            }
        }
        val c = mgr.openDevice(dev) ?: return false
        if (!c.claimInterface(ptp, true)) {
            runCatching { c.close() }
            log("USB 重枚举恢复失败：claimInterface 被拒")
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
        log("USB 设备已重枚举并重新打开成功（${dev.deviceName}）")
        return true
    }

    /** 执行命令；传输失败时尝试"重枚举恢复"再重试一次。 */
    private fun commandRecovering(
        op: Int,
        params: LongArray,
        what: String,
        out: MutableList<String>,
    ): Pair<Int, ByteArray> {
        val first = runCatching { command(conn!!, epIn!!, epOut!!, op, params, probeLog) }
        if (first.isSuccess) return first.getOrThrow()
        val err = first.exceptionOrNull()
        val why = err?.message ?: err?.javaClass?.simpleName ?: "未知错误"
        out += "$what 传输失败：$why"
        probeLog("USB $what 传输失败：$why，尝试重枚举恢复")
        if (!reopenAfterEnumeration(probeLog)) {
            throw (err as? IOException ?: IOException("USB $what 失败"))
        }
        return command(conn!!, epIn!!, epOut!!, op, params, probeLog)
    }

    /**
     * U0 入口：跑完"探测 → 会话 → 操作集 → 测速"全流程，返回可读结论。
     * 需要用户在弹出的系统对话框里点一次"允许"。
     */
    fun run(ctx: Context, log: (String) -> Unit): List<String> {
        val out = ArrayList<String>()
        probeLog = log
        ctxRef = ctx
        try {
            openDevice(ctx, log, out) ?: return out
            val conn = conn ?: return out
            val epIn = epIn ?: return out
            val epOut = epOut ?: return out

            // ---- 1) OpenSession（USB 下无需握手、无需伪装 GUID）----
            if (!openSession(conn, epIn, epOut, log, out)) return out

            // ---- 2) GetDeviceInfo：顺带对比操作集大小 ----
            var info = commandRecovering(Ptp.OP_GET_DEVICE_INFO, LongArray(0), "GetDeviceInfo", out)
            if (info.first != Ptp.RESP_OK) {
                out += "GetDeviceInfo → ${Ptp.respName(info.first)}"
                // 沿用会话失败时的降级路径：关闭残留会话重开，再试一次
                if (resetSession(conn, epIn, epOut, log, out)) {
                    info = commandRecovering(Ptp.OP_GET_DEVICE_INFO, LongArray(0), "GetDeviceInfo", out)
                }
            }
            val (code, payload) = info
            if (code != Ptp.RESP_OK) {
                out += "GetDeviceInfo 仍然失败：${Ptp.respName(code)}，后续步骤跳过"
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
            val biggest = findBiggestObject(out, log)
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
        // 一个设备都没有是最常见的情况，且**与应用无关**——必须给出分诊提示，
        // 否则用户会以为是自己设置错或应用有 bug。
        if (devs.isEmpty()) {
            out += "USB 主机侧未发现任何设备。这一步与应用无关，请按顺序排查："
            out += "①小米的 OTG 总开关：设置 → 更多设置 → OTG 连接。" +
                "部分 MIUI 默认关闭，且「10 分钟无操作自动关闭」——关着的话主机侧什么都看不到"
            out += "②相机不能在「连接至智能设备」模式：该模式下 USB 口通常只供电不暴露数据，" +
                "需退回普通拍摄模式"
            out += "③相机 USB 设置选「MTP/PTP」档位"
            out += "④线材需为数据线；注意手机只有一个 USB-C 口时，插上 OTG 设备会占用该口，" +
                "此时电脑端 adb 会断开——属正常现象，日志请在 App 的日志面板里复制"
            return null
        }
        out += "USB 设备数：${devs.size}"
        // 每个接口的 class/subclass/protocol 都打出来：尼康 USB 设置只有「MTP/PTP」
        // 一个合并档位（没有单独的 PTP 选项），接口形态未必是标准的 class6/sub1/proto1。
        // 一次日志就能定论该按什么匹配——这决定方案是否成立。
        devs.forEach { d ->
            out += "· ${d.deviceName} vid=0x%04X pid=0x%04X 接口=${d.interfaceCount}".format(
                d.vendorId, d.productId,
            )
            for (i in 0 until d.interfaceCount) {
                val it = d.getInterface(i)
                out += "    接口$i：class=0x%02X sub=0x%02X proto=0x%02X 端点=${it.endpointCount}".format(
                    it.interfaceClass, it.interfaceSubclass, it.interfaceProtocol,
                )
            }
        }
        val target = devs.firstOrNull { pickStillImageInterface(it) != null }
        if (target == null) {
            out += "未发现 Still Image 类接口（class 6 / subclass 1）。请确认：" +
                "①相机 USB 设置选了「MTP/PTP」这个档位" +
                " ②相机已退出「连接至智能设备」 ③USB 线支持数据传输（不是纯充电线）"
            return null
        }
        device = target
        val ptp = pickStillImageInterface(target) ?: return null
        out += "选用接口：${target.deviceName} 接口${ptp.id}" +
            "（class=0x%02X sub=0x%02X proto=0x%02X）".format(
                ptp.interfaceClass, ptp.interfaceSubclass, ptp.interfaceProtocol,
            )

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
        // 把全部端点打出来：若存在中断端点，事件（容器类型 4）可能走它而非 Bulk IN，
        // 这决定要不要单独起一条事件读取通道
        for (i in 0 until ptp.endpointCount) {
            val ep = ptp.getEndpoint(i)
            out += "    端点$i：地址=0x%02X 类型=%s 方向=%s 最大包=%d".format(
                ep.address,
                when (ep.type) {
                    UsbConstants.USB_ENDPOINT_XFER_BULK -> "Bulk"
                    UsbConstants.USB_ENDPOINT_XFER_INT -> "Interrupt"
                    UsbConstants.USB_ENDPOINT_XFER_ISOC -> "Iso"
                    else -> "Control"
                },
                if (ep.direction == UsbConstants.USB_DIR_IN) "IN" else "OUT",
                ep.maxPacketSize,
            )
        }
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
        // 设备插入时系统 MTP 服务往往已经嗅探过它，IN 端点里可能留有响应包；
        // 先清干净，否则后续每次读都可能先读到陈数据
        drainInput(c, ein, log)
        return Unit
    }

    /**
     * 选 Still Image 接口。
     *
     * 尼康 Z 机身的 USB 设置只有「MTP/PTP」一个合并档位，**没有单独的 PTP 选项**。
     * MTP 是 PTP 的超集（USB 设备类上同为 Still Image），主机端自行决定说哪种协议，
     * 因此同一档位下接口的 protocol 字段未必是 1。
     * 所以：先按 class6/sub1/proto1 精确匹配，找不到再放宽到 class6/sub1 任意 protocol。
     */
    private fun pickStillImageInterface(d: UsbDevice): UsbInterface? {
        var fallback: UsbInterface? = null
        for (i in 0 until d.interfaceCount) {
            val it = d.getInterface(i)
            if (it.interfaceClass != 6 || it.interfaceSubclass != 1) continue
            if (it.interfaceProtocol == 1) return it
            if (fallback == null) fallback = it
        }
        return fallback
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

    /**
     * 打开会话。
     *
     * 实测遇到过相机直接回 `SessionAlreadyOpen`，而紧接着的 GetDeviceInfo **完全收不到响应**——
     * 说明相机上有个残留会话（很可能是 Android 的 MTP 服务在设备插入时嗅探建立的），
     * 它挡住了不属于它的后续操作。因此这里不把 SessionAlreadyOpen 当"可以用"，
     * 而是主动 CloseSession 后重开。
     */
    private fun openSession(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        eout: UsbEndpoint,
        log: (String) -> Unit,
        out: MutableList<String>,
    ): Boolean {
        val (code, _) = commandRecovering(Ptp.OP_OPEN_SESSION, longArrayOf(1), "OpenSession", out)
        out += "OpenSession → ${Ptp.respName(code)}"
        log("USB OpenSession → ${Ptp.respName(code)}")

        // 会话已存在时**直接沿用**。理由：
        // 残留会话很可能就是上一次中断的探测自己留下的，而 PTP 允许直接使用已打开的会话。
        // 此前选择"先关闭再重开"，实测 CloseSession 之后相机会重置 USB 端点状态，
        // 下一笔命令发送失败（-1，且清除 STALL 无效）——而且是非确定性的。
        //
        // ⚠️ 同时放弃"新会话事务号归零"：OpenSession 自己就占一个事务号，
        // 归零会让紧随其后的 GetDeviceInfo 与它**撞号**，相机以 IncompleteTransfer 拒绝。
        // 正确做法是同一连接内事务号单调递增。
        if (code == Ptp.RESP_OK || code == Ptp.RESP_SESSION_ALREADY_OPEN) {
            if (code == Ptp.RESP_SESSION_ALREADY_OPEN) {
                out += "沿用相机上已打开的会话（残留会话多为上一次中断的探测所留）"
            }
            Thread.sleep(300)
            return true
        }
        out += "会话打开失败，后续步骤跳过"
        return false
    }

    /**
     * 降级路径：沿用会话后第一笔操作仍失败时，关闭残留会话再重开一次。
     * 只在必要时才走——CloseSession 会扰动 USB 端点状态，能不用就不用。
     */
    private fun resetSession(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        eout: UsbEndpoint,
        log: (String) -> Unit,
        out: MutableList<String>,
    ): Boolean {
        out += "沿用会话失败，降级为：关闭残留会话后重开"
        val (closeCode, _) = runCatching {
            commandRecovering(Ptp.OP_CLOSE_SESSION, LongArray(0), "CloseSession", out)
        }.getOrElse { Ptp.RESP_OK to ByteArray(0) }
        log("USB CloseSession → ${Ptp.respName(closeCode)}")
        out += "CloseSession → ${Ptp.respName(closeCode)}"
        Thread.sleep(500)
        drainInput(c, ein, log)
        val (again, _) = commandRecovering(Ptp.OP_OPEN_SESSION, longArrayOf(1), "OpenSession", out)
        out += "重新 OpenSession → ${Ptp.respName(again)}"
        log("USB 重新 OpenSession → ${Ptp.respName(again)}")
        return again == Ptp.RESP_OK
    }

    /**
     * 清掉 IN 端点里可能残留的数据。
     * 设备插入时 Android 的 MTP 服务会去嗅探，可能留下响应包；不清掉的话
     * 后续每次读都可能先读到这些陈数据，表现为"响应错配"或超时。
     */
    private fun drainInput(
        c: UsbDeviceConnection,
        ein: UsbEndpoint,
        log: (String) -> Unit,
    ) {
        inLeftover = ByteArray(0) // 端点都清了，内存余料也必须作废
        val buf = ByteArray(16 shl 10)
        var total = 0
        var rounds = 0
        while (rounds < 30) {
            val n = runCatching { c.bulkTransfer(ein, buf, buf.size, 300) }.getOrDefault(-1)
            if (n <= 0) break
            total += n
            rounds++
        }
        if (total > 0) log("USB 清掉 IN 端点残留数据 $total 字节（$rounds 次）")
    }

    // ------------------------------------------------------------ 事务

    private fun nextTxn(): Long = (++txnId) and 0x7FFFFFFFL

    /**
     * 发送一个容器，失败时清除端点 STALL 后重试一次。
     *
     * USB 设备对不接受的数据会把端点置于 STALL 状态，此后所有 `bulkTransfer` 都返回 -1，
     * 且**不会自行恢复**——必须由主机发 CLEAR_FEATURE(ENDPOINT_HALT) 清除。
     * 实测就在 CloseSession 之后的下一笔命令上撞到了（发送返回 -1/16）。
     */
    private fun sendContainer(
        c: UsbDeviceConnection,
        eout: UsbEndpoint,
        buf: ByteArray,
        what: String,
        log: (String) -> Unit,
    ) {
        var sent = runCatching { c.bulkTransfer(eout, buf, buf.size, BULK_TIMEOUT_MS) }.getOrDefault(-1)
        if (sent != buf.size) {
            log("USB $what 发送失败（$sent/${buf.size}），清除端点 STALL 后重试")
            clearHalt(c, eout, log)
            Thread.sleep(200)
            sent = runCatching { c.bulkTransfer(eout, buf, buf.size, BULK_TIMEOUT_MS) }.getOrDefault(-1)
        }
        if (sent != buf.size) {
            throw IOException("$what 发送不完整（$sent/${buf.size}）——端点被 STALL 且清除后仍失败")
        }
    }

    /** 清除端点 STALL：标准请求 CLEAR_FEATURE(ENDPOINT_HALT)。 */
    private fun clearHalt(c: UsbDeviceConnection, ep: UsbEndpoint, log: (String) -> Unit) {
        val r = runCatching {
            c.controlTransfer(
                0x02, // 主机→设备 / 标准 / 接收方为端点
                0x01, // CLEAR_FEATURE
                0x0000, // ENDPOINT_HALT
                ep.address,
                null,
                0,
                1_000,
            )
        }.getOrDefault(-1)
        log("USB 清除端点 0x%02X 的 STALL → $r".format(ep.address))
    }

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
        var data: ByteArray = ByteArray(0)
        val txn = nextTxn()
        val buf = ByteArray(HEADER_BYTES + params.size * 4)
        PtpWire.putU32(buf, 0, buf.size.toLong())
        PtpWire.putU16(buf, 4, CT_COMMAND)
        PtpWire.putU16(buf, 6, op)
        PtpWire.putU32(buf, 8, txn)
        params.forEachIndexed { i, v -> PtpWire.putU32(buf, HEADER_BYTES + i * 4, v) }
        log("USB → 发命令 0x%04X txn=$txn 共 ${buf.size}B 原始=${hexOf(buf)}".format(op))
        sendContainer(c, eout, buf, "命令 0x" + "%04X".format(op), log)

        while (true) {
            val h = readHeader(c, ein)
            when (h.type) {
                CT_RESPONSE -> {
                    val payload = readPayload(c, ein, h.payloadLen)
                    // data-IN 操作的数据在响应**之前**到达，载荷即数据集本身
                    return h.code to (if (data.isNotEmpty()) data else payload)
                }
                // data-IN 操作（如 GetDeviceInfo）会先发 Data 容器再发 Response。
                // 原先这里把 Data 直接跳过、只返回响应的空载荷——那是实打实的 bug，
                // 会让 DeviceInfo 永远解析不出来。
                CT_DATA -> {
                    data = readPayload(c, ein, h.payloadLen)
                    log("USB 数据阶段 ${data.size}B")
                }
                // 事件可能插在响应之前：不能当未知类型抛错，丢掉继续等响应
                CT_EVENT -> {
                    log("USB 收到事件容器 ${h.payloadLen}B，已忽略")
                    skip(c, ein, h.payloadLen.toLong())
                }
                else -> throw IOException("USB 收到未知容器类型 ${h.type}")
            }
        }
    }

    /**
     * 读容器头，带重试。
     * 系统 MTP 服务可能同时在读同一个 IN 端点、或插入时留下陈数据，
     * 表现为单次读超时。重试一次比直接判失败更贴近实情，也便于从日志区分
     * "偶发抢读"与"链路真死"。
     */
    private fun readHeader(c: UsbDeviceConnection, ein: UsbEndpoint): UsbHeader {
        var last: IOException? = null
        for (attempt in 1..3) {
            try {
                return readHeaderOnce(c, ein)
            } catch (e: IOException) {
                last = e
                if (attempt < 3) Thread.sleep(250)
            }
        }
        throw last ?: IOException("USB 读取失败")
    }

    private fun readHeaderOnce(c: UsbDeviceConnection, ein: UsbEndpoint): UsbHeader {
        val h = ByteArray(HEADER_BYTES)
        readFully(c, ein, h, HEADER_BYTES)
        val len = PtpWire.getU32(h, 0)
        val type = PtpWire.getU16(h, 4)
        val code = PtpWire.getU16(h, 6)
        val txn = PtpWire.getU32(h, 8)
        // 打出收到的容器头原始字节：帧格式是否有问题，看这个最直接
        probeLog(
            "USB ← 收容器 len=$len type=$type code=0x%04X txn=$txn 原始=%s".format(
                code, hexOf(h),
            ),
        )
        if (len < HEADER_BYTES) {
            throw IOException("USB 容器长度非法：$len")
        }
        // ⚠️ 这里不能对 len 设上限：大文件（实测 174MB 的视频）的数据容器头
        // len 本来就是文件大小+12，超 64MB 是合法的。分配上限在 readPayload
        // （真正要 new ByteArray 的地方）把守，流式下载不经过它。
        return UsbHeader(type, code, txn, len - HEADER_BYTES)
    }

    /** 容器头十六进制。Kotlin 的 Byte 是有符号的，必须先掩码再格式化，否则 0xFF 会打成负数。 */
    private fun hexOf(b: ByteArray): String =
        b.joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }

    private fun readPayload(c: UsbDeviceConnection, ein: UsbEndpoint, len: Long): ByteArray {
        if (len <= 0) return ByteArray(0)
        if (len > MAX_PAYLOAD) {
            throw IOException("载荷 ${len}B 超过单次分配上限 ${MAX_PAYLOAD / 1048576}MB（大文件应走流式下载）")
        }
        val b = ByteArray(len.toInt())
        readFully(c, ein, b, len.toInt())
        return b
    }

    /**
     * Bulk 读 n 字节，循环补齐；无数据时**以较长间隔**重读。
     *
     * 三条来自真机日志对比 + 对照 libgphoto2/libmtp 源码的教训：
     *
     * 1. **单次 bulkTransfer 的缓冲必须 ≥ 端点 maxPacket**（本轮源码研读新发现，
     *    §7.3"GetDeviceInfo 被拒"的真因）。USB 是包式协议：相机数据相位按
     *    512B 高速整包发送，旧实现用 12 字节缓冲读容器头，整包装不下 →
     *    EOVERFLOW，包被主机丢弃、设备收不到 ACK 会**永远重发同一包**——
     *    表现为"已收 0/12 永远读不到"。参考实现（libgphoto2 usb.c、
     *    libmtp libusb1-glue.c）首包一律按 maxPacket 整包读。
     *
     * 2. **绝不能对 IN 端点做 clearHalt**。CLEAR_FEATURE(ENDPOINT_HALT) 会复位端点并
     *    丢弃设备正在发送的数据——实测那样做会让相机回 0x2007 IncompleteTransfer，
     *    等于"清一次丢一次"，永远救不回来。（libgphoto2 也只在能区分出
     *    STALL/IO 错误时才清一次，Android 的 bulkTransfer 无法区分错误类型。）
     *
     * 3. **重读间隔不能短**。Android 的 bulkTransfer 底层是 USBDEVFS_BULK ioctl，
     *    在上一笔传输尚未完成时立刻再发，很可能中止那个进行中的 URB。
     *    实测对比：间隔 150ms 时 +153ms 就收到了响应；改成 20ms 密集重试后，
     *    2 秒内一个字节都收不到——密集重试反而把设备正要送出的数据打断了。
     *    因此用 200ms 间隔、最多 15 次（约 3 秒）。
     *
     * 一次收到的字节可能跨过当前容器边界（载荷尾包与响应包背靠背到达），
     * 多出部分存入 [inLeftover] 按序供后续读取，绝不丢弃。
     */
    private fun readFully(c: UsbDeviceConnection, ein: UsbEndpoint, buf: ByteArray, want: Int) {
        var off = 0
        // 先吃上次整包读多出来的余料
        if (inLeftover.isNotEmpty()) {
            val take = minOf(inLeftover.size, want)
            System.arraycopy(inLeftover, 0, buf, 0, take)
            inLeftover = if (take == inLeftover.size) ByteArray(0) else inLeftover.copyOfRange(take, inLeftover.size)
            off = take
        }
        val maxPkt = maxOf(ein.maxPacketSize, HEADER_BYTES)
        var attempt = 0
        while (off < want) {
            // 单次 URB 尺寸取整到 maxPacket 整数倍：剩余空间小于一个整包时
            // 整包装不下会 EOVERFLOW（§7.3 同源问题），多读的字节进余料不丢
            val raw = minOf(want - off, STREAM_CHUNK)
            val size = if (raw >= maxPkt) raw / maxPkt * maxPkt else maxPkt
            val tmp = ByteArray(size)
            val n = runCatching { c.bulkTransfer(ein, tmp, 0, size, BULK_TIMEOUT_MS) }
                .getOrDefault(-1)
            if (n > 0) {
                val take = minOf(n, want - off)
                System.arraycopy(tmp, 0, buf, off, take)
                off += take
                if (n > take) inLeftover = tmp.copyOfRange(take, n)
                attempt = 0
                continue
            }
            attempt++
            if (attempt > 15) {
                throw IOException("USB 读取失败（已收 $off/$want，等待约 3s 仍无数据）")
            }
            probeLog("USB 暂无数据（已收 $off/$want，第 $attempt 次），200ms 后重读")
            Thread.sleep(200)
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

    /** 中断后的部分速度估算（拿到的字节虽然不全，也足够回答"快不快"） */
    private fun partialMbps(total: Long, t0: Long): Double {
        val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1)
        return (total / 1048576.0) / (ms / 1000.0)
    }

    // ------------------------------------------------------------ 测速

    /**
     * 枚举存储卡，挑最大的照片文件用于测速。
     *
     * 两个实测教训（2026-09-15）：
     * 1. **照片不在根目录**。GetObjectHandles(parent=0xFFFFFFFF) 只返回根对象，
     *    尼康卡的根下通常只有 DCIM 文件夹（关联对象，size=0）——第一版只扫根目录，
     *    于是永远"未找到可测速的对象"。必须顺着关联对象递归往下找。
     * 2. **枚举命令偶发"0/12 永远无数据"**（实测 4 轮里第 1 轮撞上，后 3 轮正常），
     *    一律走 commandRecovering（带重枚举恢复）而不是裸 command，
     *    且失败原因必须写进 out——runCatching 吞掉异常时，卡片上只会显示
     *    "存储卡为空"这种误导性结论。
     */
    private fun findBiggestObject(
        out: MutableList<String>,
        log: (String) -> Unit,
    ): Pair<Long, Long>? {
        val storageIds = runCatching {
            val (code, p) = commandRecovering(Ptp.OP_GET_STORAGE_IDS, LongArray(0), "GetStorageIDs", out)
            if (code != Ptp.RESP_OK) {
                out += "GetStorageIDs 响应：${Ptp.respName(code)}"
                return@runCatching LongArray(0)
            }
            val r = ByteReader(p)
            val n = r.u32().toInt()
            LongArray(n) { r.u32() }
        }.onFailure { out += "GetStorageIDs 异常：${it.message}" }
            .getOrDefault(LongArray(0))
        if (storageIds.isEmpty()) return null

        val FMT_ASSOCIATION = 0x3001
        var best: Pair<Long, Long>? = null
        var bestName = ""
        var infoCalls = 0

        fun walk(sid: Long, parent: Long, depth: Int) {
            if (depth > 3 || infoCalls > 80) return
            val handles = runCatching {
                val (code, p) = commandRecovering(
                    Ptp.OP_GET_OBJECT_HANDLES,
                    longArrayOf(sid, 0, parent),
                    "GetObjectHandles(parent=0x${parent.toString(16)})",
                    out,
                )
                if (code != Ptp.RESP_OK) {
                    out += "GetObjectHandles(parent=0x${parent.toString(16)}) 响应：${Ptp.respName(code)}"
                    return@runCatching LongArray(0)
                }
                val r = ByteReader(p)
                val n = r.u32().toInt()
                if (n < 0 || n > 100_000) return@runCatching LongArray(0)
                LongArray(n) { r.u32() }
            }.onFailure { out += "GetObjectHandles 异常：${it.message}" }
                .getOrDefault(LongArray(0))
            if (depth == 0) out += "存储 $sid：根下 ${handles.size} 个对象"

            for (h in handles) {
                val info = runCatching {
                    infoCalls++
                    val (code, p) = commandRecovering(Ptp.OP_GET_OBJECT_INFO, longArrayOf(h), "GetObjectInfo", out)
                    if (code != Ptp.RESP_OK) {
                        out += "GetObjectInfo(0x${h.toString(16)}) 响应：${Ptp.respName(code)}"
                        return@runCatching null
                    }
                    PtpDatasets.parseObjectInfo(p)
                }.onFailure { out += "ObjectInfo(0x${h.toString(16)}) 解析失败：${it.message}" }
                    .getOrNull() ?: continue
                if (info.format == FMT_ASSOCIATION) {
                    walk(sid, h, depth + 1) // 目录：进去找照片
                    continue
                }
                if (info.compressedSize > (best?.second ?: 0L)) {
                    best = h to info.compressedSize
                    bestName = info.filename
                }
            }
        }
        for (sid in storageIds) walk(sid, 0xFFFFFFFFL, 0)
        if (best != null) out += "最大文件：$bestName（%.1fMB）".format(best!!.second / 1048576.0)
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
        var total = 0L
        var firstBytes: ByteArray? = null
        // 读块别太大：AOSP 自带 MtpDevice 源码注明"USB reads greater than 16K don't
        // work"（USB连接方案.md §8.1）。64KB 是吞吐与稳妥的折中，大块能否用留待 U3 实测。
        val buf = ByteArray(64 shl 10)
        // 发送可恢复：设备可能恰好在重枚举离线窗里，等它重新挂上再发（换新事务号）
        var sent = false
        var lastErr: IOException? = null
        for (attempt in 1..3) {
            val txn = nextTxn()
            val cmd = ByteArray(HEADER_BYTES + 4)
            PtpWire.putU32(cmd, 0, cmd.size.toLong())
            PtpWire.putU16(cmd, 4, CT_COMMAND)
            PtpWire.putU16(cmd, 6, Ptp.OP_GET_OBJECT)
            PtpWire.putU32(cmd, 8, txn)
            PtpWire.putU32(cmd, HEADER_BYTES, handle)
            try {
                sendContainer(c, eout, cmd, "GetObject 命令", log)
                sent = true
                break
            } catch (e: IOException) {
                lastErr = e
                log("USB GetObject 发送失败（第 $attempt 次）：${e.message}")
                if (!reopenAfterEnumeration(log)) break
            }
        }
        if (!sent) throw (lastErr ?: IOException("GetObject 发送失败"))
        val t0 = System.currentTimeMillis()
        try {
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
                var left = h.payloadLen
                while (left > 0) {
                    val want = minOf(buf.size.toLong(), left).toInt()
                    readFully(c, ein, buf, want)
                    if (firstBytes == null) firstBytes = buf.copyOf(minOf(16, want))
                    total += want
                    left -= want
                }
            }
        } catch (e: IOException) {
            // 中途断开：已收大块数据时按部分数据报告速度，别让整次测速白跑
            if (total > 1 shl 20) {
                log("USB 传输中断：${e.message}，按已收数据估算部分速度")
                return partialMbps(total, t0)
            }
            throw e
        }
        val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1)
        val mbps = (total / 1048576.0) / (ms / 1000.0)
        // 校验数据是已知的图像/视频格式特征，防止"测得很快但数据是错的"
        val fb = firstBytes
        val jpeg = fb != null && fb.size >= 2 && fb[0] == 0xFF.toByte() && fb[1] == 0xD8.toByte()
        val mp4 = fb != null && fb.size >= 8 && fb[4] == 0x66.toByte() && fb[5] == 0x74.toByte() &&
            fb[6] == 0x79.toByte() && fb[7] == 0x70.toByte() // "ftyp"（MOV/MP4）
        log(
            "USB 测速：$total 字节 / ${ms}ms = %.1f MB/s，数据特征：%s".format(
                mbps, when {
                    jpeg -> "JPEG"
                    mp4 -> "MOV/MP4"
                    else -> "未知！"
                },
            ),
        )
        if (!jpeg && !mp4) log("⚠️ 数据不像 JPEG/视频，测速结果不可信")
        if (declaredSize > 0 && total != declaredSize) {
            log("⚠️ 实际字节 $total 与 ObjectInfo 声明 $declaredSize 不一致")
        }
        return if (jpeg || mp4) mbps else 0.0
    }
}
