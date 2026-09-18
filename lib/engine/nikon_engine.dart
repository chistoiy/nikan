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

  /// USB 连接（实测 27.1 MB/s，Wi-Fi 的 11 倍）。会弹系统 USB 权限对话框。
  static Future<Map<String, dynamic>> connectUsb(String friendlyName) =>
      _map('connectUsb', {'friendlyName': friendlyName});

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

  /// 存储卡信息：`{cards: [...], primary: {maxBytes, freeBytes, freeImages, label}}`
  static Future<Map<String, dynamic>> storageInfo() => _map('storageInfo');

  /// 轻量预览（查看器默认路径）。
  /// [quality]：low=大缩略图(~1600px) / medium=相机端 FHD 图(≤1920×1028)。
  /// 返回 `{bytes, quality(实际生效), fallback?, note?}`——medium 不被支持时
  /// 会回退 low 并在 `quality` 里如实反映，不会静默给原图。
  static Future<Map<String, dynamic>> previewBytes(int handle, String quality) =>
      _map('previewBytes', {'handle': handle, 'quality': quality});

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

  /// 请求取消当前下载。
  ///
  /// 真正的中断发生在**原生分块边界**：`getObjectToStream` 是一次阻塞调用，Dart 侧的
  /// 取消回调传不进它的循环内部，所以必须让 Kotlin 侧自己去中断（见
  /// `CameraEngine.cancelDownload`）。这里只负责把请求送过去，立即返回。
  static Future<bool> cancelDownload() async {
    final r = await _m.invokeMethod('cancelDownload');
    return r == true;
  }

  /// 申请通知权限（仅 Android 13+ 需要）。
  ///
  /// Manifest 里一直声明着 POST_NOTIFICATIONS，但代码从没运行时申请过，
  /// 于是保活前台服务的通知在 13+ 上完全不可见——用户不知道后台在跑，
  /// "下载进度通知栏"这类依赖它的功能也无从谈起。
  /// 返回 true = 已有权限或系统不需要；false = 已弹出授权框，结果待用户决定。
  static Future<bool> requestNotificationPermission() async {
    final r = await _m.invokeMethod('requestNotificationPermission');
    return r == true;
  }

  /// 无线链路基准测速（只读）：把指定文件真传一遍但丢弃数据，报告
  /// 平均吞吐、最慢区间、当前频段（2.4/5GHz）与协商速率，并给出"还有没有空间"的判读。
  ///
  /// 用途：同一张卡文件在「相机 AP 模式」与「相机 STA 模式（接入 5GHz 路由器）」各跑一次，
  /// 就能判断瓶颈在 2.4GHz 频段、还是在相机自身的实现上。耗时与一次真实下载相同。
  static Future<List<String>> probeLinkThroughput(int handle) async {
    final r = await _m.invokeMethod('probeLinkThroughput', {'handle': handle});
    return List<String>.from(r as List);
  }

  /// 最近一次通过 USB 接入的相机名（无则 null）。
  ///
  /// 插入相机会把应用拉起来，但那一刻事件通道可能还没建好、事件会丢，
  /// 所以连接页初始化时主动查一次而不是只等事件。
  static Future<String?> lastUsbAttach() async {
    final r = await _m.invokeMethod('lastUsbAttach');
    return r as String?;
  }

  /// 清掉"已提示过 USB 接入"的标记。
  static Future<void> clearUsbAttach() => _m.invokeMethod('clearUsbAttach');

  static Future<void> protectObject(int handle, {bool protect = true}) =>
      _m.invokeMethod('protectObject', {'handle': handle, 'protection': protect ? 1 : 0});

  // ---- 遥控拍摄 / 实时取景 ----

  static Future<void> liveViewStart() => _m.invokeMethod('liveViewStart');

  /// 强制重进取景（先 0x9202 结束、再 0x9201 启动，忽略缓存的取景标志）。
  /// 用于"相机报 NotLiveView 但其实没真退出"的半死状态——只重复发 0x9201 无效。
  static Future<void> liveViewRestart() => _m.invokeMethod('liveViewRestart');

  static Future<void> liveViewStop() => _m.invokeMethod('liveViewStop');

  static Future<Uint8List> liveViewFrame() async {
    final r = await _m.invokeMethod('liveViewFrame');
    return r as Uint8List;
  }

  /// 遥控快门（拍到卡上）
  static Future<void> capture() => _m.invokeMethod('capture');

  /// 手动触发一次 AF 对焦（不指定区域，用相机当前 AF 区域）。
  /// 返回 `{ok, reason}`：失败时 reason 是相机给出的响应码说明。
  static Future<Map<String, dynamic>> afDrive() => _map('afDrive');

  /// 指定对焦区域并驱动 AF（点击取景画面）。
  /// 返回 `{ok, area(是否成功指定区域), reason, areaError?}`。
  static Future<Map<String, dynamic>> afArea(int x, int y) =>
      _map('afArea', {'x': x, 'y': y});

  /// 取景中拍摄（0x100E 优先，忙则 AF 探测回退）
  static Future<void> lvCapture() => _m.invokeMethod('lvCapture');

  /// 取景中 AF/拍摄通道探针
  static Future<List<String>> probeLvAf(int handle) async {
    final r = await _m.invokeMethod('probeLvAf', {'handle': handle});
    return List<String>.from(r as List);
  }

  /// 取景对焦坐标标定探针（需已在取景态）：厂商属性码清单 + AF 相关属性描述 +
  /// 两种候选缩放下"画面 1/4 处"的 0x9205 试探，用于确定 ChangeAfArea 的坐标空间。
  static Future<List<String>> probeAfArea(int frameW, int frameH) async {
    final r = await _m.invokeMethod('probeAfArea', {'frameW': frameW, 'frameH': frameH});
    return List<String>.from(r as List);
  }

  /// 休眠/自动关机属性探针：读出 LCD关闭/测光关闭/自动关机 的取值表，
  /// 以及息屏后 DeviceReady 是否仍应答（判断"能不能从 App 唤醒相机"）。
  static Future<List<String>> probeSleep() async {
    final r = await _m.invokeMethod('probeSleep');
    return List<String>.from(r as List);
  }

  /// 实时 ISO 发现探针（差分法，约 15 秒）：找出随 Auto ISO 变化的属性，
  /// 用于解决"相机显示 ISO AUTO 2500、App 停在 2000"的问题。
  static Future<List<String>> probeLiveIso() async {
    final r = await _m.invokeMethod('probeLiveIso');
    return List<String>.from(r as List);
  }

  /// 取景帧头部解出的**自动对焦倍数**（相机图像尺寸 ÷ 取景帧尺寸，x/y 各一个）。
  /// 返回 `{ok, scaleX, scaleY, info}`；ok=false 表示头部未解析出来，需人工标定。
  static Future<Map<String, dynamic>> afScaleFromHeader() => _map('afScaleFromHeader');

  /// 取景帧头部完整 dump（调试面板用）：384 字节逐字段，用于定位实时 ISO/光圈/快门。
  static Future<List<String>> probeLvHeader() async {
    final r = await _m.invokeMethod('probeLvHeader');
    return List<String>.from(r as List);
  }

  /// 遥控期间保持相机屏幕常亮：把 LCD 关闭 / 测光关闭 时间写到相机允许的最大值，
  /// 记住原值；退出遥控时用 `enable: false` 还原。
  /// 返回 `{ok, changed, failed, note}`——相机不允许修改时如实上报，不假装成功。
  static Future<Map<String, dynamic>> keepAwake(bool enable) =>
      _map('keepAwake', {'enable': enable});

  /// 息屏后尝试唤醒相机（0x90C8 DeviceReady）。返回是否拿到应答。
  static Future<bool> wakeUp() async {
    final r = await _m.invokeMethod('wakeUp');
    return r == true;
  }

  /// 防待机"戳一下"（实验）：DeviceReady + 重发上次对焦点，无副作用。
  /// 用于试探相机能否因为协议活动而不进入待机。
  static Future<Map<String, dynamic>> pokeActivity() => _map('pokeActivity');

  /// 把一行 Dart 侧日志写进 logcat（release 包里 UI 日志原本只存在于应用内面板，
  /// 真机排查界面问题时外部拿不到任何证据）。
  static Future<void> logToNative(String line) =>
      _m.invokeMethod('logToNative', {'line': line});

  /// 当前拍摄参数（光圈/快门/ISO/电量）
  static Future<Map<String, dynamic>> shotParams() => _map('shotParams');

  /// 设置拍摄参数（光圈/快门/ISO，数据外发 SetDevicePropDesc）
  static Future<Map<String, dynamic>> setShotParam(String name, int value) =>
      _map('setShotParam', {'name': name, 'value': value});

  /// 设备属性码 Dump（调试面板）：确认 Wi-Fi 方言的档位属性码
  static Future<List<String>> probeProps() async {
    final r = await _m.invokeMethod('probeProps');
    return List<String>.from(r as List);
  }

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

  /// 在线取原图（**不落盘**）且**持续上报进度**：
  /// 返回 `{bytes, bytesWritten, ms, speedMBps}`，过程中通过 `progress` 事件
  /// 上报 `received/total/speedMBps`。大图页在"不保存到手机"设置下走这里——
  /// 有进度条才知道是在下载还是已经卡住（旧的无进度取图只能一直转圈）。
  static Future<Map<String, dynamic>> fetchOriginal(int handle, int size) =>
      _map('fetchOriginal', {'handle': handle, 'size': size});

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
