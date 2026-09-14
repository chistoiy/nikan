import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine/app_log.dart';
import 'engine/camera_gateway.dart';
import 'engine/nikon_engine.dart';
import 'engine/settings_store.dart';
import 'models/camera_file.dart';

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

  bool isDownloaded(CameraFile f) => gateway.records.contains(f.name, f.size);

  // ------------------------------------------------------------ 连接

  Future<void> refreshWifi() async {
    wifi = await NikonEngine.wifiInfo();
    notifyListeners();
  }

  Future<void> openWifiSettings() => NikonEngine.openWifiSettings();

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

  /// 主流程入口：无需先扫描，直接对网关（相机）握手
  Future<void> connectSmart() async {
    connState = 'connecting';
    connError = null;
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
    notifyListeners();
    battery = await NikonEngine.battery();
    notifyListeners();
    await loadFiles();
  }

  Future<void> disconnect() async {
    await NikonEngine.disconnect();
    connState = 'disconnected';
    cameraInfo = null;
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
    gateway
        .schedule(() => NikonEngine.fileInfo(next!.handle), priority: false)
        .then(next.applyInfo)
        .catchError((_) {})
        .whenComplete(() {
      if (files.length % 16 == 0 || indexingDone) notifyListeners();
      _indexStep();
    });
  }

  // ------------------------------------------------------------ 下载

  Future<String> download(List<CameraFile> picks) async {
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
    final summary = await gateway.downloadFiles(
      picks,
      variant: downloadVariant,
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
    dlResult = '已下载 ${summary.downloaded}，跳过 ${summary.skipped}，失败 ${summary.failed}'
        '${deleteAfterDownload ? '，已删除相机原片 ${summary.deleted}' : ''}';
    notifyListeners();
    return dlResult!;
  }

  // ------------------------------------------------------------ 事件

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final map = e.cast<String, dynamic>();
    switch (map['type']) {
      case 'log':
        AppLog.add(map['line']?.toString() ?? '');
      case 'status':
        final state = map['state'];
        if (state == 'disconnected') {
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
        if (downloading) {
          final received = (map['received'] as num?)?.toDouble() ?? 0;
          final total = (map['total'] as num?)?.toDouble() ?? 0;
          dlFileFrac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          dlSpeed = (map['speedMBps'] as num?)?.toDouble() ?? 0;
          notifyListeners();
        }
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
    gateway.records.removeListener(_notifyThrottled);
    _sub?.cancel();
    super.dispose();
  }
}
