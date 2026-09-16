package com.nikan.nikonsync

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException

/** PTP/IP 原始报文：类型 + 载荷（不含 8 字节头）。 */
class PtpPacket(val type: Int, val payload: ByteArray)

/**
 * 读包超时，且**已收到部分字节**。
 *
 * [partialBytes] 是本次读包已经吃掉的字节数：
 * - `0` → 超时发生在**包边界**，流里的位置仍然合法，后续报文可以照常解析；
 * - `>0` → 半个包留在流里，之后每个事务都会解析错位，**只能作废连接**。
 *
 * 这个区分是"超时不再必然掉线"的关键：此前 readFully 不报告进度，任何超时
 * 都被当成错位处理，于是一次取景帧慢就直接把整条连接判死（见交接文档 §15/§19）。
 */
class PacketTimeoutException(
    val partialBytes: Int,
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

/** 编解码错误。 */
class WireException(message: String) : IOException(message)

/** PTP 事务失败（响应码 != OK）。 */
class PtpException(val code: Int, message: String) : IOException("PTP ${Ptp.respName(code)}: $message")

/** 小端读写 + 报文封装 + 字符串编解码。 */
object PtpWire {
    const val HEADER_SIZE = 8

    /**
     * 单包长度上限。长度字段来自对端，损坏或异常值会走到 ByteArray 巨量分配
     * （甚至因 toInt() 溢出变成负长度）。相机实际报文远小于此值。
     */
    const val MAX_PACKET_BYTES = 16 shl 20

    fun putU16(b: ByteArray, off: Int, v: Int) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
    }

    fun putU64(b: ByteArray, off: Int, v: Long) {
        putU32(b, off, v and 0xFFFFFFFFL)
        putU32(b, off + 4, (v ushr 32) and 0xFFFFFFFFL)
    }

    fun putU32(b: ByteArray, off: Int, v: Long) {
        b[off] = (v and 0xFF).toByte()
        b[off + 1] = ((v shr 8) and 0xFF).toByte()
        b[off + 2] = ((v shr 16) and 0xFF).toByte()
        b[off + 3] = ((v shr 24) and 0xFF).toByte()
    }

    fun getU16(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)

    fun getU32(b: ByteArray, off: Int): Long {
        var v = 0L
        for (i in 3 downTo 0) v = (v shl 8) or (b[off + i].toLong() and 0xFF)
        return v
    }

    fun getU64(b: ByteArray, off: Int): Long = getU32(b, off) or (getU32(b, off + 4) shl 32)

    fun readFully(input: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) throw IOException("socket EOF")
            off += n
        }
    }

    fun writePacket(out: OutputStream, type: Int, payload: ByteArray) {
        val buf = ByteArray(HEADER_SIZE + payload.size)
        putU32(buf, 0, buf.size.toLong())
        putU32(buf, 4, type.toLong())
        payload.copyInto(buf, HEADER_SIZE)
        out.write(buf)
        out.flush()
    }

    fun readPacket(input: InputStream): PtpPacket {
        val hdr = ByteArray(HEADER_SIZE)
        readFully(input, hdr)
        val len = getU32(hdr, 0)
        val type = getU32(hdr, 4).toInt()
        // 必须先校验长度再分配：损坏的长度会造成 OOM 或 NegativeArraySizeException，
        // 而事件读取线程一旦抛出 Error 就会静默死亡（UI 仍显示已连接却收不到任何事件）。
        if (len < HEADER_SIZE || len > MAX_PACKET_BYTES) {
            throw WireException("非法包长度 $len（允许 $HEADER_SIZE~$MAX_PACKET_BYTES）")
        }
        val payloadLen = (len - HEADER_SIZE).toInt()
        val payload = ByteArray(payloadLen)
        if (payloadLen > 0) readFully(input, payload)
        return PtpPacket(type, payload)
    }

    /**
     * 与 [readPacket] 相同，但读超时时抛出带**已读字节数**的 [PacketTimeoutException]，
     * 让调用方能区分"卡在包边界"（可继续用）与"卡在包中间"（流已错位）。
     */
    fun readPacketTracked(input: InputStream): PtpPacket {
        val hdr = ByteArray(HEADER_SIZE)
        var off = 0
        while (off < HEADER_SIZE) {
            val n = try {
                input.read(hdr, off, HEADER_SIZE - off)
            } catch (e: SocketTimeoutException) {
                throw PacketTimeoutException(off, "读包头超时（已收 $off/$HEADER_SIZE 字节）", e)
            }
            if (n < 0) throw IOException("socket EOF")
            off += n
        }
        val len = getU32(hdr, 0)
        val type = getU32(hdr, 4).toInt()
        if (len < HEADER_SIZE || len > MAX_PACKET_BYTES) {
            throw WireException("非法包长度 $len（允许 $HEADER_SIZE~$MAX_PACKET_BYTES）")
        }
        val payloadLen = (len - HEADER_SIZE).toInt()
        val payload = ByteArray(payloadLen)
        off = 0
        while (off < payloadLen) {
            val n = try {
                input.read(payload, off, payloadLen - off)
            } catch (e: SocketTimeoutException) {
                // 已经读完包头：即使载荷一个字节都没到，位置也不再是包边界
                throw PacketTimeoutException(HEADER_SIZE + off, "读载荷超时（已收 $off/$payloadLen 字节）", e)
            }
            if (n < 0) throw IOException("socket EOF")
            off += n
        }
        return PtpPacket(type, payload)
    }

    /** InitCommandRequest/Ack 中的友好名：UTF-16LE + null 结尾。 */
    fun encodeUtf16LeNullTerm(s: String): ByteArray {
        val bytes = ByteArray((s.length + 1) * 2)
        var off = 0
        for (ch in s) {
            putU16(bytes, off, ch.code)
            off += 2
        }
        putU16(bytes, off, 0)
        return bytes
    }

    /** 从 off 开始解码 UTF-16LE null 结尾字符串，返回 [字符串, 消耗字节数]。 */
    fun decodeUtf16Le(b: ByteArray, off: Int): Pair<String, Int> {
        var i = off
        val sb = StringBuilder()
        while (i + 1 < b.size) {
            val u = getU16(b, i)
            i += 2
            if (u == 0) break
            sb.append(u.toChar())
        }
        return sb.toString() to (i - off)
    }
}

/** PTP 数据集（DeviceInfo/ObjectInfo/数组）读取器。字段全部小端。 */
class ByteReader(private val b: ByteArray) {
    var off = 0
        private set

    val remaining: Int get() = b.size - off

    private fun need(n: Int) {
        if (b.size - off < n) throw WireException("数据集在 $off 处越界（需要 $n 字节，剩余 ${b.size - off}）")
    }

    fun u8(): Int {
        need(1)
        return b[off++].toInt() and 0xFF
    }

    fun u16(): Int {
        need(2)
        val v = (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
        off += 2
        return v
    }

    fun u32(): Long {
        need(4)
        var v = 0L
        for (i in 3 downTo 0) v = (v shl 8) or (b[off + i].toLong() and 0xFF)
        off += 4
        return v
    }

    fun bytes(n: Int): ByteArray {
        need(n)
        val r = b.copyOfRange(off, off + n)
        off += n
        return r
    }

    /** PTP 字符串：u8 字符数（含 null）+ UTF-16LE 单元。 */
    fun str(): String {
        need(1)
        val n = u8()
        if (n == 0) return ""
        need(n * 2)
        val sb = StringBuilder(n)
        repeat(n) {
            val u = u16()
            if (u != 0) sb.append(u.toChar())
        }
        return sb.toString()
    }

    fun u16Array(): IntArray {
        val n = countOf(2)
        return IntArray(n) { u16() }
    }

    fun u32Array(): LongArray {
        val n = countOf(4)
        return LongArray(n) { u32() }
    }

    /**
     * 读取数组元素个数并按剩余字节数校验。个数来自对端，若直接拿去分配数组，
     * 损坏的长度（如 0x40000000）会立刻触发巨量分配。
     */
    private fun countOf(elemBytes: Int): Int {
        val n = u32()
        if (n < 0 || n > remaining / elemBytes) {
            throw WireException("数组元素个数非法（$n 个，剩余 $remaining 字节，每元素 $elemBytes 字节）")
        }
        return n.toInt()
    }
}
