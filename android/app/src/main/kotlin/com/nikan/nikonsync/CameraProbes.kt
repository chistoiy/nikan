package com.nikan.nikonsync

import android.os.SystemClock

/**
 * 协议探针：只读诊断与厂商操作码试探，仅供调试面板调用。
 *
 * 从 CameraEngine 拆出（原文件逾 1500 行，探针段约占 380 行）。
 * 依赖的引擎成员已放宽为 internal：CameraEngine.need() / CameraEngine.client / CameraEngine.indexOfSoi()。
 *
 * ⚠️ 保留在 CameraEngine 里的 drainCheckEvents / parseCheckEvents 是事件排水的共用逻辑，
 *    与探针无关，不要一起搬走。
 * ⚠️ 其中若干探针会真实改变相机状态（实拍、写卡），新增时必须标注并走调试面板的二次确认。
 */
internal object CameraProbes {
    /**
     * 取景中 AF 通道探针（调试面板用）。
     *
     * ⚠️ 2026-09-15 第三轮按 libgphoto2 ptp.h 重写：旧版本试的是 0x9405（实为
     * **MeasureSpotWb 点测白平衡**）和 0x90C3（实为 **DelImageSDRAM，需 1 参数**），
     * 两个都不是对焦操作，探针结论因此一直误导。
     * 现在的候选按证据排序：0x90C1=AfDrive（无参，本轮采用）、0x9205=ChangeAfArea(2 参数)、
     * 0x9204=MfDrive(2 参数)、0x9206=AfDriveCancel（无参）、0x90C8=DeviceReady（对照）。
     */
    fun probeLvAf(handle: Long): List<String> {
        val c = CameraEngine.need()
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
        out += t("0x90C1 AfDrive（无参，应采用）", Ptp.OP_NIKON_AF_DRIVE, LongArray(0))
        out += t("0x9205 ChangeAfArea(128,128)", Ptp.OP_NIKON_CHANGE_AF_AREA, longArrayOf(128L, 128L))
        out += t("0x9204 MfDrive(1,0)", Ptp.OP_NIKON_MF_DRIVE, longArrayOf(1L, 0L))
        out += t("0x9206 AfDriveCancel", Ptp.OP_NIKON_AF_DRIVE_CANCEL, LongArray(0))
        out += t("0x90C8 DeviceReady（对照）", Ptp.OP_NIKON_DEVICE_READY, LongArray(0))
        out += t("0x90C3 DelImageSDRAM(0)（对照，旧版误当AF）", Ptp.OP_NIKON_DEL_IMAGE_SDRAM, longArrayOf(0L))
        out.forEach { CameraEngine.log("LV对焦探针 $it") }
        return out
    }

    /**
     * 实时 ISO 发现探针（自动，无需用户操作相机）。
     *
     * 起因：Auto ISO 下相机屏幕显示 `ISO AUTO 2500`，而属性 `0x500F` 读出来停在 2000
     * ——0x500F 报的很可能只是"ISO 设定/上限"，不是当下实际使用的感光度。
     *
     * 做法（**差分法**，不需要知道属性名）：
     * 1. 读 `0x500F` 描述符，拿到它的 ISO 取值表（例如 100…51200）；
     * 2. `0x90CA` 列出全部厂商属性码，逐个用 `0x1015 GetDevicePropValue` 读当前值；
     * 3. 等 8 秒（Auto ISO 会自己变），再读一遍；
     * 4. 报告**值发生变化的属性码**，并把新值落在 ISO 取值表里的码标为"疑似实时 ISO"。
     *
     * 运行期间请把镜头对着明暗变化的地方，否则 Auto ISO 不会动、差分为空。
     */
    fun probeLiveIso(): List<String> {
        val c = CameraEngine.need()
        val out = ArrayList<String>()

        // 1) ISO 取值表
        val isoDesc = runCatching {
            c.transact(Ptp.OP_GET_DEVICE_PROP_DESC, longArrayOf(0x500FL)).data
        }.getOrNull()
        var isoTable = emptySet<Long>()
        var isoCurrent = -1L
        if (isoDesc != null) {
            val r = ByteReader(isoDesc)
            r.u16()
            val dtype = r.u16()
            r.u8()
            ptpValue(r, dtype)
            isoCurrent = ptpValue(r, dtype) ?: -1L
            if (r.u8() == 2) {
                val n = r.u16()
                isoTable = (0 until n).mapNotNull { ptpValue(r, dtype) }.toSet()
            }
        }
        out += "0x500F 当前=$isoCurrent，取值表 ${isoTable.size} 项" +
            if (isoTable.isNotEmpty()) "（最小 ${isoTable.min()} 最大 ${isoTable.max()}）" else ""

        // 2) 属性码清单：**标准段与厂商段都要差**——
        //    0x500F(ExposureIndex) 在 Auto ISO 下不反映实际值，实时值可能在标准段的其他码
        //    （0x5008 等）或某个厂商码里。
        val codes = (0x5001L..0x5017L).toList() +
            vendorPropCodes(c).filter { it in 0xD000L..0xDFFFL }.take(150)
        if (codes.isEmpty()) {
            out += "未取到可读属性码，无法差分"
            out.forEach { CameraEngine.log("实时ISO探针 $it") }
            return out
        }
        val first = readPropValues(c, codes)
        out += "第一遍读取 ${first.size}/${codes.size} 个厂商属性"

        // 3) 等 Auto ISO 变化
        CameraEngine.log("实时ISO探针 等待 8 秒（请对着明暗变化的地方，让 Auto ISO 动起来）")
        Thread.sleep(8_000)
        val second = readPropValues(c, codes)

        // 4) 差分
        val changed = ArrayList<String>()
        for (code in codes) {
            val a = first[code] ?: continue
            val b = second[code] ?: continue
            if (a == b) continue
            val isoHint = if (b in isoTable) "  ← 值在 ISO 表内" else ""
            changed += "0x%04X %d→%d%s".format(code, a, b, isoHint)
        }
        out += if (changed.isEmpty()) {
            "8 秒内没有任何厂商属性变化（Auto ISO 可能没在动，或本机把实时值放在别处）"
        } else {
            "8 秒内变化 ${changed.size} 项：" + changed.joinToString(" | ")
        }
        out.forEach { CameraEngine.log("实时ISO探针 $it") }
        return out
    }

    /** 读厂商属性码列表（0x90CA 返回 [u32 数量] + N×u16，或裸 u16 数组）。 */
    private fun vendorPropCodes(c: PtpSession): List<Long> {
        val d = runCatching {
            c.transact(Ptp.OP_NIKON_GET_VENDOR_PROP_CODES, LongArray(0)).data
        }.getOrNull() ?: return emptyList()
        var i = 0
        if (d.size >= 4) {
            val n = PtpWire.getU32(d, 0)
            if (n in 1..4000) i = 4
        }
        val out = ArrayList<Long>()
        while (i + 1 < d.size && out.size < 4000) {
            out += PtpWire.getU16(d, i).toLong()
            i += 2
        }
        return out
    }

    /** 逐码读当前值（0x1015）；按返回字节数猜类型。读不到的码不进结果。 */
    private fun readPropValues(c: PtpSession, codes: List<Long>): Map<Long, Long> {
        val map = LinkedHashMap<Long, Long>()
        for (code in codes) {
            val d = runCatching {
                c.transactShort(Ptp.OP_GET_DEVICE_PROP_VALUE, longArrayOf(code), 1500).data
            }.getOrNull() ?: continue
            val v = when {
                d.size >= 4 -> PtpWire.getU32(d, 0)
                d.size == 2 -> PtpWire.getU16(d, 0).toLong()
                d.size == 1 -> (d[0].toLong() and 0xFF)
                else -> continue
            }
            map[code] = v
        }
        return map
    }

    /** 读一个属性描述符的取值（按 dtype；8 字节类型只取低 32 位，够用） */
    private fun ptpValue(r: ByteReader, dtype: Int): Long? = when (dtype) {
        0x0001, 0x0002 -> r.u8().toLong()
        0x0003, 0x0004 -> r.u16().toLong()
        0x0005, 0x0006 -> r.u32()
        0x0007, 0x0008 -> {
            val lo = r.u32()
            r.u32()
            lo
        }
        else -> null
    }

    /**
     * 休眠/自动关机相关属性探针（只读）。
     *
     * 起因：真机上相机空闲十几秒就息屏，息屏后 `0x9203` 恒 NotLiveView、`0x9205`
     * 被接受却不生效，遥控拍摄直接不可用（必须手动按相机快门才醒）。
     * 这里把"能延长屏幕/待机时间"的属性全部读出来，取值表就是可写范围的答案：
     * - 0xD064 MonitorOff（LCD Off Time，libgphoto2 标注**可写**）
     * - 0xD062 MeterOff（Auto Meter Off Time，可写）
     * - 0xD066 AutoOffTimers（自动关机组合档）
     * - 0xD0B3 MonitorOffDelay
     */
    fun probeSleep(): List<String> {
        val c = CameraEngine.need()
        val out = ArrayList<String>()
        for ((code, name) in listOf(
            0xD064L to "MonitorOff LCD关闭",
            0xD062L to "MeterOff 测光关闭",
            0xD066L to "AutoOffTimers 自动关机",
            0xD0B3L to "MonitorOffDelay",
        )) {
            val line = CameraEngine.propDescDebugLine(code)
            out += "0x%04X %s → %s".format(code, name, line ?: "不支持")
        }
        // DeviceReady 在息屏后是否仍应答（判断"能不能从 App 唤醒"）
        val t0 = SystemClock.elapsedRealtime()
        val awake = runCatching { c.transactShort(Ptp.OP_NIKON_DEVICE_READY, LongArray(0), 3000) }
        val ms = SystemClock.elapsedRealtime() - t0
        out += if (awake.isSuccess) {
            "0x90C8 DeviceReady（唤醒）→ OK ${ms}ms（屏幕此刻是亮的吗？）"
        } else {
            "0x90C8 DeviceReady（唤醒）→ ${Ptp.respName((awake.exceptionOrNull() as? PtpException)?.code ?: -1)} ${ms}ms"
        }
        out.forEach { CameraEngine.log("休眠探针 $it") }
        return out
    }

    /**
     * 取景对焦坐标标定探针（必须**先进入实时取景**再跑）。
     *
     * 要回答的问题：`0x9205 ChangeAfArea` 的 x/y 到底在哪个坐标空间里？
     * 我们的点击换算用的是「取景帧像素」（实测 640×424），相机接受了这些值、
     * 但对焦点落到别处——典型的"空间不同、比例不同"。
     *
     * 做法（只读 + 三个无副作用的坐标试探）：
     * 1. `0x90CA GetVendorPropCodes` 列出相机支持的厂商属性码，看有没有
     *    0xD05D LiveViewAFArea / 0xD061 LiveViewAFFocus / 0xD108 AutofocusArea /
     *    0xD08D AFAreaPoint —— 有的话它们的取值范围就是 AF 坐标空间的第一手证据；
     * 2. 对上述码逐个读描述符（类型/枚举/范围/当前值）；
     * 3. 按**两种候选缩放**（×1 = 取景帧像素，×3 = 相机内部 1920 宽的取景图）
     *    各发一个"画面 1/4 处"的点，人眼在相机屏幕上即可判断哪一种落在 1/4 处。
     */
    fun probeAfArea(frameW: Int, frameH: Int): List<String> {
        val c = CameraEngine.need()
        val out = ArrayList<String>()
        val fw = if (frameW > 0) frameW else 640
        val fh = if (frameH > 0) frameH else 424

        // 1) 支持的厂商属性码
        val codes = runCatching {
            c.transact(Ptp.OP_NIKON_GET_VENDOR_PROP_CODES, LongArray(0)).data
        }.getOrNull()
        if (codes == null || codes.isEmpty()) {
            out += "0x90CA GetVendorPropCodes → 无数据（该机型可能不支持）"
        } else {
            val list = ArrayList<Long>()
            var i = 0
            if (codes.size >= 4) {
                // 载荷可能是 [u32 数量] + N×u16，也可能直接是 u16 数组，两种都试
                val n = PtpWire.getU32(codes, 0)
                if (n in 1..2000) i = 4 else i = 0
            }
            while (i + 1 < codes.size && list.size < 2000) {
                list += PtpWire.getU16(codes, i).toLong()
                i += 2
            }
            out += "0x90CA 厂商属性码：${list.size} 个"
            val interest = listOf(0xD05DL, 0xD061L, 0xD08DL, 0xD108L, 0xD1A0L, 0xD0B2L)
            val hits = interest.filter { list.contains(it) }
            out += "其中 AF/取景相关：${
                if (hits.isEmpty()) "均未出现" else hits.joinToString(", ") { "0x%04X".format(it) }
            }"
        }

        // 2) 候选属性描述符：0xD08D「AF Area Point」若可读，就能**读回相机实际的对焦点**
        //     ——那意味着可以自动标定倍数（发一个坐标、读回落点、解方程），不必靠肉眼。
        for (code in longArrayOf(0xD08DL, 0xD05DL, 0xD061L, 0xD108L)) {
            val d = runCatching {
                c.transact(Ptp.OP_GET_DEVICE_PROP_DESC, longArrayOf(code)).data
            }.getOrNull()
            if (d == null || d.size < 8) {
                out += "0x%04X → 不支持".format(code)
                continue
            }
            val r = ByteReader(d)
            val dtype = r.u16(); r.u16()
            val getSet = r.u8()
            val dm = CameraEngine.propDescDebugLine(code)
            out += "0x%04X dtype=0x%04X %s %s".format(
                code, dtype, if (getSet != 0) "可写" else "只读", dm ?: "",
            )
        }
        // 顺带读回一次当前值（若存在）——用于判断"能否读回对焦点位置"
        runCatching {
            val v = c.transactShort(Ptp.OP_GET_DEVICE_PROP_VALUE, longArrayOf(0xD08DL), 2000).data
            if (v.isNotEmpty()) {
                out += "0xD08D 当前值 = ${v.joinToString(" ") { "%02X".format(it) }}（读回可用！）"
            }
        }

        // 3) 坐标空间试探：**中心点对任何等比缩放都是不变量**，先用它验证"有没有偏移"；
        //    再用"画面 1/4 处"在 ×4 下发一次，人眼比对即可确认倍数。
        //    2026-09-15 真机实测：×4 与相机一致（×16 会把对焦点顶到右下角 = 被截断）。
        val cx = fw / 2
        val cy = fh / 2
        for ((label, sx, sy) in listOf(
            Triple("中心（任何倍数都应落在正中，验证原点）", cx.toLong(), cy.toLong()),
            Triple("1/4 处 ×4（实测倍数，应落在画面 1/4 处）", (fw / 4 * 4).toLong(), (fh / 4 * 4).toLong()),
            Triple("3/4 处 ×4（应落在画面 3/4 处）", (fw * 3 / 4 * 4).toLong(), (fh * 3 / 4 * 4).toLong()),
        )) {
            val r = runCatching {
                c.transactShort(Ptp.OP_NIKON_CHANGE_AF_AREA, longArrayOf(sx, sy), 2500)
            }
            out += "0x9205 $label → 发送[$sx,$sy] " + if (r.isSuccess) {
                "OK（看相机屏幕：对焦框落在画面什么位置？）"
            } else {
                Ptp.respName((r.exceptionOrNull() as? PtpException)?.code ?: -1)
            }
        }
        out.forEach { CameraEngine.log("AF标定 $it") }
        return out
    }

    /**
     * 高速下载探针：0x9400~0x9406 逐个尝试多种参数形态，
     * 记录响应码/数据量，用于定位新一代高速读取操作。
     */
    fun probeHiSpeed(handle: Long): List<String> {
        val c = CameraEngine.need()
        val out = ArrayList<String>()
        // 0x9400 的真实形态（libgphoto2 ptp.h）：
        //   3 参数 = [对象句柄, 32bit 传输长度, 结束标志]，返回 r1=已发送字节数、
        //   r2/r3 = 传输前偏移（低/高 32 位，可用于续传）。
        // 旧代码把它当 [句柄, 偏移, 长度] 试，得到 OutOfFocus —— 参数语义完全不同。
        // ⚠️ 结束标志只试 0：置 1 会让相机认为"传完即结束"，可能后续数据无人接收
        // （这条探针在连接后自动跑，不能有副作用）。
        val shapes = listOf(
            "句柄,传输长度,结束标志=0" to longArrayOf(handle, 1048576, 0),
            "句柄,长度" to longArrayOf(handle, 1048576),
            "句柄（旧猜法 偏移0 长度64K）" to longArrayOf(handle, 0, 65536),
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
        out.forEach { CameraEngine.log("探针 $it") }
        return out
    }

    /**
     * 中等图探针：查看器"中"档用的 GetFhdPicture(0x920F，1 参数=对象句柄)，
     * 返回 ≤1920×1028 的图片。
     *
     * ⚠️ 本探针此前叫 probeResize 并试 0x9207——按 libgphoto2 ptp.h，**0x9207 是
     * InitiateCaptureRecInMedia（拍摄操作）**，当只读探针反复试是危险的。
     * 0x920F 才是相机端出小图的正解。
     */
    fun probeResize(handle: Long): List<String> {
        val c = CameraEngine.need()
        val out = ArrayList<String>()
        val tryOp = { label: String, op: Int, params: LongArray ->
            val result = try {
                val data = c.transact(op, params).data
                val soi = CameraEngine.indexOfSoi(data)
                val jpeg = if (soi > 0) data.copyOfRange(soi, data.size) else data
                val dims = jpegDims(jpeg)
                val extra = if (dims.isNotEmpty()) " $dims" else ""
                "OK ${data.size}B（JPEG 偏移 $soi）$extra"
            } catch (e: PtpException) {
                Ptp.respName(e.code)
            } catch (e: Exception) {
                e.message ?: "异常"
            }
            out += "0x%04X [%s] → %s".format(op, label, result)
        }
        tryOp("句柄", Ptp.OP_NIKON_GET_FHD_PICTURE, longArrayOf(handle))
        tryOp("句柄（对照 GetThumb）", Ptp.OP_GET_THUMB, longArrayOf(handle))
        tryOp("句柄（对照 大缩略图）", Ptp.OP_NIKON_GET_LARGE_THUMB, longArrayOf(handle))
        out.forEach { CameraEngine.log("探针 $it") }
        return out
    }

    /** 实时取景探针：0x9200~0x9203 逐个试探（不包含会真拍照的操作）。 */
    fun probeLiveView(): List<String> {
        val c = CameraEngine.need()
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
        out.forEach { CameraEngine.log("取景探针 $it") }
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
        val c = CameraEngine.need()
        val out = ArrayList<String>()
        var startedHere = false
        try {
            if (!CameraEngine.liveViewOn) {
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
                CameraEngine.log("取景帧探针 $line")
            }
        } finally {
            // 无论上面发生什么都要关闭取景：绝不能把相机留在取景态
            if (startedHere) {
                runCatching { c.transactShort(Ptp.OP_NIKON_LV_END, LongArray(0), 3000) }
                    .onFailure { CameraEngine.log("结束取景失败：${it.message}") }
                CameraEngine.liveViewOn = false
                CameraEngine.log("取景帧尺寸探针结束，已关闭取景")
            }
        }
        return out
    }

    /** 从 JPEG 字节里找 SOF 段读出像素尺寸，返回 "宽×高" 或失败原因。 */
    private fun jpegDims(d: ByteArray): String {
        val soi = CameraEngine.indexOfSoi(d)
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
        val c = CameraEngine.need()
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
            while (SystemClock.elapsedRealtime() - t0 < 12_000 && !found && CameraEngine.client != null) {
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
        CameraEngine.liveViewOn = false
        out.forEach { CameraEngine.log("取景2 $it") }
        return out
    }

    /**
     * 实时取景探针 v3：启动取景后，对候选操作在"取景中"状态下的响应码全量记录。
     * 对比基线（未取景：0x9403~06=0xA00B NotLiveView、0x9400~02=ParameterNotSupported），
     * 响应码发生变化的操作即为取景帧/状态通道。最后恢复并验证。
     */
    fun probeLiveView3(handle: Long): List<String> {
        val c = CameraEngine.need()
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

        CameraEngine.liveViewOn = false
        out.forEach { CameraEngine.log("取景3 $it") }
        return out
    }

    /**
     * 实时取景探针 v4：状态机完整探索。
     * 已知：0x9201 后 0x9403 从 NotLiveView 变 OK；0x9400 三参数稳定返回 OutOfFocus（疑似带对焦检查的拍摄类操作）。
     * 本探针：对焦 → 0x9400 对比 → 0x9201/0x9206 双向状态翻转 → 每个 OK 响应输出数据头 16 字节 hex。
     * 注意：0x9400 若为拍摄类操作，对焦后调用可能会实拍一张测试照。
     */
    fun probeLiveView4(handle: Long): List<String> {
        val c = CameraEngine.need()
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

        CameraEngine.liveViewOn = false
        out.forEach { CameraEngine.log("取景4 $it") }
        return out
    }

    /**
     * 实时取景探针 v5：候机唤醒 → 启动取景 → 耐心轮询等取景热身（最长 30s） → 抳焦后测试 LV 拍摄 → 关闭。
     * 已知：0x9201=开启取景状态、0x9206=关闭、0x9403 在取景中返回 OK（首先 0B，可能热身后出帧）、
     *       0x9405 在取景中返回 OutOfFocus（疑似取景中拍摄，对焦优先）、0x9209 返回状态字节。
     */
    fun probeLiveView5(handle: Long): List<String> {
        val c = CameraEngine.need()
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
        while (SystemClock.elapsedRealtime() - t0 < 30_000 && CameraEngine.client != null) {
            val (ok3, n3) = tryOp(0x9403L, LongArray(0), 1500)
            val (ok2, n2) = tryOp(0x9203L, LongArray(0), 1500)
            lastSizes = "0x9403=${if (ok3) "${n3}B" else Ptp.respName(n3)} 0x9203=${if (ok2) "${n2}B" else Ptp.respName(n2)}"
            if (ok3 && n3 > 0 && frameOp == 0L) frameOp = 0x9403L
            if (ok2 && n2 > 0 && frameOp == 0L) frameOp = 0x9203L
            if (frameOp != 0L) {
                // 拿到帧：连续采样 5 次记录帧大小曲线
                var i = 0
                while (i < 5 && CameraEngine.client != null) {
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

        CameraEngine.liveViewOn = false
        out.forEach { CameraEngine.log("取景5 $it") }
        return out
    }

    private fun attempt_marker(t0: Long): Boolean =
        SystemClock.elapsedRealtime() - t0 > 6_000 && (SystemClock.elapsedRealtime() - t0) % 3000 < 700
}
