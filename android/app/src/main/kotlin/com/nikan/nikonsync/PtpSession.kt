package com.nikan.nikonsync

import java.io.IOException
import java.io.OutputStream

/**
 * PTP 会话的传输层抽象。上层逻辑（枚举/下载/遥控/保活）只依赖此接口，
 * Wi-Fi（PtpIpClient）与 USB（PtpUsbClient）各实现一份——
 * 即 USB连接方案.md §3 U2 的"PtpSession 接口"落地。
 *
 * 接口形状 = CameraEngine 的实际依赖面（transact / getObjectToStream /
 * connect / close / deviceInfo / cameraName / 两个回调），不为未来预留空方法。
 */
interface PtpSession {
    class TransactResult(val responseCode: Int, val params: LongArray, val data: ByteArray)

    /**
     * 下载模式。Wi-Fi 有 0x94xx 厂商高速通道（HISPEED）与分块（PARTIAL），
     * 失败时逐级降级；USB 下 GetObject 整文件流式即最快路径，恒为 FULL、无需降级。
     */
    enum class DlMode { HISPEED, PARTIAL, FULL }

    val deviceInfo: DeviceInfo?
    val cameraName: String
    val isConnected: Boolean
    val effectiveDlMode: DlMode

    /** 事件回调：code 为 PTP 事件码，params 为事件参数（如 ObjectAdded 的对象句柄）。 */
    var eventHandler: ((Int, LongArray) -> Unit)?

    /** 断连回调：连接死亡且不可恢复时触发一次。 */
    var disconnectHandler: ((String) -> Unit)?

    /**
     * 建立会话并完成 OpenSession + GetDeviceInfo（deviceInfo/cameraName 就绪后返回）。
     * @param arg Wi-Fi：相机 IP；USB：忽略（设备由 UsbManager 枚举获得）。
     */
    fun connect(arg: String, friendlyName: String)

    fun close()

    /** 同步执行一笔 PTP 事务；多线程并发调用由实现内部串行化。 */
    fun transact(op: Int, params: LongArray = LongArray(0)): TransactResult

    /**
     * 数据外发事务（SetDevicePropDesc / SendObjectInfo 等需要 data-OUT 的操作）。
     * 语义与 [transact] 一致：非 OK 响应抛 PtpException。
     */
    fun transactWithDataOut(op: Int, params: LongArray, data: ByteArray): TransactResult

    /**
     * 短超时事务（探测类操作用，失败快速返回）。Wi-Fi 侧缩短 socket 超时；
     * USB 的 bulkTransfer 不遵守超时参数，默认实现等同 [transact]。
     */
    fun transactShort(op: Int, params: LongArray = LongArray(0), timeoutMs: Int = 3000): TransactResult =
        transact(op, params)

    /** 大缩略图（0x9403），失败回退标准 GetThumb。返回原始 JPEG 字节。 */
    fun getThumbnailBytes(handle: Long): ByteArray =
        transact(Ptp.OP_GET_THUMB, longArrayOf(handle)).data

    /**
     * 下载对象并写入 out，返回实际写入的字节数。
     * 调用方必须把返回值与 GetObjectInfo 的 size 比对：任何"少传数据就结束"的
     * 情形都要显式失败，绝不能静默保存残缺文件（阶段 0 的教训）。
     */
    fun getObjectToStream(
        handle: Long,
        size: Long,
        out: OutputStream,
        onProgress: (received: Long, total: Long) -> Unit,
    ): Long

    /** Wi-Fi 分块下载失败时降级整文件重试；实现无需降级时保持空实现。 */
    fun degradeToFullDownload() {}

    /** 立即判死（保活探针失败等）；实现必须触发一次 disconnectHandler，重复调用应被忽略。 */
    fun notifyLinkDead(reason: String)

    /** 下载前快速校验：size 无效直接拒绝，避免生成空文件。 */
    fun requireValidSize(size: Long) {
        if (size <= 0) throw IOException("对象大小无效（$size），拒绝下载以免生成空文件")
    }
}
