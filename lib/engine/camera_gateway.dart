import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'nikon_engine.dart';
import 'record_store.dart';
import 'thumb_cache.dart';
import '../models/camera_file.dart';

/// 相机请求网关：PTP 命令通道一次只能跑一个事务，这里做统一串行调度。
/// 高优先级队列（可见单元格加载、用户操作）优先于低优先级（后台索引）。
/// 大文件下载不进队列（耗时长），由协议层事务锁天然串行。
class CameraGateway {
  CameraGateway() {
    thumbCache.pruneDiskIfNeeded();
    records.load();
  }

  // NikonEngine 为纯静态封装
  final ThumbCache thumbCache = ThumbCache();
  final RecordStore records = RecordStore();

  final Queue<_Job> _hi = Queue();
  final Queue<_Job> _lo = Queue();
  bool _running = false;
  final Set<int> _pendingInfo = {};
  final Set<int> _pendingThumb = {};

  /// 详情/缩略图的失败次数。没有这个负缓存时，单元格每次重建都会重新发起
  /// 请求，而这些请求的回调又会触发重建，形成请求风暴。
  /// 用计数而非一次性放弃：瞬时失败（相机忙）值得重试，反复失败的才止损。
  static const int _maxInfoRetry = 3;
  final Map<int, int> _infoFailCnt = {};
  final Map<int, int> _thumbFailCnt = {};

  bool _exhausted(Map<int, int> counts, int handle) =>
      (counts[handle] ?? 0) >= _maxInfoRetry;

  void _countFail(Map<int, int> counts, int handle) =>
      counts[handle] = (counts[handle] ?? 0) + 1;

  /// 重新枚举文件后清空失败计数，给这些句柄一次完整重试机会。
  void resetFailures() {
    _infoFailCnt.clear();
    _thumbFailCnt.clear();
  }

  /// 任一文件详情/缩略图加载完成时回调（驱动 UI 刷新）
  void Function()? onFileUpdated;

  // -------------------------------------------------------- 调度核心

  Future<T> schedule<T>(Future<T> Function() op, {bool priority = false}) {
    final c = Completer<T>();
    final job = _Job(() async {
      try {
        c.complete(await op());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    (priority ? _hi : _lo).addLast(job);
    _pump();
    return c.future;
  }

  void _pump() {
    if (_running) return;
    final Queue<_Job> q = _hi.isNotEmpty ? _hi : _lo;
    if (q.isEmpty) return;
    _running = true;
    q.removeFirst().run().whenComplete(() {
      _running = false;
      _pump();
    });
  }

  // -------------------------------------------------------- 文件加载

  /// 是否还需要（且值得）发起加载请求。给 UI 用来判断要不要安排加载，
  /// 避免每个单元格每次重建都排一个注定什么都不做的回调。
  bool needsLoad(CameraFile f, {bool withThumb = false}) {
    final needInfo = !f.infoLoaded && !_exhausted(_infoFailCnt, f.handle);
    final needThumb = withThumb && !f.hasThumb && !_exhausted(_thumbFailCnt, f.handle);
    return needInfo || needThumb;
  }

  /// 确保文件详情已加载（可选缩略图）。网格单元格可见时调用。
  /// 返回是否发起了新请求（配合 UI 占位动画）。
  bool ensureLoaded(CameraFile f, {bool withThumb = false}) {
    if (!needsLoad(f, withThumb: withThumb)) return false;
    final needInfo = !f.infoLoaded;
    final needThumb = withThumb && !f.hasThumb;
    if (needInfo && !_pendingInfo.add(f.handle)) return false;
    if (needThumb && !_pendingThumb.add(f.handle)) return false;

    schedule(() async {
      if (needInfo) {
        if (withThumb) {
          final m = await NikonEngine.fileView(f.handle);
          f.applyInfo(m);
          final bytes = m['thumb'] as Uint8List?;
          if (bytes != null && bytes.isNotEmpty) {
            thumbCache.put(f.handle, bytes);
            f.hasThumb = true;
          }
        } else {
          f.applyInfo(await NikonEngine.fileInfo(f.handle));
        }
      } else if (needThumb) {
        var bytes = await thumbCache.get(f.handle);
        bytes ??= (await NikonEngine.fileView(f.handle))['thumb'] as Uint8List?;
        if (bytes != null && bytes.isNotEmpty) {
          thumbCache.put(f.handle, bytes);
          f.hasThumb = true;
        }
      }
    }, priority: withThumb).catchError((_) {}).whenComplete(() {
      _pendingInfo.remove(f.handle);
      _pendingThumb.remove(f.handle);
      // 本轮尝试过但没拿到就记一次失败；连续失败到上限后不再重试
      if (withThumb && !f.infoLoaded) _countFail(_infoFailCnt, f.handle);
      if (withThumb && !f.hasThumb) _countFail(_thumbFailCnt, f.handle);
      onFileUpdated?.call();
    });
    return true;
  }

  Uint8List? memThumb(int handle) => thumbCache.memGet(handle);

  final Map<int, Uint8List> _viewMem = {};

  void _memViewPut(int handle, Uint8List bytes) {
    _viewMem.remove(handle);
    _viewMem[handle] = bytes;
    while (_viewMem.length > 4) {
      _viewMem.remove(_viewMem.keys.first);
    }
  }

  /// 大图查看用的最佳字节：JPEG 拉原图（≤40MB），RAW/视频用大缩略图。
  Future<Uint8List> viewBytes(CameraFile f) async {
    final cached = _viewMem[f.handle];
    if (cached != null) return cached;
    Uint8List bytes;
    if (f.kind == 'video' || f.kind == 'raw') {
      if (!f.hasThumb && !_exhausted(_thumbFailCnt, f.handle)) {
        await schedule(() async {
          final m = await NikonEngine.fileView(f.handle);
          f.applyInfo(m);
          final t = m['thumb'] as Uint8List?;
          if (t != null && t.isNotEmpty) {
            thumbCache.put(f.handle, t);
            f.hasThumb = true;
          } else {
            _countFail(_thumbFailCnt, f.handle);
          }
        }, priority: true).catchError((_) {
          _countFail(_thumbFailCnt, f.handle);
        });
      }
      final t = thumbCache.memGet(f.handle) ?? await thumbCache.get(f.handle);
      if (t == null) throw StateError('预览图不可用');
      bytes = t;
    } else {
      bytes = await NikonEngine.fetchObject(f.handle, f.size ?? 0);
    }
    _memViewPut(f.handle, bytes);
    return bytes;
  }

  // -------------------------------------------------------- 下载

  /// 批量下载（顺序执行）。跳过已下载文件，返回统计。
  /// [variant]：original / 8M / 2M；[deleteAfterDownload]：成功后删除相机原片。
  Future<DownloadSummary> downloadFiles(
    List<CameraFile> picks, {
    void Function(int done, int total, CameraFile current, double fileFrac, double speedMBps)? onProgress,
    void Function(CameraFile f, String message)? onFileSkipped,
    bool Function()? isCancelled,
    String variant = 'original',
    bool deleteAfterDownload = false,
  }) async {
    final summary = DownloadSummary(total: picks.length);
    for (final f in picks) {
      if (isCancelled?.call() ?? false) break;
      // 详情缺失时先补（多 RAW+JPEG 同拍时名字已知的 JPEG 优先已覆盖大多数场景）
      if (!f.infoLoaded) {
        try {
          f.applyInfo(await schedule(() => NikonEngine.fileInfo(f.handle), priority: true));
        } catch (_) {}
      }
      final name = f.name;
      final size = f.size;
      if (name == null || size == null) {
        onFileSkipped?.call(f, '详情读取失败，已跳过');
        summary.skipped++;
        continue;
      }
      final recordName = variant == 'original' ? name : '$name#$variant';
      if (records.contains(recordName, size)) {
        onFileSkipped?.call(f, variant == 'original' ? '已下载过，跳过' : '该画质已下载过，跳过');
        summary.skipped++;
        continue;
      }
      try {
        onProgress?.call(summary.done, picks.length, f, 0, 0);
        final r = await NikonEngine.download(f.handle, name, size, variant: variant);
        records.add(RecEntry(
          name: name,
          size: size,
          variant: variant,
          uri: r['uri'] as String?,
          path: r['path'] as String?,
        ));
        if (deleteAfterDownload) {
          try {
            await NikonEngine.deleteObject(f.handle);
            summary.deleted++;
          } catch (_) {
            onFileSkipped?.call(f, '下载成功但删除相机原片失败');
          }
        }
        summary.downloaded++;
        summary.bytes += size;
      } catch (e) {
        onFileSkipped?.call(f, '下载失败：$e');
        summary.failed++;
      }
      onProgress?.call(summary.done, picks.length, f, 1.0, 0);
    }
    return summary;
  }
}

class DownloadSummary {
  DownloadSummary({required this.total});
  final int total;
  int downloaded = 0;
  int skipped = 0;
  int failed = 0;
  int deleted = 0;
  int bytes = 0;
  int get done => downloaded + skipped + failed;
  bool get allOk => failed == 0;
}

class _Job {
  _Job(this.run);
  final Future<void> Function() run;
}
