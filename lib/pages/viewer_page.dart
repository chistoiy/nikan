import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../engine/app_log.dart';
import '../engine/nikon_engine.dart';
import '../models/camera_file.dart';
import '../models/exif_summary.dart';
import '../util/format.dart';
import 'widgets/app_widgets.dart';
import 'widgets/zoom_image.dart';

/// 全屏大图查看器：左右翻页、双指缩放、按画质档位取图、EXIF 信息（ISO/光圈/快门）。
///
/// **画质策略**：默认不再拉原图。一张 JPEG 原图可达 20MB+，Wi-Fi（实测 2.4MB/s）
/// 下要好几秒，而"翻看图个大概"根本不需要原图。现在按设置里的档位取图：
/// - `low`    = 大缩略图（~1600px，与列表缩略图同源，几乎零成本）
/// - `medium` = 相机端 FHD 图 0x920F（≤1920×1028，几十~几百 KB）——**默认**
/// - `original` = 原图（仅当前这一张，按需点「显示原图」）
/// 该动作只作用于当前这张，翻页不受影响；角标始终显示实际生效档位与大小，
/// 避免用户"以为在看原图"。
///
/// **原图加载（2026-09-15 第四轮）**：点「显示原图」后显示**真实进度**——百分比、
/// 已接收/总量、速率、已用时，并在连续 8 秒没有新数据时明确提示"可能已卡住"。
/// 是否顺带保存到手机由设置决定（默认不保存，仅查看）。
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.model,
    required this.files,
    required this.initialIndex,
    this.isSelected,
    this.onToggleSelect,
  });

  final AppModel model;
  final List<CameraFile> files;
  final int initialIndex;

  /// 当前这张是否已被选中（配套 [onToggleSelect]）。为 null 表示这个入口不支持选择。
  final bool Function(int handle)? isSelected;

  /// 在查看器内切换"选中"。
  ///
  /// 为什么查看器里也要能选：挑图最自然的流程是"放大看清 → 决定要不要 → 下一张"。
  /// 如果必须退出去、找到那张、再点角标，翻一张就要来回切两次，图多时非常费劲。
  final void Function(int handle)? onToggleSelect;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _ctrl;
  bool _showInfo = true;

  /// 每张图的字节缓存。**必须有上限**：原图可达 40MB，翻十张就是 OOM
  /// （此前这里只增不减，是审查文档 A3 记录的隐患）。
  final Map<int, _ViewBytes> _cache = {};
  static const int _cacheMax = 3;

  final Map<int, ExifSummary> _exif = {};

  /// 正在拉取原图的句柄
  final Set<int> _loadingFull = {};

  // ---- 原图加载的进度与停滞监控 ----
  // 每秒打一拍：用于显示"已用 Ns"，以及判断"数据是否已经不动了"。
  // 没有这个，用户就只能面对一个转圈，无法区分"正在传"与"已卡死"。
  Timer? _tick;
  int _elapsed = 0;
  int _seenReceived = -1;
  int _stillFor = 0;

  /// 超过这个秒数没有任何新数据，就明确提示可能已卡住
  static const int _stallWarnSec = 8;

  AppModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController(initialPage: widget.initialIndex);
    // 订阅 model：进度事件约 300ms 一次，只靠每秒的计时器重建会让
    // 百分比一跳一跳的（进度条看起来像卡住）。
    model.addListener(_onModel);
  }

  void _onModel() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(_onModel);
    _tick?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  int get _index =>
      _ctrl.hasClients ? (_ctrl.page?.round() ?? widget.initialIndex) : widget.initialIndex;

  CameraFile? get _current =>
      (_index >= 0 && _index < widget.files.length) ? widget.files[_index] : null;

  /// 该句柄当前是否被选中（不支持选择的入口恒为 false）
  bool _isSel(int? handle) =>
      handle != null && (widget.isSelected?.call(handle) ?? false);

  /// 当前这张用哪个档位：跟随设置。用户点了「显示原图」后缓存里已是原图，
  /// `_ensure` 的档位比较会自然跳过（rank(original) ≥ rank(设置值)）。
  String _qualityFor(int handle) => model.viewerQuality;

  /// 档位高低比较：low < medium < original
  static int _rank(String q) => switch (q) {
        'original' => 2,
        'medium' => 1,
        _ => 0,
      };

  void _put(int handle, Uint8List bytes, String quality) {
    _cache.remove(handle);
    _cache[handle] = _ViewBytes(bytes, quality);
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<void> _ensure(CameraFile f) async {
    final want = _qualityFor(f.handle);
    final cur = _cache[f.handle];
    // 已有不低于所需档位的字节：直接用
    if (cur != null && _rank(cur.quality) >= _rank(want)) return;
    try {
      if (want == 'original') {
        // 与「显示原图」按钮共用同一条带进度的取图路径：
        // 设置里默认画质就是原图时，同样要能看见进度而不是干转圈。
        if (_loadingFull.contains(f.handle)) return;
        setState(() => _loadingFull.add(f.handle));
        model.beginOriginalLoad(saving: false, totalBytes: f.size ?? 0);
        _startProgressWatch();
        try {
          final r = await NikonEngine.fetchOriginal(f.handle, f.size ?? 0);
          final bytes = r['bytes'];
          if (bytes is! Uint8List || bytes.isEmpty) return;
          if (!mounted) return;
          setState(() => _put(f.handle, bytes, 'original'));
          if (f.kind != 'video') _parseExif(f.handle, bytes);
        } finally {
          _tick?.cancel();
          if (mounted) {
            setState(() => _loadingFull.remove(f.handle));
            model.endOriginalLoad();
          }
        }
      } else {
        final r = await NikonEngine.previewBytes(f.handle, want);
        final bytes = r['bytes'];
        if (bytes is! Uint8List || bytes.isEmpty) return;
        final actual = (r['quality'] as String?) ?? want;
        if (r['fallback'] == true) {
          AppLog.add('查看器：中等图回退为缩略图（${r['note'] ?? "相机未提供"}）');
        }
        if (!mounted) return;
        setState(() => _put(f.handle, bytes, actual));
      }
    } catch (e) {
      // 拉取失败保持现有画面，不弹错（翻页时高频触发）
      AppLog.add('查看器取图失败（${f.name ?? f.handle}）：$e');
    }
  }

  Future<void> _parseExif(int handle, Uint8List bytes) async {
    final info = await ExifSummary.parse(bytes);
    if (mounted) setState(() => _exif[handle] = info);
  }

  /// 升级当前图片为原图。
  ///
  /// 两条路径由设置「查看原图时保存到手机」决定：
  /// - **关（默认）**：`fetchOriginal` 流式取回内存只用于显示，不落盘、不写下载记录；
  /// - **开**：走原生下载（流式落 MediaStore/SAF + 写去重记录），再用返回的 uri
  ///   读本地字节显示——一次传输完成"看"与"存"两件事，省一半流量。
  ///
  /// 两条路径都持续上报进度，界面显示百分比/已接收量/速率/已用时，
  /// 并在连续无新数据时提示"可能已卡住"（此前只有一个转圈，用户无法分辨）。
  Future<void> _showOriginal() async {
    final f = _current;
    if (f == null) return;
    if (_cache[f.handle]?.quality == 'original' || _loadingFull.contains(f.handle)) return;
    final save = model.viewerSaveOriginal;
    setState(() => _loadingFull.add(f.handle));
    model.beginOriginalLoad(saving: save, totalBytes: f.size ?? 0);
    _startProgressWatch();
    try {
      // 已是原图记录（此前下载过）：直接从本地读，不重新传输
      if (model.isDownloaded(f)) {
        final uri = await _localUriFor(f);
        if (uri != null) {
          final bytes = await NikonEngine.mediaBytes(uri);
          if (!mounted) return;
          setState(() => _put(f.handle, bytes, 'original'));
          _parseExif(f.handle, bytes);
          return;
        }
      }
      if (save) {
        String? savedUri;
        final result = await model.download(
          [f],
          variantOverride: 'original',
          onSaved: (_, uri) => savedUri = uri,
        );
        if (!mounted) return;
        if (savedUri != null) {
          // 本地读回：不再走一次网络
          final bytes = await NikonEngine.mediaBytes(savedUri!);
          if (!mounted) return;
          setState(() => _put(f.handle, bytes, 'original'));
          _parseExif(f.handle, bytes);
          return;
        }
        // 落盘没成功（例如被跳过/失败）：退回内存取图，至少让用户看到原图
        AppLog.add('查看器：原图落盘未成功（$result），改为内存读取');
      }
      final r = await NikonEngine.fetchOriginal(f.handle, f.size ?? 0);
      final bytes = r['bytes'];
      if (!mounted) return;
      if (bytes is! Uint8List || bytes.isEmpty) throw StateError('相机未返回图像数据');
      setState(() => _put(f.handle, bytes, 'original'));
      if (f.kind != 'video') _parseExif(f.handle, bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载原图失败：$e'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      _tick?.cancel();
      if (mounted) {
        setState(() => _loadingFull.remove(f.handle));
        model.endOriginalLoad();
      }
    }
  }

  /// 每秒一拍：累计用时，并判断"数据是否还在动"
  void _startProgressWatch() {
    _tick?.cancel();
    _elapsed = 0;
    _seenReceived = -1;
    _stillFor = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed++;
        final got = model.originalReceived;
        if (got > _seenReceived) {
          _seenReceived = got;
          _stillFor = 0;
        } else {
          _stillFor++;
        }
      });
    });
  }

  /// 从下载记录里找这张图的本地 uri（找不到就按文件名兜底找回）
  Future<String?> _localUriFor(CameraFile f) async {
    final name = f.name;
    if (name == null) return null;
    for (final e in model.gateway.records.all) {
      if (e.name == name && (e.variant == 'original' || e.variant.isEmpty)) return e.uri;
    }
    return NikonEngine.findMediaByName(name);
  }

  static String _qualityLabel(String? q) => switch (q) {
        'original' => '原图',
        'medium' => '中',
        _ => '低',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${_index + 1} / ${widget.files.length}',
            style: const TextStyle(fontSize: 15)),
        actions: [
          // 选中开关：放在 AppBar 而不是浮层上，既不挡画面，翻页时也能一直点
          if (widget.onToggleSelect != null)
            IconButton(
              tooltip: _isSel(_current?.handle) ? '取消选中这张' : '选中这张',
              icon: Icon(
                _isSel(_current?.handle) ? Icons.check_circle : Icons.circle_outlined,
                color: _isSel(_current?.handle) ? kAccent : Colors.white,
              ),
              onPressed: () {
                final f = _current;
                if (f == null) return;
                HapticFeedback.selectionClick();
                widget.onToggleSelect!(f.handle);
                setState(() {}); // 立刻反映到图标（并让返回后的列表计数同步）
              },
            ),
          IconButton(
            tooltip: '信息',
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          _originalButton(),
        ],
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: widget.files.length,
        onPageChanged: (_) => setState(() {}),
        itemBuilder: (context, i) {
          final f = widget.files[i];
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensure(f));
          final cached = _cache[f.handle];
          final bytes = cached?.bytes ?? model.gateway.memThumb(f.handle);
          final exifInfo = _exif[f.handle];
          return Column(
            children: [
              Expanded(
                child: bytes == null
                    ? const Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          ZoomableImage(bytes: bytes),
                          // 角标：如实显示当前生效档位，避免"以为在看原图"
                          Positioned(
                            right: 10,
                            top: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${_qualityLabel(cached?.quality)} · ${formatBytes(bytes.length)}',
                                style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                              ),
                            ),
                          ),
                          // 原图加载进度：正在拉取时覆盖在画面上（原图尚未到，
                          // 当前显示的仍是中/低档图，所以必须叠一层说明正在升级）
                          if (_loadingFull.contains(f.handle))
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 16,
                              child: _originalProgressCard(f),
                            ),
                        ],
                      ),
              ),
              if (_showInfo)
                Container(
                  width: double.infinity,
                  color: const Color(0xFF141414),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        f.name ?? '',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (f.dateText != null) f.dateText!,
                          if (f.width != null && f.height != null && f.width! > 0) '${f.width}×${f.height}',
                          formatBytes(f.size),
                          if (f.ext != null) f.ext!,
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        exifInfo != null
                            ? exifInfo.text
                            : (f.kind == 'video'
                                ? ''
                                : (cached?.quality == 'original' ? 'EXIF 解析中…' : '点右上「显示原图」可看 EXIF')),
                        style: const TextStyle(fontSize: 12.5, color: kAccent),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 原图加载进度卡片：百分比 + 已接收/总量 + 速率 + 已用时；
  /// 连续 [_stallWarnSec] 秒没有新数据时，明确提示"可能已卡住"。
  ///
  /// 存在的理由很直接：用户此前只能看到一个转圈，无法区分
  /// "正在传 20MB" 与 "已经卡死 / 链路断了"——而这两件事的处理方式完全不同。
  Widget _originalProgressCard(CameraFile f) {
    final received = model.originalReceived;
    final total = model.originalTotal > 0 ? model.originalTotal : (f.size ?? 0);
    final hasTotal = total > 0;
    final frac = hasTotal ? (received / total).clamp(0.0, 1.0) : null;
    final stalled = _stillFor >= _stallWarnSec;
    final warn = const Color(0xFFE5A08A);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: stalled ? warn : Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                stalled ? Icons.warning_amber_rounded : Icons.downloading,
                size: 16,
                color: stalled ? warn : kAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  model.originalSaving ? '正在下载原图并保存到手机' : '正在加载原图（不保存到手机）',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                hasTotal ? '${(frac! * 100).round()}%' : '…',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: stalled ? warn : kAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: Colors.white24,
              color: stalled ? warn : kAccent,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            _progressLine(received, total, hasTotal),
            style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.75)),
          ),
          if (stalled) ...[
            const SizedBox(height: 6),
            Text(
              '⚠ 已 $_stillFor 秒没有收到新数据。相机可能在唤醒/忙，也可能链路已断——'
              '可继续等，或返回后重新连接相机。',
              style: TextStyle(fontSize: 11.5, height: 1.45, color: warn),
            ),
          ],
        ],
      ),
    );
  }

  String _progressLine(int received, int total, bool hasTotal) {
    if (received <= 0) {
      return '正在向相机请求数据…（大文件通常要等几秒才开始）  ·  已用 ${_elapsed}s';
    }
    final parts = <String>[
      hasTotal ? '${formatBytes(received)} / ${formatBytes(total)}' : formatBytes(received),
      if (model.originalSpeed > 0.01) '${model.originalSpeed.toStringAsFixed(1)} MB/s',
      '已用 ${_elapsed}s',
    ];
    return parts.join('  ·  ');
  }

  /// 「显示原图」按钮：当前这张已是原图时显示静态标记
  Widget _originalButton() {
    final f = _current;
    final loading = f != null && _loadingFull.contains(f.handle);
    final already = f != null && _cache[f.handle]?.quality == 'original';
    if (already) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Center(child: Text('原图', style: TextStyle(fontSize: 12.5, color: kAccent))),
      );
    }
    return IconButton(
      tooltip: model.viewerSaveOriginal
          ? '显示原图（同时保存到手机）'
          : '显示原图（仅查看，不保存到手机；可在设置里改为保存）',
      icon: loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                // 总量已知时用确定进度，用户一眼就知道有没有在动
                value: model.originalFrac > 0 ? model.originalFrac : null,
              ),
            )
          : const Icon(Icons.hd_outlined),
      onPressed: (f == null || loading) ? null : _showOriginal,
    );
  }
}

class _ViewBytes {
  _ViewBytes(this.bytes, this.quality);
  final Uint8List bytes;
  final String quality;
}
