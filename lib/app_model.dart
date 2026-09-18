import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine/app_log.dart';
import 'engine/camera_gateway.dart';
import 'engine/nikon_engine.dart';
import 'engine/settings_store.dart';
import 'models/camera_file.dart';
import 'models/pair_linker.dart';

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
    settings.load().then((_) => notifyListeners());
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
      final name = await NikonEngine.lastUsbAttach();
      if (name != null && usbAttachNotice == null) {
        usbAttachNotice = name;
        notifyListeners();
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
    notifyListeners();
    final variant = variantOverride ?? downloadVariant;
    final summary = await gateway.downloadFiles(
      picks,
      variant: variant,
      onSaved: onSaved,
      deleteAfterDownload: deleteAfterDownload,
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
        // 表现是"App 自己开了但什么都不做"；现在连接页会切到 USB 模式并提示。
        usbAttachNotice = map['name']?.toString() ?? 'USB 相机';
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
