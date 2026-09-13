package com.nikan.nikonsync

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** GetDeviceInfo 数据集。 */
class DeviceInfo(
    val standardVersion: Int,
    val vendorExtensionId: Long,
    val vendorExtensionVersion: Int,
    val vendorExtensionDesc: String,
    val functionalMode: Int,
    val operationsSupported: IntArray,
    val eventsSupported: IntArray,
    val devicePropsSupported: IntArray,
    val manufacturer: String,
    val model: String,
    val deviceVersion: String,
    val serialNumber: String,
) {
    fun supportsOperation(op: Int): Boolean = operationsSupported.contains(op)

    fun supportsEvent(evt: Int): Boolean = eventsSupported.contains(evt)

    override fun toString(): String =
        "$manufacturer $model (v$deviceVersion, 序列号 $serialNumber, ${operationsSupported.size} 个操作, ${eventsSupported.size} 个事件)"
}

/** GetObjectInfo 数据集。 */
class ObjectInfo(
    val storageId: Long,
    val format: Int,
    val protectionStatus: Int,
    val compressedSize: Long,
    val thumbFormat: Int,
    val thumbSize: Long,
    val imageWidth: Long,
    val imageHeight: Long,
    val parentObject: Long,
    val filename: String,
    val captureDateRaw: String,
) {
    /** PTP 时间字符串 "YYYYMMDDThhmmss" → "MM-dd HH:mm:ss"。 */
    val captureDateText: String
        get() {
            if (captureDateRaw.length < 15) return captureDateRaw
            return try {
                val parsed = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US).parse(captureDateRaw) ?: return captureDateRaw
                SimpleDateFormat("MM-dd HH:mm:ss", Locale.US).format(Date(parsed.time))
            } catch (_: Exception) {
                captureDateRaw
            }
        }

    val isVideo: Boolean
        get() = format == Ptp.FMT_AVI || format == Ptp.FMT_MOV || format == Ptp.FMT_MPEG || format == Ptp.FMT_MP4 ||
            filename.endsWith(".mov", true) || filename.endsWith(".mp4", true) || filename.endsWith(".avi", true)

    val isJpeg: Boolean
        get() = format == Ptp.FMT_JPEG_EXIF || format == Ptp.FMT_JPEG_JFIF || filename.endsWith(".jpg", true) ||
            filename.endsWith(".jpeg", true)

    override fun toString(): String = "$filename ${Ptp.fmtName(format)} $compressedSize"
}

object PtpDatasets {
    fun parseDeviceInfo(data: ByteArray): DeviceInfo {
        val d = ByteReader(data)
        val standardVersion = d.u16()
        val vendorExtensionId = d.u32()
        val vendorExtensionVersion = d.u16()
        val vendorExtensionDesc = d.str()
        val functionalMode = d.u16()
        val operations = d.u16Array()
        val events = d.u16Array()
        val deviceProps = d.u16Array()
        d.u16Array() // captureFormats
        d.u16Array() // imageFormats
        val manufacturer = d.str()
        val model = d.str()
        val deviceVersion = d.str()
        val serial = try { d.str() } catch (_: Exception) { "" }
        return DeviceInfo(
            standardVersion, vendorExtensionId, vendorExtensionVersion, vendorExtensionDesc, functionalMode,
            operations, events, deviceProps, manufacturer, model, deviceVersion, serial,
        )
    }

    fun parseObjectInfo(data: ByteArray): ObjectInfo {
        val d = ByteReader(data)
        val storageId = d.u32()
        val format = d.u16()
        val protection = d.u16()
        val compressedSize = d.u32()
        val thumbFormat = d.u16()
        val thumbSize = d.u32()
        d.u32() // thumbPixWidth
        d.u32() // thumbPixHeight
        val imageWidth = d.u32()
        val imageHeight = d.u32()
        d.u32() // imageBitDepth
        val parent = d.u32()
        d.u16() // associationType
        d.u32() // associationDesc
        d.u32() // sequenceNumber
        val filename = d.str()
        val captureDate = d.str()
        return ObjectInfo(
            storageId, format, protection, compressedSize, thumbFormat, thumbSize,
            imageWidth, imageHeight, parent, filename, captureDate,
        )
    }
}
