import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine/app_log.dart';
import 'engine/camera_gateway.dart';
import 'engine/nikon_engine.dart';
import 'engine/settings_store.dart';
import 'models/camera_file.dart';
import 'models/pair_linker.dart';

/// "扫描附近热点"权限的申请结果。
///
/// 必须是三态而不是布尔：`denied`（用户明确拒绝，可以再弹一次）与
/// `blocked`（已问过、系统不再弹框，只能去应用设置）的引导完全不同。
enum WifiScanPerm {
  /// 已持有权限，可以扫描
  granted,

  /// 用户刚刚明确拒绝
  denied,

  /// 系统不会（或无法）再弹授权框，只能引导去应用设置手动开
  blocked,
}

/// "加入相机热点"这一步失败（凭据缺失 / 密码不对 / 用户在系统框里取消）。
///
/// 为什么单独成形：这是**最常见的失败**，而且它有三条完全不同的出路
/// （填密码 / 去系统设置连一次 / 再试一次），成败全靠引导是否对症。
/// 混在一条 `Exception('已加入热点「X」，但连接相机失败：…')` 里会**把归因说反**
/// ——明明没连上，却告诉用户"已加入热点"（真机实测踩到）。
class ApJoinException implements Exception {
  ApJoinException(this.ssid, this.reason, {required this.hadPassword});

  final String ssid;

  /// 原生给出的具体原因（已含可行动的建议）
  final String reason;

  /// 这次是否带着密码去连的：带了还失败 ⇒ 密码可疑；没带 ⇒ 手机里没这个热点。
  /// 两条路的引导不同，所以要分开。
  final bool hadPassword;

  String get hint => hadPassword
      ? '相机热点密码可能不对（密码在相机屏幕上：网络菜单 → 连接至智能设备 → Wi-Fi 连接）。'
          '也可以重新填一次正确的密码再试。'
      : '本应用还不知道这个热点的密码。你在系统 Wi-Fi 里输过的密码，'
          '本应用读不到（Android 禁止应用读取系统保存的 Wi-Fi 密码），'
          '所以需要二选一：\n'
          '① 在本应用里填一次（推荐：存下之后「一键连接」全自动，再也不用输）；\n'
          '② 打开系统 Wi-Fi 面板手动点一下相机热点——注意：免密，但每次连接都要点，'
          '系统不会替你自动完成。';

  @override
  String toString() => reason;
}

/// 全局应用状态：连接、文件列表、按需索引、下载、设置。
class AppModel extends ChangeNotifier {
  AppModel() {
    // 原生事件唯一入口：转发到广播流（各页面订阅）与全局日志，
    // 避免多页面各自订阅导致事件通道互相抢占/清空。
    _sub = NikonEngine.events().listen((e) {
      _onEvent(e);
      _eventCtrl.add(e);
    });
    gateway.records.load().then((_) => notifyListeners());
    settings.load().then((_) {
      // 读不到热点名的档案（本机 Wi-Fi 侧就是读不到）在启动时用相机自身上报的
      // 数据补一次推定热点名——否则副标题永远空着、"一键连接"也不会出现。
      final n = settings.backfillDerivedSsid();
      if (n > 0) {
        AppLog.addKey('按相机序列号补全了 $n 台相机的推定热点名');
        unawaited(settings.save());
      }
      notifyListeners();
    });
    gateway.onFileUpdated = _notifyThrottled;
    // 下载记录变化也要驱动重建：否则删除后列表要等下一次引擎通知才刷新
    gateway.records.addListener(_notifyThrottled);
    NikonEngine.getSaveFolder().then((v) {
      saveFolderUri = v;
      notifyListeners();
    });
  }

  Timer? _notifyTimer;
  bool _notifyPending = false;

  /// 节流通知。后台索引会为每个文件触发一次回调，直接 notifyListeners 等于
  /// 按文件数重建所有页面（几千张照片 = 几千次全页重建 + 排序）。
  /// 状态本身是实时读取的，最后一次变更必定会被渲染，只是最多延迟 150ms。
  void _notifyThrottled() {
    if (_notifyPending) return;
    _notifyPending = true;
    _notifyTimer = Timer(const Duration(milliseconds: 150), () {
      _notifyPending = false;
      notifyListeners();
    });
  }

  final StreamController<dynamic> _eventCtrl = StreamController<dynamic>.broadcast();

  /// 原生事件广播流（日志/进度/相机事件/连接状态）
  Stream<dynamic> get events => _eventCtrl.stream;

  final NikonEngine engine = NikonEngine();
  late final CameraGateway gateway = CameraGateway();
  final SettingsStore settings = SettingsStore();
  StreamSubscription<dynamic>? _sub;

  // ---- 设置 ----
  String? saveFolderUri; // null = 系统相册 Pictures/NikonSync

  String get downloadVariant => settings.downloadVariant;
  bool get deleteAfterDownload => settings.deleteAfterDownload;
  String get sortMode => settings.sortMode;

  /// 大图查看器默认画质：low / medium / original（默认 medium）
  String get viewerQuality => settings.viewerQuality;

  Future<void> setViewerQuality(String v) async {
    settings.viewerQuality = v;
    await settings.save();
    notifyListeners();
  }

  /// 大图页点「显示原图」时是否顺带保存到手机（默认关）
  bool get viewerSaveOriginal => settings.viewerSaveOriginal;

  Future<void> setViewerSaveOriginal(bool v) async {
    settings.viewerSaveOriginal = v;
    await settings.save();
    notifyListeners();
  }

  /// 取景点击对焦的坐标缩放（见 SettingsStore.afAreaScale）
  double get afAreaScale => settings.afAreaScale;

  Future<void> setAfAreaScale(double v) async {
    settings.afAreaScale = v;
    await settings.save();
    notifyListeners();
  }

  /// RAW+JPEG 成对联动（见 SettingsStore.linkRawJpegPairs）
  bool get linkRawJpegPairs => settings.linkRawJpegPairs;

  Future<void> setLinkRawJpegPairs(bool v) async {
    settings.linkRawJpegPairs = v;
    await settings.save();
    notifyListeners();
  }

  // ---- 大图页原图加载进度 ----
  //
  // 两条路径（仅查看 / 顺带保存）都会把进度写进这几项。有进度条才说得清
  // "是在下载还是卡住了"——此前只有一个转圈指示，转 30 秒用户只能干等。
  bool originalLoading = false;
  bool originalSaving = false; // true = 同时在保存到手机（文案不同）
  double originalFrac = 0;
  double originalSpeed = 0;
  int originalReceived = 0;
  int originalTotal = 0;

  void beginOriginalLoad({required bool saving, int totalBytes = 0}) {
    originalLoading = true;
    originalSaving = saving;
    originalFrac = 0;
    originalSpeed = 0;
    originalReceived = 0;
    originalTotal = totalBytes;
    notifyListeners();
  }

  void endOriginalLoad() {
    originalLoading = false;
    originalSaving = false;
    originalFrac = 0;
    originalSpeed = 0;
    originalReceived = 0;
    originalTotal = 0;
    notifyListeners();
  }

  // ---- 存储卡状态 ----
  /// 相机存储卡摘要（连接后自动拉取）：{freeBytes, freeImages, maxBytes, label}
  Map<String, dynamic>? storage;
  List<Map<String, dynamic>> storageCards = [];

  Future<void> refreshStorage() async {
    if (connState != 'connected') return;
    try {
      final r = await NikonEngine.storageInfo();
      final cards = ((r['cards'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      storageCards = cards;
      storage = (r['primary'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      storage = null;
    }
    notifyListeners();
  }

  /// 卡剩余容量的可读文案（无数据时返回空串）
  String get storageText {
    final s = storage;
    if (s == null) return '';
    final free = (s['freeBytes'] as num?)?.toDouble() ?? 0;
    final imgs = (s['freeImages'] as num?)?.toInt() ?? 0;
    if (free <= 0) return '';
    final gb = free / (1024 * 1024 * 1024);
    final size = gb >= 1 ? '${gb.toStringAsFixed(1)}GB' : '${(free / (1024 * 1024)).round()}MB';
    return '卡剩余 $size${imgs > 0 ? ' · 可拍 $imgs 张' : ''}';
  }

  Future<void> setDownloadVariant(String v) async {
    settings.downloadVariant = v;
    await settings.save();
    notifyListeners();
  }

  Future<void> setDeleteAfterDownload(bool v) async {
    settings.deleteAfterDownload = v;
    await settings.save();
    notifyListeners();
  }

  Future<void> setSortMode(String v) async {
    settings.sortMode = v;
    await settings.save();
    notifyListeners();
  }

  Future<void> pickSaveFolder() async {
    final uri = await NikonEngine.pickSaveFolder();
    if (uri != null) {
      saveFolderUri = uri;
      notifyListeners();
    }
  }

  Future<void> clearSaveFolder() async {
    await NikonEngine.clearSaveFolder();
    saveFolderUri = null;
    notifyListeners();
  }

  // ---- 连接 ----
  String connState = 'disconnected'; // connecting / connected / disconnected
  String? connError;
  Map<String, dynamic>? cameraInfo;
  int battery = -1;
  Map<String, dynamic>? wifi;
  List<String> foundCameras = [];
  bool scanning = false;

  /// 自动重连进度（原生在意外断开后自行重试时上报）。
  /// attempt > 0 表示"连接中"是重连，而不是用户主动连接——UI 据此区分文案。
  int reconnectAttempt = 0;
  int reconnectTotal = 0;
  int reconnectNextMs = 0;
  String? reconnectReason;

  // ---- 链路健康：相机活性 + Wi-Fi 信号 ----
  //
  // 用户遇到的困惑很具体：「不知道是卡住了、相机断开了、还是别的原因」。
  // 只显示"已连接"回答不了这个问题，所以这里给两组可感知的证据：
  // 1）Wi-Fi 信号强度（RSSI/格数/链路速率）——链路层面；
  // 2）相机的活性（距上次收到相机消息多久、保活探针往返耗时）——协议层面。
  // 空闲 60s 无消息是正常的（相机本就 3~60s 才推一次属性），但探针必须答得上。
  String transport = 'wifi'; // wifi / usb（USB 无 Wi-Fi 信号可测）
  int camIdleMs = -1; // 距上次收到相机消息（-1 = 本会话还没收到过）
  int camRttMs = -1; // 最近一次保活探针往返耗时（-1 = 还没探过）
  bool camProbeOk = true; // 最近一次探针是否成功（复探成功也算成功）
  int wifiRssi = 0; // dBm；0 = 无数据
  int wifiLevel = -1; // 0~4 格；-1 = 无数据
  int wifiLinkSpeed = 0; // Mbps

  Timer? _signalTimer;

  void _startSignalWatch() {
    _signalTimer?.cancel();
    _signalTimer = Timer.periodic(const Duration(seconds: 4), (_) => _tickSignal());
    unawaited(_tickSignal());
  }

  void _stopSignalWatch() {
    _signalTimer?.cancel();
    _signalTimer = null;
    camIdleMs = -1;
    camRttMs = -1;
    camProbeOk = true;
    wifiLevel = -1;
    wifiRssi = 0;
    wifiLinkSpeed = 0;
  }

  /// 每 4 秒刷新一次 Wi-Fi 信号（顺带驱动"距上次消息 N 秒"的文案刷新）
  Future<void> _tickSignal() async {
    if (connState != 'connected') return;
    if (transport == 'usb') {
      // USB 没有 Wi-Fi 信号可测：不要拿当前家庭 Wi-Fi 的格数冒充相机链路
      notifyListeners();
      return;
    }
    try {
      final w = await NikonEngine.wifiInfo();
      wifi = w;
      wifiRssi = (w['rssi'] as num?)?.toInt() ?? 0;
      wifiLevel = (w['signalLevel'] as num?)?.toInt() ?? -1;
      wifiLinkSpeed = (w['linkSpeed'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    notifyListeners();
  }

  /// Wi-Fi 信号的可读文案（无数据时如实说明，不猜）
  String get wifiSignalText {
    if (wifiLevel < 0) return '无数据';
    final dbm = wifiRssi < 0 ? ' · $wifiRssi dBm' : '';
    final quality = switch (wifiLevel) {
      4 => '很强',
      3 => '良好',
      2 => '一般',
      1 => '较弱',
      _ => '很弱',
    };
    return '$wifiLevel/4 格（$quality）$dbm';
  }

  /// 立即刷新一次链路健康（详情面板的「立即检测」）
  Future<void> refreshSignal() => _tickSignal();

  /// 一句话链路诊断（点 AppBar 的信号图标可见详情）
  String get linkHealthText {
    if (connState == 'connected') {
      final rtt = camRttMs >= 0 ? '响应 $camRttMs ms' : '等待相机响应…';
      if (!camProbeOk) return '相机未响应，正在确认…';
      final s = camIdleMs >= 0 ? (camIdleMs / 1000).round() : -1;
      if (s < 0) return '已连接 · $rtt';
      if (s <= 12) return '已连接 · $rtt';
      if (s <= 90) return '相机空闲 ${s}s（无新消息，正常）';
      return '已 ${s}s 未收到相机消息';
    }
    if (connState == 'connecting') return connStateText;
    return '未连接相机';
  }

  void _clearReconnect() {
    reconnectAttempt = 0;
    reconnectTotal = 0;
    reconnectNextMs = 0;
    reconnectReason = null;
  }

  // ---- 文件 ----
  List<CameraFile> files = [];
  bool loadingFiles = false;
  String? filesError;
  bool hasNewPhotos = false;
  int get indexedCount => files.where((f) => f.infoLoaded).length;
  bool get indexingDone => files.isNotEmpty && indexedCount == files.length;

  // ---- 下载 ----
  bool downloading = false;
  bool cancelRequested = false;
  int dlDone = 0;
  int dlTotal = 0;
  double dlFileFrac = 0;
  double dlSpeed = 0;
  String dlCurrentName = '';
  String? dlResult;

  /// 本次（或最近一次）下载中**跳过/失败的具体文件与原因**。
  ///
  /// 以前只有一个汇总串（"失败 3"），用户既不知道是哪几张、也不知道为什么，
  /// 更没法重试——而那几张往往正是他最想要的。现在逐条留证，并支持一键重试。
  /// 元素形如 `(handle: 123, name: 'DSC_0001.JPG', reason: '下载失败：...')`。
  final List<({int handle, String name, String reason})> dlIssues = [];

  /// 上次下载里**真的失败**的那几张（用于重试）。
  ///
  /// 只挑失败项：把"已下载过，跳过"也算进来的话，重试等于白转一圈又跳过一遍。
  List<CameraFile> failedDownloadFiles() {
    final byHandle = {for (final f in files) f.handle: f};
    return [
      for (final i in dlIssues)
        if (i.reason.contains('失败') && byHandle[i.handle] != null) byHandle[i.handle]!,
    ];
  }

  bool get isDownloadReady => connState == 'connected';

  /// 连接态文案（相册页/遥控页的断开占位共用）。
  /// 区分"用户主动连接中"与"意外断开后的自动重连"，否则两种情况都只说一句
  /// "连接已断开"，用户既不知道发生了什么，也不知道该等还是该手动重连。
  String get connStateText {
    if (connState == 'connected') return '已连接';
    if (connState == 'connecting' && reconnectAttempt > 0) {
      return '连接已断开，正在自动重连（第 $reconnectAttempt/$reconnectTotal 次）';
    }
    if (connState == 'connecting') return '正在连接相机…';
    return '连接已断开';
  }

  bool isDownloaded(CameraFile f) => gateway.records.contains(f.name, f.size);

  // ------------------------------------------------------------ 连接

  Future<void> refreshWifi() async {
    wifi = await NikonEngine.wifiInfo();
    notifyListeners();
  }

  Future<void> openWifiSettings() => NikonEngine.openWifiSettings();

  // ------------------------------------------------------------ USB 接入提示

  /// 检测到的 USB 接入提示（连接页显示）。null = 无提示。
  String? usbAttachNotice;

  /// 主动查询原生侧记录的 USB 接入。
  ///
  /// 插入相机时系统会带着 USB_DEVICE_ATTACHED 拉起应用，但那一刻事件通道可能
  /// **还没建立**，事件会丢——所以连接页初始化时补查一次，否则这个提示时灵时不灵。
  Future<void> pollUsbAttach() async {
    try {
      // 两条路都要走：先看系统有没有投递过接入 Intent（冷启动那条），
      // 再**主动查 USB 总线上有没有相机**——多数 ROM（HyperOS 实测）不会把
      // ATTACHED Intent 投给非"默认处理程序"的应用，只等它的话表现就是
      // "插上相机，App 里毫无反应，还得手动点连接"（真机反馈原文）。
      var name = await NikonEngine.lastUsbAttach();
      name ??= await NikonEngine.usbCameraPresent();
      if (name != null && usbAttachNotice == null) {
        usbAttachNotice = name;
        notifyListeners();
        // 冷启动/主动探测路径：同样按设置自动连一次
        unawaited(_autoConnectUsb(name));
      }
    } catch (_) {}
  }

  /// 用户已看到提示，清掉（原生侧一并清，避免每次进连接页都再提示一次）。
  Future<void> dismissUsbAttach() async {
    if (usbAttachNotice == null) return;
    usbAttachNotice = null;
    notifyListeners();
    try {
      await NikonEngine.clearUsbAttach();
    } catch (_) {}
  }

  /// 申请通知权限（Android 13+ 需要）。失败不影响连接，只是没有保活通知。
  Future<void> ensureNotificationPermission() async {
    try {
      await NikonEngine.requestNotificationPermission();
    } catch (_) {}
  }

  // ------------------------------------------------- 记住设备与自动连接

  bool get autoConnectWifi => settings.autoConnectWifi;
  bool get autoConnectUsb => settings.autoConnectUsb;

  Future<void> setAutoConnectWifi(bool v) async {
    settings.autoConnectWifi = v;
    await settings.save();
    notifyListeners();
  }

  Future<void> setAutoConnectUsb(bool v) async {
    settings.autoConnectUsb = v;
    await settings.save();
    notifyListeners();
  }

  /// 忘记已记住的相机（自动连接随之失效）
  Future<void> forgetCamera() async {
    settings.forgetCamera();
    connectedIp = null;
    await settings.save();
    notifyListeners();
  }

  /// 确保拿到"扫描附近 Wi-Fi"的权限（13+ = NEARBY_WIFI_DEVICES，10~12 = 定位）。
  ///
  /// **返回枚举而不是布尔**：调用方要区分"用户明确拒绝"和"系统已不再弹框"，
  /// 两者的引导完全不同（前者可以再弹一次，后者只能去应用设置）。
  ///
  /// 等待用户作答**不再靠数秒数**：原生侧现在会把系统授权框的结果回调上来
  /// （`onPermissionResult`），这里按 `wifiPermissionState` 等它——
  /// 之前固定等 3.6 秒，用户多看一眼就被判失败，还会弹一个让人摸不着头脑的
  /// "去设置授权"，而权限其实**从没被问过**（真机上 `dumpsys` 可证：
  /// `NEARBY_WIFI_DEVICES` 没有 `USER_SET` 标志）。
  Future<WifiScanPerm> ensureWifiScanPermission() async {
    try {
      if (await NikonEngine.hasWifiScanPermission()) return WifiScanPerm.granted;
      final r = await NikonEngine.requestWifiScanPermission();
      AppLog.addKey('扫描权限：申请结果=$r');
      switch (r) {
        case 'granted':
          return WifiScanPerm.granted;
        case 'blocked':
          return WifiScanPerm.blocked;
        case 'no-activity':
        case 'error':
          return WifiScanPerm.blocked;
        default:
          break; // asked：等用户在系统框上作答
      }
      // 最长等 60 秒（用户可能正在读框上的说明），期间不断查状态
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (await NikonEngine.hasWifiScanPermission()) {
          AppLog.addKey('扫描权限：用户已允许');
          return WifiScanPerm.granted;
        }
        if (await NikonEngine.wifiPermissionState() == 'denied') {
          AppLog.addKey('扫描权限：用户已拒绝');
          return WifiScanPerm.denied;
        }
      }
      AppLog.addKey('扫描权限：等待超时（授权框可能没弹出来）');
      return WifiScanPerm.blocked;
    } catch (e) {
      AppLog.addKey('扫描权限：流程异常 $e');
      return WifiScanPerm.blocked;
    }
  }

  /// 手机已保存过的热点名（相机热点几乎必然在其中，比现扫更可靠）
  Future<List<String>> savedWifiSsids() async {
    try {
      return await NikonEngine.savedWifiSsids();
    } catch (e) {
      AppLog.addKey('读取已保存热点失败：$e');
      return const [];
    }
  }

  /// 打开本应用的系统设置页（用于引导用户手动授予权限）
  Future<void> openAppSettings() => NikonEngine.openAppSettings();

  /// 已记录的相机（可以有多台）
  List<CameraProfile> get cameras => settings.cameras;

  /// 这次连接用的是哪台相机的档案（用于连接成功后把名称/地址写回**正确的那一台**）。
  ///
  /// 为什么不靠当前 SSID 反查：读当前 SSID 需要运行时权限（`NEARBY_WIFI_DEVICES`），
  /// 没授予时系统返回 `<unknown ssid>`；靠名称/地址归并也不可靠。
  /// 显式传参才是能对的前提。
  String? _pendingProfileSsid;

  /// 新增/更新一台相机档案。`ssid` 为空时表示"热点名还没记录"（例如只连过 USB）。
  Future<CameraProfile> saveCameraProfile({
    String? ssid,
    String? password,
    String? name,
    bool? sta,
  }) async {
    final p = settings.upsertCamera(
      ssid: ssid,
      password: password,
      name: name,
      sta: sta,
    );
    await settings.save();
    notifyListeners();
    return p;
  }

  Future<void> removeCameraProfile(CameraProfile target) async {
    settings.removeCameraProfile(target);
    await settings.save();
    notifyListeners();
  }

  /// 编辑一台**已存在**的相机档案（就地修改）。
  ///
  /// 为什么不能复用 [saveCameraProfile]：那条路走 `upsertCamera` 按标识归并，
  /// 而"给旧记录补热点名"时新 SSID 在列表里查不到 → 会**另外追加一条**，
  /// 旧的那条（SSID 为空）永远留在列表里 —— 用户看到的就是
  /// "照提示补了 SSID，列表里还是不显示相机热点"（真机反馈原文）。
  Future<void> updateCameraProfile(
    CameraProfile target, {
    required String ssid,
    required String password,
    String? name,
    required bool sta,
  }) async {
    final newSsid = ssid.trim();
    // 改成的热点名若已被别的档案占用，合并掉那条——同一个热点不该有两条记录
    if (newSsid.isNotEmpty) {
      settings.cameras.removeWhere((c) => !identical(c, target) && c.ssid == newSsid);
    }
    // 热点名**没改动**时保留"推定"标记：用户可能只是来补密码，没核对热点名，
    // 这时把它当成事实会掩盖风险（推错了不会报错，只会连不上）。
    if (newSsid != target.ssid) target.ssidDerived = false;
    target.ssid = newSsid;
    target.password = password;
    if (name != null) target.name = name.trim();
    target.sta = sta;
    if (newSsid.isNotEmpty) settings.lastUsedSsid = newSsid;
    await settings.save();
    notifyListeners();
  }

  /// 手机此刻是否**已经在相机所在的那个网络里**。
  ///
  /// 只看网络层事实，不依赖 SSID：相机地址与手机同 /24，或相机地址就是当前网关
  /// （相机自建热点时它通常就是网关 192.168.1.1）。这样即使永远读不到热点名，
  /// "手动连上相机 Wi-Fi 后点连接"这条最常用的路径也依然能工作。
  bool _sameNetworkAs(String cameraIp) {
    if (cameraIp.isEmpty) return false;
    final ip = wifi?['ip']?.toString() ?? '';
    final gw = wifi?['gateway']?.toString() ?? '';
    if (gw.isNotEmpty && gw == cameraIp) return true;
    final a = ip.split('.');
    final b = cameraIp.split('.');
    if (a.length != 4 || b.length != 4) return false;
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
  }

  /// 按档案连接相机：**这就是"一键重连"的落点**。
  ///
  /// - AP 模式档案：用档案里存的密码请系统连上相机热点（没存密码则直接引导补录，
  ///   不发注定失败的免密请求），再连相机；
  /// - STA 模式档案：相机在同一个路由器下，直接连（会扫本网段）。
  ///
  /// 连接成功后由 [_rememberCamera] 把相机名/地址写回这台档案，供下次使用。
  Future<String> connectViaProfile(CameraProfile p) async {
    if (connState == 'connected' || connState == 'connecting') {
      throw StateError('相机已连接，无需重复连接');
    }
    // 档案里没有热点名（多见于"手动连热点后用 App 连接"自动建档、而系统没给出 SSID）：
    // 此时**不能**一上来就拿上次的 IP 硬连——那个 IP 属于相机热点网段，
    // 而用户此刻很可能已经回到家里路由器，连过去只会得到 ECONNREFUSED 加一串扫描，
    // 看起来就是"点连接失败"却不知道为什么（真机反馈正是如此）。
    //
    // 但也不要直接判死刑：SSID 只决定"要不要替用户切网络"，**不是连接的前提**。
    // 用户手动连上相机 Wi-Fi 的场景下，手机与相机此刻已在同一网络，
    // 直接连即可（判据见 _sameNetworkAs，只读网络层事实，不需要任何权限）。
    if (!p.sta && p.ssid.isEmpty) {
      try {
        await refreshWifi();
      } catch (_) {}
      if (!_sameNetworkAs(p.ip)) {
        throw StateError(
          '「${p.label}」还没记录相机热点名，而且手机现在不在相机的网络里，无法直接连。\n'
          '点「编辑」用「用当前网络」或「选择附近热点」补一次，之后就能一键连接。',
        );
      }
      AppLog.addKey(
        '档案「${p.label}」无热点名，但手机已在相机网络'
        '（本机 ${wifi?['ip']} / 网关 ${wifi?['gateway']} / 相机 ${p.ip}），直接连接',
      );
    }
    _pendingProfileSsid = p.ssid.isEmpty ? null : p.ssid;
    // **没有密码就不发 specifier 请求**。
    //
    // 为什么：`WifiNetworkSpecifier` 不带凭据时请求的是"开放网络"（凭据描述也是
    // 匹配条件的一部分），相机热点是 WPA2 ⇒ **结构性匹配不上**，结局固定是系统
    // "正在搜索设备…→找不到设备"（真机实测过多次）。它不是"用系统已保存的凭据连"
    // ——应用既读不到系统保存的密码（Android 禁止），也无法启用别人保存的网络
    // （Android 10 起 `enableNetwork` 只对本应用创建的网络生效）。
    // 所以与其让用户盯着必然失败的搜索看一分钟，不如立刻给出两条真实出路。
    if (p.canAutoJoin && p.password.isEmpty) {
      throw ApJoinException(
        p.ssid,
        '本应用还没有「${p.ssid}」的密码，无法替你发起 Wi-Fi 连接'
        '（应用不允许读取系统 Wi-Fi 里保存的密码）。',
        hadPassword: false,
      );
    }
    if (p.canAutoJoin) {
      // **入网失败自动重试一次**（仅限"搜索了一阵才失败"的情况）。
      //
      // 为什么：真机实测有一个时间竞态——断开时相机会自动关 Wi-Fi，重新打开后
      // 热点要过一会儿才稳定可搜到；系统specifier 的"正在搜索设备…"在这段窗口里
      // 会以「找不到设备」收场，而用户走完"填密码/去系统设置"再回来时就能连上。
      // 这不是凭据问题，是时机问题——让程序等 5 秒自己重试，别把这个负担丢给用户。
      //
      // 失败**很快**（<3 秒）= 用户在系统确认框上点了取消：绝不再弹一次打扰。
      AppLog.addKey('一键入网「${p.ssid}」（${p.password.isEmpty ? "未带密码" : "带密码"}）');
      final sw = Stopwatch()..start();
      try {
        await NikonEngine.joinCameraAp(p.ssid, p.password);
      } catch (e) {
        final firstErr = e.toString();
        final slow = sw.elapsedMilliseconds >= 3000;
        if (!slow) {
          throw ApJoinException(p.ssid, firstErr, hadPassword: p.password.isNotEmpty);
        }
        AppLog.addKey('入网失败（等了 ${sw.elapsedMilliseconds ~/ 1000}s，像相机 Wi-Fi 刚开启），5 秒后自动重试');
        await Future<void>.delayed(const Duration(seconds: 5));
        try {
          await NikonEngine.joinCameraAp(p.ssid, p.password);
        } catch (e2) {
          throw ApJoinException(p.ssid, e2.toString(), hadPassword: p.password.isNotEmpty);
        }
      }
      // 系统真的让我们连上了这个热点 ⇒ 热点名被现实证实，不再是推定值
      p.ssidDerived = false;
      settings.lastUsedSsid = p.ssid;
      await settings.save();
      notifyListeners();
    }
    try {
      await connectSmart();
    } catch (e) {
      throw Exception(
        p.canAutoJoin ? '已加入热点「${p.ssid}」，但连接相机失败：$e' : '$e',
      );
    }
    return '已连接「${p.label}」';
  }

  /// AP 模式一键入网：App 内加入相机热点 → 立刻连接相机。
  ///
  /// 这是 AP 模式（最常用）该有的终点：用户不必再去系统设置里手动切热点。
  /// 用的是 `WifiNetworkSpecifier`，全程只多一次"系统确认框"。
  ///
  /// **密码可以留空**：留空时系统会用"手机里已保存的这个热点"去连——
  /// 用户第一次连相机时本来就在系统设置里连过一次，那个凭据系统已经记住了。
  /// Android 不允许 App 读取系统保存的 Wi-Fi 密码，但允许请求连接一个已保存的网络，
  /// 所以"第一次手动连过 → 之后一键自动连"是能成立的，不需要用户手输长 SSID。
  Future<String> joinApAndConnect({
    required String ssid,
    String password = '',
  }) async {
    if (connState == 'connected' || connState == 'connecting') {
      throw StateError('相机已连接，无需重复加入热点');
    }
    _pendingProfileSsid = ssid;
    try {
      await NikonEngine.joinCameraAp(ssid, password);
    } catch (e) {
      throw ApJoinException(ssid, e.toString(), hadPassword: password.isNotEmpty);
    }
    settings.upsertCamera(
      ssid: ssid,
      // 只在这次真的提供了密码时覆盖（历史行为保留；现在没有密码时根本不会
      // 走到这里——无密码的 specifier 请求只会匹配开放网络，必然失败）
      password: password.isNotEmpty ? password : null,
    );
    await settings.save();
    notifyListeners();
    try {
      await connectSmart();
    } catch (e) {
      // 热点已经加入了，别把它退掉——用户可以直接再点「连接相机」重试
      throw Exception('已加入热点「$ssid」，但连接相机失败：$e');
    }
    return password.isEmpty
        ? '已用系统保存的凭据加入热点「$ssid」并连上相机'
        : '已加入热点「$ssid」并连上相机';
  }

  /// 保存相机热点凭据（SSID / 密码），供一键入网使用
  Future<void> saveApCredentials(String ssid, String password) async {
    await saveCameraProfile(ssid: ssid.trim(), password: password);
  }

  /// 退出 App 专属的相机热点连接（恢复系统默认网络）
  Future<void> leaveCameraAp() async {
    await NikonEngine.leaveCameraAp();
  }

  /// 尽力读出**当前所连热点名**（补全相机档案用），读不到返回 null。
  ///
  /// 顺序：`currentSsid()` →（必要时申请权限）→ `currentSsid()` → `wifiInfo['ssid']`。
  /// **读不到不是错误**，只意味着档案里少一个字段。
  Future<String?> _readCurrentSsid() async {
    try {
      final s = (await NikonEngine.currentSsid())?.trim();
      if (s != null && s.isNotEmpty && !s.startsWith('<')) return s;
    } catch (e) {
      AppLog.addKey('读当前热点名失败：$e');
    }
    try {
      if (!await NikonEngine.hasWifiScanPermission()) {
        // 这一步正是"确实需要知道热点名"的场景，在这里弹授权框合情合理；
        // 否则用户得自己去翻「添加相机 → 选择附近热点」，很容易半途而废
        // （真机反馈：连过好几次，档案里始终没有热点名）。
        final r = await ensureWifiScanPermission();
        AppLog.addKey('为补全热点名申请权限：$r');
        if (r == WifiScanPerm.granted) {
          final s = (await NikonEngine.currentSsid())?.trim();
          if (s != null && s.isNotEmpty && !s.startsWith('<')) return s;
        }
      }
    } catch (e) {
      AppLog.addKey('申请扫描权限失败：$e');
    }
    // 最后兜底：wifiInfo 里的 ssid（Android 10~12 通常可读）
    try {
      await refreshWifi();
      final cur = (wifi?['ssid'] as String?)?.trim();
      if (cur != null && cur.isNotEmpty && !cur.startsWith('<')) return cur;
    } catch (_) {}
    return null;
  }

  /// 记住这台相机。SSID 只在**Wi-Fi 连接**时记录：那时手机加入的正是相机热点；
  /// 若在 USB 连接时也记 SSID，记下的会是家里路由器的名字，之后一回家就会误连。
  ///
  /// **保存必须放在 finally 里**：取值过程中任何一步抛异常（例如 refreshWifi 失败）
  /// 都不该丢掉已经拿到的部分——之前写在 try 末尾，一次失败就什么都没存，
  /// 表现是"连过好几次了，连接页还是没有记住的相机"。
  Future<void> _rememberCamera() async {
    try {
      // 相机名的键是 `cameraName`（PTP/IP 握手时相机自报的名字），
      // 不是 `name`——设备信息里没有 `name` 这个键，之前取错了所以一直是空。
      final info = cameraInfo;
      final camName = (info?['cameraName'] as String?)?.trim();
      final model = (info?['model'] as String?)?.trim();
      final label = (camName != null && camName.isNotEmpty)
          ? camName
          : ((model != null && model.isNotEmpty) ? model : null);

      // **相机序列号 = 同一台相机的唯一身份**（Wi-Fi 与 USB 都一样，见 cameraInfo['serial']）。
      // 用它归并档案，才不会出现"无线一条、数据线一条"的两条记录。
      final serial = (info?['serial'] as String?)?.trim();

      // 连上的地址：原生这次实际握手的 host。USB 是 `usb:` 伪地址，不能当 Wi-Fi 地址存
      final rawIp = (info?['ip'] as String?)?.trim();
      final ip = (rawIp != null && _isIpv4(rawIp)) ? rawIp : null;
      if (ip != null) connectedIp = ip;

      if (transport == 'wifi') {
        // 写回"这次用的是哪台档案"（最准）。没有 pending（用户手动连的热点）时，
        // 由 _readCurrentSsid 尽力读一次：读不到不等于出错（本机 `getSSID()` 恒为
        // `<unknown ssid>`，权限已授予也如此），退回按名称/地址归并即可。
        var ssid = _pendingProfileSsid;
        if (ssid == null || ssid.isEmpty) {
          ssid = await _readCurrentSsid();
        }
        // 系统读不到就用相机自身上报的数据推——实测能推出正确热点名
        // （NIKON_ + 型号 + 序列号末 5 位），标为"推定"，
        // 真正入网成功后会在 connectViaProfile 里转正。
        var derived = false;
        if (ssid == null || ssid.isEmpty) {
          final guess = CameraProfile.deriveApSsid(cameraName: camName, serial: serial);
          if (guess != null) {
            ssid = guess;
            derived = true;
            AppLog.addKey('系统读不到热点名，按序列号推得：$guess（推定）');
          }
        }
        AppLog.addKey('记住相机：本次 SSID=${ssid ?? "（读不到）"}${derived ? "（推定）" : ""}');
        settings.upsertCamera(
          serial: serial,
          ssid: ssid,
          ssidDerived: derived,
          name: label,
          ip: ip,
        );
      } else {
        // USB：只记名称与序列号（IP 是伪地址，SSID 记了会变成家里路由器的名字）。
        // 序列号是把"无线那条"和"数据线那条"合并成一条的依据；
        // 热点名照旧可以推（推出来的是相机自建热点的名字，与当前连的网络无关）。
        settings.upsertCamera(serial: serial, name: label);
      }
    } catch (e) {
      AppLog.addKey('记住相机时出错：$e');
    } finally {
      try {
        await settings.save();
      } catch (_) {}
      final p = settings.lastCamera;
      AppLog.addKey(
        '已记住相机：name=${p?.name} serial=${p?.serial} ssid=${p?.ssid} ip=${p?.ip} '
        '档案数=${settings.cameras.length}（本次 transport=$transport）',
      );
      notifyListeners();
    }
  }

  static final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  static bool _isIpv4(String s) => _ipv4.hasMatch(s);

  bool _autoWifiTriedThisResume = false;

  /// 每次回到前台重置"本轮到点自动连接"的额度，避免一次会话里反复重试
  void resetAutoConnectGate() => _autoWifiTriedThisResume = false;

  /// 尝试自动连接已记住的相机。返回一句给用户看的说明；null = 什么都没做。
  ///
  /// **只在"确实像用户意图"时才连**：当前 Wi-Fi 的 SSID 就是上次那台相机的热点。
  /// 不能凭"曾经连过"就盲连——PTP/IP 相机同一时刻只接受一个会话，
  /// 盲目连接会抢掉别的 App 正在用的会话，失败还会白占相机的会话释放窗口（可达 3 分钟）。
  Future<String?> tryAutoConnectWifi() async {
    if (!settings.autoConnectWifi) return null;
    if (connState == 'connected' || connState == 'connecting') return null;
    if (settings.cameras.isEmpty) return null;
    if (_autoWifiTriedThisResume) return null;
    _autoWifiTriedThisResume = true;

    final p = settings.lastCamera;
    if (p == null) return null;

    // STA 档案：相机本来就在同一个网络里，不需要比对热点名
    if (!p.sta) {
      if (p.ssid.isEmpty) return null;
      try {
        await refreshWifi();
      } catch (_) {}
      final ssid = (wifi?['ssid'] as String?)?.trim();
      final readable = ssid != null && ssid.isNotEmpty && !ssid.startsWith('<');
      if (readable) {
        // 读得到就按热点名判断：不是它**不自动连**——PTP/IP 相机只接受一个会话，
        // 盲连会抢掉别的 App 正在用的会话，失败还白占相机最长 3 分钟的释放窗口
        if (ssid != p.ssid) return null;
      } else {
        // 读不到 SSID（本机 ROM 恒为 `<unknown ssid>`）：改用**网络层事实**判断——
        // 手机若已在相机的网络里（相机地址就是当前网关，或与手机同 /24），
        // 那就是用户的明确意图（他刚在系统设置里连上了相机热点）。
        // 这正是"去系统设置连一次 → 切回 App"的收尾动作，不判的话就永远接不上。
        if (!_sameNetworkAs(p.ip)) return null;
        AppLog.addKey('读不到热点名，但手机已在相机网络（${wifi?['ip']} / 网关 ${wifi?['gateway']}），自动连接「${p.label}」');
      }
    }

    try {
      _pendingProfileSsid = p.ssid.isEmpty ? null : p.ssid;
      // 已经在目标网络里了，直接连（不要再次请求加入热点，那会又弹一次系统确认框）
      await connectSmart();
      return '已自动连接「${p.label}」';
    } catch (e) {
      // 自动连接失败**不打扰用户**：多数是相机在忙或会话还没释放，重试由用户决定
      AppLog.addKey('自动连接失败（${p.label}）：$e');
      return null;
    }
  }

  /// 同一次 USB 插入只自动试一次，失败后不再反复尝试
  String? _usbAutoTriedFor;

  /// 检测到 USB 相机接入 → 按设置自动连接。
  ///
  /// 失败则退回"提示用户手动连接"（`usbAttachNotice`），并在连接页给出按钮。
  Future<void> _autoConnectUsb(String name) async {
    if (!settings.autoConnectUsb) return;
    if (connState == 'connected' || connState == 'connecting') return;
    if (_usbAutoTriedFor == name) return;
    _usbAutoTriedFor = name;
    try {
      await connectUsb();
      usbAttachNotice = null;
      AppLog.addKey('USB 相机（$name）已自动连接');
    } catch (e) {
      AppLog.addKey('USB 相机自动连接失败：$e');
      usbAttachNotice = name; // 退回手动：把提示留给用户
      notifyListeners();
    }
  }

  Future<void> scan() async {
    scanning = true;
    notifyListeners();
    try {
      foundCameras = await NikonEngine.scan();
    } catch (e) {
      foundCameras = [];
      rethrow;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 是否由本模型自己发起连接。
  /// 用于区分"主动连接"（返回后由这里初始化）与"其他入口连接成功"
  /// （调试面板直连原生，只能靠 connected 事件初始化），避免重复枚举。
  bool _connectingSelf = false;

  Future<void> connect(String ip) async {
    connState = 'connecting';
    connError = null;
    transport = 'wifi';
    notifyListeners();
    _connectingSelf = true;
    try {
      cameraInfo = await NikonEngine.connect(ip, 'Nikon Wireless Mobile Utility');
      connectedIp = ip;
      await _afterConnected();
    } catch (e) {
      connState = 'disconnected';
      connError = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _connectingSelf = false;
    }
  }

  /// 当前/上次 Wi-Fi 连上的相机地址（自动重连与"记住的相机"用它）
  String? connectedIp;

  /// USB 连接：相机经数据线直连手机，走 PTP/USB 传输层（27.1 MB/s）
  Future<void> connectUsb() async {
    connState = 'connecting';
    connError = null;
    transport = 'usb';
    notifyListeners();
    _connectingSelf = true;
    try {
      cameraInfo = await NikonEngine.connectUsb('Nikon Wireless Mobile Utility');
      await _afterConnected();
    } catch (e) {
      connState = 'disconnected';
      connError = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _connectingSelf = false;
    }
  }

  /// 主流程入口：无需先扫描，直接对网关（相机）握手
  Future<void> connectSmart() async {
    connState = 'connecting';
    connError = null;
    transport = 'wifi';
    notifyListeners();
    _connectingSelf = true;
    try {
      cameraInfo = await NikonEngine.connectSmart();
      await _afterConnected();
    } catch (e) {
      connState = 'disconnected';
      connError = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _connectingSelf = false;
    }
  }

  Future<void> _afterConnected() async {
    connState = 'connected';
    hasNewPhotos = false;
    _clearReconnect();
    // 保活前台服务马上要起来：先在 Android 13+ 上把通知权限要到，
    // 否则通知完全不可见，用户不知道后台在保活（Manifest 里的声明一直没人申请）。
    unawaited(ensureNotificationPermission());
    // 记住这台相机（SSID/IP/名称），供下次自动连接与"记住的相机"快捷入口使用
    unawaited(_rememberCamera());
    notifyListeners();
    battery = await NikonEngine.battery();
    notifyListeners();
    // 存储卡状态、信号/心跳监控与文件列表并行拉取
    unawaited(refreshStorage());
    _startSignalWatch();
    await loadFiles();
  }

  Future<void> disconnect() async {
    await NikonEngine.disconnect();
    connState = 'disconnected';
    cameraInfo = null;
    _stopSignalWatch();
    notifyListeners();
  }

  void consumeNewPhotos() {
    hasNewPhotos = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ 文件

  /// 快速枚举（只拿句柄，秒级）。与已有列表按句柄合并，保留已加载详情。
  Future<void> loadFiles() async {
    if (connState != 'connected') return;
    loadingFiles = true;
    filesError = null;
    notifyListeners();
    try {
      final r = await NikonEngine.listFolders();
      final handles = (r['files'] as List).map((e) => (e as num).toInt()).toList();
      final folderNames = (r['folders'] as List).cast<String>();
      final folderIdx = (r['fileFolders'] as List?)?.map((e) => (e as num).toInt()).toList();
      final byHandle = {for (final f in files) f.handle: f};
      final next = <CameraFile>[];
      for (var i = 0; i < handles.length; i++) {
        final h = handles[i];
        final folder = folderIdx != null && i < folderIdx.length && folderIdx[i] >= 0
            ? folderNames[folderIdx[i]]
            : '';
        final old = byHandle[h];
        if (old != null) {
          next.add(old);
        } else {
          next.add(CameraFile(handle: h, folder: folder));
        }
      }
      // 新照片优先：文件夹名倒序（106NZ502 > 105NZ502）、句柄倒序
      next.sort((a, b) {
        final c = b.folder.compareTo(a.folder);
        return c != 0 ? c : b.handle.compareTo(a.handle);
      });
      files = next;
      loadingFiles = false;
      _rebuildPairIndex();
      notifyListeners();
      // 重新枚举说明用户主动刷新或相机有新照片：给此前读取失败的句柄一次重试机会
      gateway.resetFailures();
      _startIndexing();
      _autoProbe();
    } catch (e) {
      loadingFiles = false;
      filesError = e.toString();
      notifyListeners();
    }
  }

  bool _indexRunning = false;
  bool _probedOnce = false;

  // ------------------------------------------------------------ RAW+JPEG 配对

  /// 基名索引：目录/基名 → 文件。配对与"找另一半"都走它，避免每次 O(n) 扫全表。
  final Map<String, CameraFile> _pairIndex = {};

  /// 重新枚举后重建索引（只有已读到文件名的条目能入索引）。
  void _rebuildPairIndex() {
    _pairIndex.clear();
    for (final f in files) {
      final k = PairLinker.keyOf(f);
      if (k != null) _pairIndex[k] = f;
    }
    // 规则集中在 PairLinker（可单测），这里只做装配
    PairLinker.linkAll(files);
  }

  /// 给一个文件找配对：同目录 + 同基名 + 类型互补（一个 JPEG 一个 RAW）。
  /// 视频不参与配对；同名同类的两个文件不配对——宁可不连，也不要连错。
  void _pairOne(CameraFile f) {
    final k = PairLinker.keyOf(f);
    if (k == null) return;
    PairLinker.link(f, _pairIndex[k]);
  }

  /// 取配对文件（无配对返回 null）
  CameraFile? pairOf(CameraFile f) {
    final h = f.pairHandle;
    if (h == null) return null;
    for (final x in files) {
      if (x.handle == h) return x;
    }
    return null;
  }

  /// 该文件的配对是否已下载到手机
  bool isPairDownloaded(CameraFile f) {
    final p = pairOf(f);
    return p != null && isDownloaded(p);
  }

  /// 连接后自动运行一次协议探针（高速下载 0x9400 族 / 相机端缩放 0x9207），
  /// 结果写入调试日志，用于确定能否接入更快的下载通道。
  void _autoProbe() {
    if (_probedOnce || files.isEmpty) return;
    _probedOnce = true;
    final h = files.first.handle;
    gateway.schedule(() async {
      try {
        await NikonEngine.probeHiSpeed(h);
        await NikonEngine.probeResize(h);
      } catch (_) {}
    }, priority: false);
  }

  /// 后台逐个补全文件详情（低优先级，让位给可见单元格加载）。
  void _startIndexing() {
    if (_indexRunning) return;
    _indexRunning = true;
    _indexStep();
  }

  void _indexStep() {
    if (connState != 'connected' || !_indexRunning) {
      _indexRunning = false;
      return;
    }
    CameraFile? next;
    for (final f in files) {
      if (!f.infoLoaded) {
        next = f;
        break;
      }
    }
    if (next == null) {
      _indexRunning = false;
      notifyListeners();
      return;
    }
    final target = next;
    gateway
        .schedule(() => NikonEngine.fileInfo(target.handle), priority: false)
        .then((m) {
      target.applyInfo(m);
      // 索引补全后才拿得到文件名——RAW+JPEG 配对只能在这里增量做（O(1)）
      final k = target.pairKey;
      if (k != null) _pairIndex[k] = target;
      _pairOne(target);
    })
        .catchError((_) {})
        .whenComplete(() {
      // 计数必须是"已补全详情的文件数"，**不能**用 `files.length`：那是列表总长度，
      // 枚举完成就固定了，既不递增也不是进度。实测后果是两个极端——1500 张的卡上
      // `1500 % 16 != 0` 恒为假（索引进度永远不刷新），1600 张时又每个文件都通知一次。
      _indexedSinceNotify++;
      if (_indexedSinceNotify >= 16 || indexingDone) {
        _indexedSinceNotify = 0;
        _notifyThrottled();
      }
      _indexStep();
    });
  }

  /// 距上次通知已补全详情的文件数（见 [_indexStep]）。
  int _indexedSinceNotify = 0;

  // ------------------------------------------------------------ 下载

  /// 批量下载。[variantOverride] 用于显式指定画质（查看器"显示原图"要强制原图，
  /// 不受设置里的下载画质影响）。
  Future<String> download(
    List<CameraFile> picks, {
    String? variantOverride,
    void Function(CameraFile f, String? uri)? onSaved,
  }) async {
    if (downloading || picks.isEmpty) return '';
    downloading = true;
    cancelRequested = false;
    dlDone = 0;
    dlTotal = picks.length;
    dlFileFrac = 0;
    dlSpeed = 0;
    dlResult = null;
    dlCurrentName = '';
    dlIssues.clear();
    notifyListeners();
    final variant = variantOverride ?? downloadVariant;
    // 逐张的原因要留下来：只汇总成"失败 3"的话，用户根本不知道是哪三张、为什么，
    // 也就无从决定要不要重试（而失败的那几张往往正是他真正想要的那几张）。
    dlIssues.clear();
    final summary = await gateway.downloadFiles(
      picks,
      variant: variant,
      onSaved: onSaved,
      deleteAfterDownload: deleteAfterDownload,
      onFileSkipped: (f, message) =>
          dlIssues.add((handle: f.handle, name: f.name ?? '#${f.handle}', reason: message)),
      onProgress: (done, total, current, fileFrac, speed) {
        dlDone = done;
        dlTotal = total;
        if (fileFrac == 0) {
          dlCurrentName = current.name ?? '';
          dlFileFrac = 0;
        }
        notifyListeners();
      },
      isCancelled: () => cancelRequested,
    );
    downloading = false;
    dlFileFrac = 0;
    // 取消要单独说：把"已取消"混进"失败"会让用户以为出了故障，
    // 而"剩余 N 张未传"才是他下一步该知道的事。
    dlResult = summary.cancelled
        ? '已取消（已下载 ${summary.downloaded}，剩余 ${summary.remaining} 张未传）'
        : '已下载 ${summary.downloaded}，跳过 ${summary.skipped}，失败 ${summary.failed}'
            '${deleteAfterDownload ? '，已删除相机原片 ${summary.deleted}' : ''}';
    notifyListeners();
    return dlResult!;
  }

  /// 取消当前下载。
  ///
  /// **两步缺一不可**：[cancelRequested] 只让 Dart 侧的批量循环在"下一张之前"停下，
  /// 而正在传的那一张阻塞在原生 `getObjectToStream` 的循环里——那里的取消标志只能
  /// 由 Kotlin 侧设置。此前只做了第一步，所以"点取消"对 4GB 视频要等它传完才生效。
  Future<void> cancelDownload() async {
    cancelRequested = true;
    try {
      await NikonEngine.cancelDownload();
    } catch (_) {
      // 取消请求本身失败不影响 Dart 侧已经置位的停止逻辑，不该因此弹错
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ 事件

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final map = e.cast<String, dynamic>();
    switch (map['type']) {
      case 'usbAttached':
        // 插入相机把应用拉起（Manifest 声明了 USB_DEVICE_ATTACHED）。此前无人处理，
        // 表现是"App 自己开了但什么都不做"；现在按设置自动连接，失败才退回提示。
        usbAttachNotice = map['name']?.toString() ?? 'USB 相机';
        notifyListeners();
        unawaited(_autoConnectUsb(usbAttachNotice!));
      case 'usbDetached':
        // 拔出：清掉提示，并允许"下一次插入"重新自动连一次
        // （_usbAutoTriedFor 是"同一次插入只试一次"的门，不重置的话第二次插上就不会自动连）
        _usbAutoTriedFor = null;
        usbAttachNotice = null;
        notifyListeners();
      case 'log':
        AppLog.add(map['line']?.toString() ?? '');
      case 'status':
        final state = map['state'];
        if (state == 'reconnecting') {
          // 自动重连中：UI 显示"连接中…"并给出第几次尝试，不置灰
          reconnectAttempt = (map['attempt'] as num?)?.toInt() ?? 0;
          reconnectTotal = (map['total'] as num?)?.toInt() ?? 0;
          reconnectNextMs = (map['nextInMs'] as num?)?.toInt() ?? 0;
          reconnectReason = map['reason']?.toString();
          connState = 'connecting';
          notifyListeners();
        } else if (state == 'disconnected') {
          _clearReconnect();
          _stopSignalWatch();
          if (connState != 'disconnected') {
            connState = 'disconnected';
            _indexRunning = false;
            notifyListeners();
          }
        } else if (state == 'connected' && !_connectingSelf && connState != 'connected') {
          // 相机连上了，但连接不是本模型发起的（调试面板直连原生）：
          // 只能靠事件补齐状态与文件列表，否则相机已连上、相册页却显示"连接已断开"。
          unawaited(_afterConnected());
        }
      case 'progress':
        final received = (map['received'] as num?)?.toDouble() ?? 0;
        final total = (map['total'] as num?)?.toDouble() ?? 0;
        final speed = (map['speedMBps'] as num?)?.toDouble() ?? 0;
        if (downloading) {
          dlFileFrac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          dlSpeed = speed;
        }
        // 大图页的"显示原图"也会走到这里（下载与仅查看两条路径共用同一套进度事件）
        if (originalLoading) {
          originalReceived = received.round();
          if (total > 0) originalTotal = total.round();
          originalFrac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          originalSpeed = speed;
        }
        if (downloading || originalLoading) notifyListeners();
      case 'health':
        // 保活心跳（每 5s 一次，来自原生）：只有它才能回答
        // "相机是空闲还是已经失联"——事件通道安静时这两种情况长得一样。
        camIdleMs = (map['eventAgoMs'] as num?)?.toInt() ?? -1;
        camRttMs = (map['rttMs'] as num?)?.toInt() ?? -1;
        camProbeOk = map['probeOk'] != false;
        notifyListeners();
      case 'objectAdded':
        if (connState == 'connected') {
          hasNewPhotos = true;
          notifyListeners();
        }
    }
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _signalTimer?.cancel();
    gateway.records.removeListener(_notifyThrottled);
    _sub?.cancel();
    super.dispose();
  }
}
