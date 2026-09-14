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
    /** 取景中 AF/拍摄通道探针（调试面板用）。 */
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
        out += t("0x9405 无参（疑似LV AF/拍摄）", Ptp.OP_NIKON_LV_CAPTURE, LongArray(0))
        out += t("0x100E 标准快门（会实拍！）", Ptp.OP_INITIATE_CAPTURE, LongArray(0))
        out += t("0x9205 AF区域[128,128]", 0x9205, longArrayOf(128L, 128L))
        out += t("0x9204 MF驱动[1,0]", 0x9204, longArrayOf(1L, 0L))
        out += t("0x90C3 AF驱动", 0x90C3, LongArray(0))
        out += t("0x9209 状态", 0x9209, LongArray(0))
        out.forEach { CameraEngine.log("LV对焦探针 $it") }
        return out
    }

    /**
     * 高速下载探针：0x9400~0x9406 逐个尝试多种参数形态，
     * 记录响应码/数据量，用于定位新一代高速读取操作。
     */
    fun probeHiSpeed(handle: Long): List<String> {
        val c = CameraEngine.need()
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
        out.forEach { CameraEngine.log("探针 $it") }
        return out
    }

    /** 相机端缩放探针：0x9207 GetObjectResize 的参数形态尝试。 */
    fun probeResize(handle: Long): List<String> {
        val c = CameraEngine.need()
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
