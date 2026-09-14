import 'dart:async';

import 'package:flutter/services.dart';

/// 相机引擎的 Flutter 侧封装。
///
/// 指令走 MethodChannel "nikonsync/engine"，
/// 事件（日志/进度/相机事件/状态）走 EventChannel "nikonsync/events"。
class NikonEngine {
  static const MethodChannel _m = MethodChannel('nikonsync/engine');
  static const EventChannel _e = EventChannel('nikonsync/events');

  static Stream<dynamic> events() => _e.receiveBroadcastStream();

  static Future<Map<String, dynamic>> _map(String method, [Map<String, dynamic>? args]) async {
    final r = await _m.invokeMethod(method, args ?? const {});
    return (r as Map).cast<String, dynamic>();
  }

  static Future<Map<String, dynamic>> wifiInfo() => _map('wifiInfo');

  /// 应用版本（原生侧读 BuildConfig，与 pubspec 不会失同步）
  static Future<String?> appVersion() async =>
      await _m.invokeMethod('appVersion') as String?;

  static Future<void> openWifiSettings() => _m.invokeMethod('openWifiSettings');

  static Future<List<String>> scan() async {
    final r = await _m.invokeMethod('scan');
    return List<String>.from(r as List);
  }

  static Future<Map<String, dynamic>> connect(String ip, String friendlyName) =>
      _map('connect', {'ip': ip, 'friendlyName': friendlyName});

  /// 智能连接：直接对网关（相机）握手 + 重试，失败才网段扫描兜底
  static Future<Map<String, dynamic>> connectSmart() => _map('connectSmart');

  static Future<void> disconnect() => _m.invokeMethod('disconnect');

  static Future<Map<String, dynamic>> enumerate() => _map('enumerate');

  static Future<List<Map<String, dynamic>>> objectInfo(List<int> handles) async {
    final r = await _m.invokeMethod('objectInfo', {'handles': handles});
    return (r as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 快速枚举：只拿目录树句柄（秒级），详情/缩略图按需拉取
  static Future<Map<String, dynamic>> listFolders() => _map('listFolders');

  static Future<Map<String, dynamic>> fileInfo(int handle) => _map('fileInfo', {'handle': handle});

  static Future<Map<String, dynamic>> fileView(int handle) => _map('fileView', {'handle': handle});

  static Future<Uint8List> thumbnail(int handle) async {
    final r = await _m.invokeMethod('getThumbnail', {'handle': handle});
    return r as Uint8List;
  }

  static Future<int> battery() async {
    final r = await _m.invokeMethod('battery');
    return (r as num).toInt();
  }

  /// 相机能力清单（需已连接）：操作码/事件码/属性码原始列表
  static Future<Map<String, dynamic>> capabilities() => _map('capabilities');

  static Future<Map<String, dynamic>> download(
    int handle,
    String fileName,
    int size, {
    String variant = 'original',
  }) =>
      _map('download', {'handle': handle, 'fileName': fileName, 'size': size, 'variant': variant});

  static Future<void> deleteObject(int handle) => _m.invokeMethod('deleteObject', {'handle': handle});

  static Future<void> protectObject(int handle, {bool protect = true}) =>
      _m.invokeMethod('protectObject', {'handle': handle, 'protection': protect ? 1 : 0});

  // ---- 遥控拍摄 / 实时取景 ----

  static Future<void> liveViewStart() => _m.invokeMethod('liveViewStart');

  static Future<void> liveViewStop() => _m.invokeMethod('liveViewStop');

  static Future<Uint8List> liveViewFrame() async {
    final r = await _m.invokeMethod('liveViewFrame');
    return r as Uint8List;
  }

  /// 遥控快门（拍到卡上）
  static Future<void> capture() => _m.invokeMethod('capture');

  /// 手动触发一次 AF 对焦
  static Future<bool> afDrive() async {
    final r = await _m.invokeMethod('afDrive');
    return r == true;
  }

  /// 取景中拍摄（0x100E 优先，忙则 AF 探测回退）
  static Future<void> lvCapture() => _m.invokeMethod('lvCapture');

  /// 取景中 AF/拍摄通道探针
  static Future<List<String>> probeLvAf(int handle) async {
    final r = await _m.invokeMethod('probeLvAf', {'handle': handle});
    return List<String>.from(r as List);
  }

  /// 当前拍摄参数（光圈/快门/ISO/电量）
  static Future<Map<String, dynamic>> shotParams() => _map('shotParams');

  // ---- 保存位置（SAF） ----

  static Future<String?> getSaveFolder() async => await _m.invokeMethod('getSaveFolder') as String?;

  static Future<void> clearSaveFolder() => _m.invokeMethod('clearSaveFolder');

  static Future<String?> pickSaveFolder() async => await _m.invokeMethod('pickSaveFolder') as String?;

  // ---- 协议探针（调试） ----

  static Future<List<String>> probeHiSpeed(int handle) async {
    final r = await _m.invokeMethod('probeHiSpeed', {'handle': handle});
    return List<String>.from(r as List);
  }

  static Future<List<String>> probeResize(int handle) async {
    final r = await _m.invokeMethod('probeResize', {'handle': handle});
    return List<String>.from(r as List);
  }

  static Future<List<String>> probeLiveView() async {
    final r = await _m.invokeMethod('probeLiveView');
    return List<String>.from(r as List);
  }

  /// 实时取景链路探针（0x9206 疑似 Start → 0x9403~06 拉帧 → 0x9201 疑似 End）
  static Future<List<String>> probeLiveView2() async {
    final r = await _m.invokeMethod('probeLiveView2');
    return List<String>.from(r as List);
  }

  /// 取景帧尺寸探针：候选帧通道逐个尝试，报告字节数与 JPEG 像素尺寸。
  /// 用于判断是否存在比 0x9203（实测 640×424）更大的取景帧。
  static Future<List<String>> probeLvFrames() async {
    final r = await _m.invokeMethod('probeLvFrames');
    return List<String>.from(r as List);
  }

  /// USB 连接模式 U0 实验：枚举设备 → 打开会话 → 读操作集 → 实测吞吐。
  /// 需要用户在系统弹窗里点一次授权，因此原生侧是长任务（最长等 60 秒）。
  static Future<List<String>> usbProbe() async {
    final r = await _m.invokeMethod('usbProbe');
    return List<String>.from(r as List);
  }

  /// 取景中候选操作响应码全量探针
  static Future<List<String>> probeLiveView3(int handle) async {
    final r = await _m.invokeMethod('probeLiveView3', {'handle': handle});
    return List<String>.from(r as List);
  }

  /// 取景状态机完整探索（含 0x9400 对焦后行为、双向状态翻转、数据头 hex）
  static Future<List<String>> probeLiveView4(int handle) async {
    final r = await _m.invokeMethod('probeLiveView4', {'handle': handle});
    return List<String>.from(r as List);
  }

  /// 取景热身轮询：等待 0x9403/0x9203 出帧，含取景中 AF 与 0x9405 拍摄测试
  static Future<List<String>> probeLiveView5(int handle) async {
    final r = await _m.invokeMethod('probeLiveView5', {'handle': handle});
    return List<String>.from(r as List);
  }

  // ---- 本地已下载媒体 ----

  static Future<Uint8List?> mediaThumb(String uri) async {
    final r = await _m.invokeMethod('mediaThumb', {'uri': uri});
    if (r == null) return null;
    return r as Uint8List;
  }

  static Future<bool> mediaDelete(String uri) async {
    final r = await _m.invokeMethod('mediaDelete', {'uri': uri});
    return r == true;
  }

  static Future<bool> openMedia(String uri) async {
    final r = await _m.invokeMethod('openMedia', {'uri': uri});
    return r == true;
  }

  /// 拉取对象原始字节（大图查看，JPEG ≤40MB）
  static Future<Uint8List> fetchObject(int handle, int size) async {
    final r = await _m.invokeMethod('fetchObject', {'handle': handle, 'size': size});
    return r as Uint8List;
  }

  /// 读取本地媒体完整字节（查看器用）
  static Future<Uint8List> mediaBytes(String uri) async {
    final r = await _m.invokeMethod('mediaBytes', {'uri': uri});
    return r as Uint8List;
  }

  /// 按文件名找回本地媒体 uri（修复旧记录），找不到返回 null
  static Future<String?> findMediaByName(String name) async {
    final r = await _m.invokeMethod('findMediaByName', {'name': name});
    return r as String?;
  }
}
