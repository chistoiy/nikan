package com.nikan.nikonsync

/**
 * PTP/IP 协议常量。
 * 报文封装遵循 ISO 15740 PTP-IP：4 字节小端长度 + 4 字节小端类型 + 载荷。
 */
object Ptp {
    // ---- 包类型 ----
    const val PKT_INIT_CMD_REQ = 1
    const val PKT_INIT_CMD_ACK = 2
    const val PKT_INIT_EVT_REQ = 3
    const val PKT_INIT_EVT_ACK = 4
    const val PKT_INIT_FAIL = 5
    const val PKT_OPERATION_REQUEST = 6
    const val PKT_OPERATION_RESPONSE = 7
    const val PKT_EVENT = 8
    const val PKT_START_DATA = 9
    const val PKT_DATA = 10
    const val PKT_CANCEL_TRANSACTION = 11
    const val PKT_END_DATA = 12
    const val PKT_PROBE_REQUEST = 13
    const val PKT_PROBE_RESPONSE = 14

    // ---- 操作码 ----
    const val OP_GET_DEVICE_INFO = 0x1001
    const val OP_OPEN_SESSION = 0x1002
    const val OP_CLOSE_SESSION = 0x1003
    const val OP_GET_STORAGE_IDS = 0x1004
    const val OP_GET_STORAGE_INFO = 0x1005
    const val OP_GET_OBJECT_HANDLES = 0x1007
    const val OP_GET_OBJECT_INFO = 0x1008
    const val OP_GET_OBJECT = 0x1009
    const val OP_GET_THUMB = 0x100A
    const val OP_GET_DEVICE_PROP_DESC = 0x1014
    const val OP_GET_DEVICE_PROP_VALUE = 0x1015
    /**
     * SetDevicePropValue（**不是** SetDevicePropDesc）。
     *
     * libgphoto2 ptp.c:2824：`PTP_CNT_INIT(ptp, PTP_OC_SetDevicePropValue, propcode)`
     * —— **参数 = 属性码，数据 = 只有值本身**（按 dtype 长度编码，不带 code/dtype 前缀）。
     * 此前把 0x1016 当成 SetDevicePropDesc 用，数据里塞了 `[code][dtype][值]` 且不传参数，
     * 相机直接拒绝 —— 这就是"A/S/P 档改参数报错"的根因（同 0x90C3 / 0x90C1 那类码义错配）。
     */
    const val OP_SET_DEVICE_PROP_VALUE = 0x1016

    // 标准 PTP 0x101B = GetPartialObject：参数 3 个（句柄、偏移 u32、最大长度 u32）。
    // 注意 0x1012 是 SetObjectProtection，绝不能当分块下载用！
    const val OP_GET_PARTIAL_OBJECT = 0x101B
    // 后续功能预留的标准操作码
    const val OP_DELETE_OBJECT = 0x100B
    const val OP_INITIATE_CAPTURE = 0x100E
    const val OP_SET_OBJECT_PROTECTION = 0x1012

    // ---- 尼康厂商操作（遥控/取景/加速，能力清单已确认在支持列表中）----
    //
    // ⚠️ 2026-09-15 第三轮：本表此前有 5 处**码与语义错配**，全部按 libgphoto2 的
    // ptp.h（`docs/reference/libgphoto2/camlibs/ptp2/ptp.h` 尼康段，逐行带参数个数注释）
    // 校正。错配的后果不是"报错"而是"做了别的事"，很难从现象反推：
    //   · 0x90C3 被当成 AF 驱动 → 它其实是 DelImageSDRAM(1 参数)，无参调用必然
    //     ParameterNotSupported（真机日志原文），于是"点击取景框对焦"永远失败；
    //   · 0x90C1 被当成事件排水 → 它其实是 AF Drive！等于每次保活/拍摄都在驱动对焦；
    //   · 0x9405 被当成"取景中拍摄" → 它其实是 MeasureSpotWb（点测白平衡）；
    //   · 0x9207 被当成"相机端缩放" → 它其实是 InitiateCaptureRecInMedia（会拍摄！）。
    const val OP_NIKON_GET_LARGE_THUMB = 0x90C4
    /** AF Drive：**无参数**。取景中与盲拍都用它（旧码 0x90C3 是 DelImageSDRAM）。 */
    const val OP_NIKON_AF_DRIVE = 0x90C1
    /** DelImageSDRAM：1 参数（0x0=全部，其他=取消该图）。⚠️ 不是 AF 驱动。 */
    const val OP_NIKON_DEL_IMAGE_SDRAM = 0x90C3
    /** 取厂商事件队列：无参数，数据入（旧的 0x90C1 是 AF 驱动，不是排水）。 */
    const val OP_NIKON_GET_EVENT = 0x90C7
    /** 多参数版取事件。 */
    const val OP_NIKON_GET_EVENT_EX = 0x941C
    /** 保活探针：无参数。旧的 0x90C2 是 ChangeCameraMode(1 参数)，带 0 参必被拒。 */
    const val OP_NIKON_DEVICE_READY = 0x90C8
    const val OP_NIKON_CHANGE_CAMERA_MODE = 0x90C2
    /** AF + 拍摄到 SDRAM（无参数）。拍摄类操作，勿当探针用。 */
    const val OP_NIKON_AF_CAPTURE_SDRAM = 0x90CB
    /** 拍摄到 SDRAM（1 参数）。拍摄类操作。 */
    const val OP_NIKON_CAPTURE_REC_IN_SDRAM = 0x90C0
    // Z50 II 实测：0x9201=启动取景态（0x9403/9209 随之可用）、
    // 0x9203=取景帧（40~73KB JPEG）
    const val OP_NIKON_LV_START = 0x9201
    /** EndLiveView（无参数）。旧的 0x9206 其实是 AfDriveCancel（见下）。 */
    const val OP_NIKON_LV_END = 0x9202
    /** 旧代码沿用的 0x9206，实为 AfDriveCancel；仅作 EndLiveView 的兜底尝试。 */
    const val OP_NIKON_AF_DRIVE_CANCEL = 0x9206
    const val OP_NIKON_LV_FRAME = 0x9203
    /** MfDrive：2 参数（手动对焦焦点移动）。 */
    const val OP_NIKON_MF_DRIVE = 0x9204
    /** ChangeAfArea：2 参数（x, y）——点击取景画面指定对焦点的正解。 */
    const val OP_NIKON_CHANGE_AF_AREA = 0x9205
    /**
     * GetVendorPropCodes：无参数、数据入。
     * 返回相机支持的**全部**厂商属性码——读 AF 区域/取景相关属性前先用它确认
     * 该机型到底支持哪些码（0xD108 AutofocusArea 在本机 Wi-Fi 下就没有）。
     */
    const val OP_NIKON_GET_VENDOR_PROP_CODES = 0x90CA
    /**
     * InitiateCaptureRecInMedia：**拍摄**操作。
     * libgphoto2 注释：参数 2 个 —— 0xFFFFFFFF=拍前不对焦 / 0xFFFFFFFE=拍前对焦；
     * 第二参数 sdram=1 / card=0。取景中拍摄的兜底路径用它（拍前对焦 + 落卡）。
     */
    const val OP_NIKON_CAPTURE_REC_IN_MEDIA = 0x9207
    /**
     * GetFhdPicture：1 参数（对象句柄），返回**不超过 1920×1028** 的图片。
     * 这就是查看器"中"等画质的正解：相机端出小图，不必下载原图。
     */
    const val OP_NIKON_GET_FHD_PICTURE = 0x920F
    /** 点测白平衡（旧代码误当成"取景中拍摄"）。 */
    const val OP_NIKON_MEASURE_SPOT_WB = 0x9405

    // ---- 响应码 ----
    const val RESP_OK = 0x2001
    const val RESP_SESSION_ALREADY_OPEN = 0x201E
    const val RESP_DEVICE_BUSY = 0x2019

    // ---- 事件码 ----
    const val EVT_OBJECT_ADDED = 0x4002
    const val EVT_OBJECT_REMOVED = 0x4003
    const val EVT_STORE_ADDED = 0x4004
    const val EVT_STORE_REMOVED = 0x4005
    const val EVT_DEVICE_PROP_CHANGED = 0x4006
    /**
     * 0x400C 是 **StorageInfoChanged**（libgphoto2 ptp.h: PTP_EC_StorageInfoChanged），
     * 不是"拍摄完成"。名字此前写错，用它当"拍完"的信号会误判。
     */
    const val EVT_STORAGE_INFO_CHANGED = 0x400C

    // ---- 对象格式码 ----
    const val FMT_UNDEFINED = 0x3000
    const val FMT_ASSOCIATION = 0x3001
    const val FMT_AVI = 0x300A
    const val FMT_MOV = 0x300B
    const val FMT_MPEG = 0x300C
    const val FMT_MP4 = 0x300D
    const val FMT_JPEG_EXIF = 0x3801
    const val FMT_JPEG_JFIF = 0x380B
    const val FMT_PNG = 0x380C

    /**
     * 尼康 Wireless Mobile Utility（WMU）官方 App 在 InitCommandRequest 中
     * 硬编码的发起方 GUID。相机凭这个稳定值把客户端识别为已配对主机，
     * 跳过配对流程直接放行完整操作集。
     */
    val WMU_INITIATOR_GUID = byteArrayOf(
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88.toByte(), 0x99.toByte(), 0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte(), 0xEE.toByte(), 0xFF.toByte(),
    )

    const val PROTOCOL_VERSION_10 = 0x00010000L

    /**
     * 响应码名称（按 ISO 15740）。
     *
     * ⚠️ 这张表此前是错的：把 0x2007 标成 "ParameterBad"、0x2008 标成 "ParameterBadType"、
     * 0x2009 标成 "ValueNotSupported"、0x200A 标成 "AccessDenied" 等，都与标准不符。
     * 错误的名称会把人往错误方向带——实测中就因为 "ParameterBad" 去查了参数问题，
     * 而 0x2007 的真实含义是 IncompleteTransfer（数据阶段未按预期完成）。
     * 排查时请以标准码为准。
     */
    fun respName(code: Int): String = when (code) {
        0x2001 -> "OK"
        0x2002 -> "GeneralError"
        0x2003 -> "SessionNotOpen"
        0x2004 -> "InvalidTransactionID"
        0x2005 -> "OperationNotSupported"
        0x2006 -> "ParameterNotSupported"
        0x2007 -> "IncompleteTransfer"
        0x2008 -> "InvalidStorageId"
        0x2009 -> "InvalidObjectHandle"
        0x200A -> "DevicePropNotSupported"
        0x200B -> "InvalidObjectFormatCode"
        0x200C -> "StoreFull"
        0x200D -> "ObjectWriteProtected"
        0x200E -> "StoreReadOnly"
        0x200F -> "AccessDenied"
        0x2010 -> "NoThumbnailPresent"
        0x2013 -> "StoreNotAvailable"
        0x2019 -> "DeviceBusy"
        0x201A -> "InvalidParentObject"
        0x201B -> "InvalidDevicePropFormat"
        0x201C -> "InvalidDevicePropValue"
        0x201D -> "InvalidParameter"
        0x201E -> "SessionAlreadyOpen"
        0x201F -> "TransactionCancelled"
        // 尼康厂商响应码（0xA004 实测=未对焦；0xA00B 实测=未在实时取景）
        0xA004 -> "OutOfFocus(未对焦)"
        0xA00B -> "NotLiveView(未在取景)"
        else -> "0x%04X".format(code)
    }

    fun fmtName(code: Int): String = when (code) {
        FMT_UNDEFINED -> "RAW/Undefined"
        FMT_ASSOCIATION -> "Folder"
        FMT_AVI -> "AVI"
        FMT_MOV -> "MOV"
        FMT_MPEG -> "MPEG"
        FMT_MP4 -> "MP4"
        FMT_JPEG_EXIF -> "JPEG"
        FMT_JPEG_JFIF -> "JPEG"
        FMT_PNG -> "PNG"
        else -> "0x%04X".format(code)
    }

    fun evtName(code: Int): String = when (code) {
        0x4001 -> "CancelTransaction"
        EVT_OBJECT_ADDED -> "ObjectAdded"
        EVT_OBJECT_REMOVED -> "ObjectRemoved"
        EVT_STORE_ADDED -> "StoreAdded"
        EVT_STORE_REMOVED -> "StoreRemoved"
        EVT_DEVICE_PROP_CHANGED -> "DevicePropChanged"
        0x4007 -> "ObjectInfoChanged"
        0x4008 -> "DeviceInfoChanged"
        0x4009 -> "RequestObjectTransfer"
        0x400A -> "StoreFull"
        // ⚠️ 0x400B~0x400E 此前整体错位了两格（0x400C 被写成 CaptureComplete），
        // 后果之一：真机日志里 0x400D 被显示成 "UnreportedStatus"，掩盖了
        // "相机其实会主动上报拍摄完成" 这个事实。按 libgphoto2 ptp.h 校正。
        0x400B -> "DeviceReset"
        EVT_STORAGE_INFO_CHANGED -> "StorageInfoChanged"
        0x400D -> "CaptureComplete(拍摄完成)"
        0x400E -> "UnreportedStatus"
        0x400F -> "ObjectPropChanged"
        0x4010 -> "ObjectPropDescChanged"
        0x4011 -> "ObjectReferencesChanged"
        0xC0E2 -> "CaptureCompleteRecInSdram"
        else -> "0x%04X".format(code)
    }
}
