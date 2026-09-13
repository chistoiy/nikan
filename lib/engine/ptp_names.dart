/// 标准 PTP / MTP / 已知尼康厂商操作码与事件码的名称对照。
/// 未识别的 0x9xxx 一律视为尼康厂商操作。
const Map<int, String> ptpOpNames = {
  0x1001: 'GetDeviceInfo 获取设备信息',
  0x1002: 'OpenSession 打开会话',
  0x1003: 'CloseSession 关闭会话',
  0x1004: 'GetStorageIDs 存储列表',
  0x1005: 'GetStorageInfo 存储信息',
  0x1006: 'GetFormatCodes 格式码列表',
  0x1007: 'GetObjectHandles 对象句柄枚举',
  0x1008: 'GetObjectInfo 对象信息',
  0x1009: 'GetObject 下载文件',
  0x100A: 'GetThumb 缩略图',
  0x100B: 'DeleteObject 删除文件',
  0x100C: 'SendObjectInfo 发送对象信息',
  0x100D: 'SendObject 上传文件',
  0x100E: 'InitiateCapture 拍摄（快门）',
  0x100F: 'FormatStore 格式化存储',
  0x1010: 'ResetDevice 复位设备',
  0x1011: 'SelfTest 自检',
  0x1012: 'SetObjectProtection 写保护',
  0x1013: 'PowerDown 关机',
  0x1014: 'GetDevicePropDesc 属性描述',
  0x1015: 'GetDevicePropValue 读属性',
  0x1016: 'SetDevicePropValue 写属性',
  0x1017: 'ResetDevicePropValue 复位属性',
  0x1018: 'TerminateOpenCapture 终止连续拍摄',
  0x1019: 'MoveObject 移动对象',
  0x101A: 'CopyObject 复制对象',
  0x101B: 'GetPartialObject 分块下载',
  0x101C: 'InitiateOpenCapture 连续拍摄',
  // MTP 扩展
  0x9801: 'MTP GetObjectPropsSupported 对象属性列表',
  0x9802: 'MTP GetObjectPropDesc 对象属性描述',
  0x9803: 'MTP GetObjectPropValue 读对象属性',
  0x9804: 'MTP SetObjectPropValue 写对象属性',
  0x9805: 'MTP GetObjectPropList 属性批量读取',
  0x9806: 'MTP SetObjectPropList 属性批量写入',
  0x9810: 'MTP SendObjectPropList',
  0x9811: 'MTP GetObjectReferences 对象引用',
  0x9812: 'MTP SetObjectReferences 设置对象引用',
  // 已知尼康厂商操作（开源社区逆向）
  0x90C0: 'Nikon CheckEvent 事件查询',
  0x90C1: 'Nikon GetEvent 事件数据',
  0x90C2: 'Nikon DeviceReady 就绪检查',
  0x90C3: 'Nikon SetControlMode 控制模式',
  0x90C4: 'Nikon GetLargeThumb 大缩略图',
  0x9407: 'Nikon SetTransferListLock 传输队列锁定',
  0x9408: 'Nikon GetTransferList 读取传输队列',
};

/// 未在对照表中的 0x9000+ 视为尼康厂商操作
String opName(int code) =>
    ptpOpNames[code] ?? (code >= 0x9000 ? 'Nikon 厂商操作' : '未知操作');

const Map<int, String> ptpEvtNames = {
  0x4001: 'CancelTransaction 事务取消',
  0x4002: 'ObjectAdded 新对象',
  0x4003: 'ObjectRemoved 对象删除',
  0x4004: 'StoreAdded 存储加入',
  0x4005: 'StoreRemoved 存储移除',
  0x4006: 'DevicePropChanged 属性变化',
  0x4007: 'ObjectInfoChanged 对象信息变化',
  0x4008: 'DeviceInfoChanged 设备信息变化',
  0x4009: 'RequestObjectTransfer 请求传输',
  0x400A: 'StoreFull 存储已满',
  0x400B: 'StorageInfoChanged 存储信息变化',
  0x400C: 'CaptureComplete 拍摄完成',
  0x400D: 'UnreportedStatus 状态上报',
  0x400E: 'ObjectPropChanged 对象属性变化',
  0x400F: 'ObjectPropDescChanged 属性描述变化',
  0x4010: 'ObjectReferencesChanged 对象引用变化',
};

String evtName(int code) => ptpEvtNames[code] ?? '厂商事件';

const Map<int, String> ptpPropNames = {
  0x5001: 'BatteryLevel 电量',
  0x5003: 'ImageSize 图像尺寸',
  0x5007: 'WhiteBalance 白平衡',
  0x500D: 'FNumber 光圈值',
  0x500E: 'ExposureTime 曝光时间',
  0x500F: 'ExposureIndex ISO',
  0xD303: 'MTP 传输协议',
};
