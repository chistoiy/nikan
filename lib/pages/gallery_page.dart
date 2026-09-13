import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_model.dart';
import '../models/camera_file.dart';
import 'viewer_page.dart';

/// 相册页：3 列缩略图网格、按需加载、类型/文件夹筛选、
/// 长按进入选择 + 按住滑动批量勾选（微信式）、批量下载。
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.model});

  final AppModel model;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  static const yellow = Color(0xFFFFE100);
  static const int _cols = 3;
  static const double _gap = 2;

  final Set<int> _selected = {};
  bool _selectMode = false;
  bool _dragSelecting = false;
  bool _dragAdd = true; // 滑动选择的方向：true 选中 / false 取消
  int? _anchorIdx; // 长按起点的列表索引
  Offset? _dragLastLocal;
  Timer? _autoScrollTimer;
  String _kind = 'all'; // all / jpeg / raw / video
  String _folder = '全部';
  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _gridCtrl = ScrollController();

  AppModel get model => widget.model;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _gridCtrl.dispose();
    super.dispose();
  }

  List<CameraFile> get _filtered {
    var list = model.files;
    if (_kind != 'all') list = list.where((f) => f.kind == _kind).toList();
    if (_folder != '全部') list = list.where((f) => f.folder == _folder).toList();
    int cmp(CameraFile a, CameraFile b) {
      switch (model.sortMode) {
        case 'oldest':
          final da = a.dateRaw, db = b.dateRaw;
          if (da == null && db == null) return a.handle.compareTo(b.handle);
          if (da == null) return 1;
          if (db == null) return -1;
          final c = da.compareTo(db);
          return c != 0 ? c : a.handle.compareTo(b.handle);
        case 'nameAsc':
        case 'nameDesc':
          final na = a.name, nb = b.name;
          if (na == null && nb == null) return 0;
          if (na == null) return 1;
          if (nb == null) return -1;
          final c = na.compareTo(nb);
          return model.sortMode == 'nameAsc' ? c : -c;
        default: // newest：文件夹倒序 + 句柄倒序
          final c = b.folder.compareTo(a.folder);
          return c != 0 ? c : b.handle.compareTo(a.handle);
      }
    }

    return list..sort(cmp);
  }

  String get _variantLabel => switch (model.downloadVariant) {
        '2M' => '2M',
        '8M' => '8M',
        _ => '原图',
      };

  void _toggle(int handle) {
    setState(() {
      if (!_selected.remove(handle)) _selected.add(handle);
      if (_selectMode && _selected.isEmpty) _selectMode = false;
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
      _dragSelecting = false;
      _anchorIdx = null;
      _stopAutoScroll();
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  /// 数据空间单元格索引：屏幕局部坐标 + 列表滚动偏移（否则滚动后选错行）
  int? _indexOf(Offset local, double width) {
    final cell = (width - _gap * (_cols - 1)) / _cols;
    if (cell <= 0) return null;
    final files = _filtered;
    if (files.isEmpty) return null;
    final scroll = _gridCtrl.hasClients ? _gridCtrl.offset : 0.0;
    var row = ((scroll + local.dy) / (cell + _gap)).floor();
    if (row < 0) row = 0;
    final col = (local.dx / (cell + _gap)).floor().clamp(0, _cols - 1);
    var idx = row * _cols + col;
    if (idx >= files.length) idx = files.length - 1;
    return idx;
  }

  /// 选中/取消 锚点→当前索引 的连续范围（微信式：跨行按路径覆盖）
  void _applyRange(int cur, bool add) {
    final anchor = _anchorIdx;
    if (anchor == null) return;
    final files = _filtered;
    final lo = min(anchor, cur), hi = max(anchor, cur);
    var changed = false;
    for (var i = lo; i <= hi && i < files.length; i++) {
      if (add) {
        changed |= _selected.add(files[i].handle);
      } else {
        changed |= _selected.remove(files[i].handle);
      }
    }
    if (changed) setState(() {});
  }

  /// 按屏幕坐标换算网格行，整行选中/取消（微信式滑动选择）。
  void _selectRowAt(Offset globalPosition, bool add) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    _dragLastLocal = local;
    final idx = _indexOf(local, box.size.width);
    if (idx != null) _applyRange(idx, add);
    _updateAutoScroll(local, box.size.height, add);
  }

  /// 指针停在网格上下边缘时慢速自动滚动，便于继续向后选择
  void _updateAutoScroll(Offset local, double height, bool add) {
    const edge = 90.0;
    const step = 7.0;
    double? delta;
    if (local.dy < edge && local.dy > 0) delta = -step;
    if (local.dy > height - edge && local.dy < height) delta = step;
    if (delta == null) {
      _stopAutoScroll();
      return;
    }
    if (_autoScrollTimer != null) return;
    final d = delta;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_dragSelecting || !_gridCtrl.hasClients) {
        _stopAutoScroll();
        return;
      }
      final pos = _gridCtrl.position;
      final next = (pos.pixels + d).clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(next);
      final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && _dragLastLocal != null) {
        final local = box.globalToLocal(_dragLastLocal!);
        final idx = _indexOf(local, box.size.width);
    if (idx != null) _applyRange(idx, add);
      }
    });
  }

  /// 打开大图查看器
  void _openViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewerPage(model: model, files: _filtered, initialIndex: index),
      ),
    );
  }

  Future<void> _download() async {
    final picks = _filtered.where((f) => _selected.contains(f.handle)).toList();
    if (picks.isEmpty) return;
    final result = await model.download(picks);
    if (!mounted) return;
    if (result.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
    }
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        if (model.connState != 'connected') {
          return Scaffold(
            appBar: AppBar(title: const Text('照片')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off, size: 56, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('连接已断开', style: TextStyle(fontSize: 15)),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回重新连接'),
                  ),
                ],
              ),
            ),
          );
        }
        final files = _filtered;
        return Scaffold(
          appBar: _selectMode ? _selectionAppBar() : _normalAppBar(),
          body: Column(
            children: [
              _filterChips(),
              if (model.hasNewPhotos) _newPhotoBanner(),
              if (!model.indexingDone && model.files.isNotEmpty) _indexBar(),
              if (model.downloading) _downloadBar(),
              Expanded(child: _body(files)),
            ],
          ),
          bottomNavigationBar: _selectMode ? _bottomBar() : null,
        );
      },
    );
  }

  // ------------------------------------------------------------ 顶栏

  PreferredSizeWidget _normalAppBar() => AppBar(
        title: Text('照片${model.files.isEmpty ? '' : ' ${model.files.length}'}'),
        actions: [
          IconButton(
            tooltip: '显示选项',
            icon: const Icon(Icons.tune),
            onPressed: _showOptions,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: model.loadingFiles ? null : () => model.loadFiles(),
          ),
        ],
      );

  PreferredSizeWidget _selectionAppBar() => AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelect),
        title: Text('已选 ${_selected.length}'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                final all = _filtered.map((f) => f.handle).toSet();
                if (all.length == _selected.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(all);
                }
              });
            },
            child: Text(
              _selected.length == _filtered.length ? '取消全选' : '全选',
              style: const TextStyle(color: yellow),
            ),
          ),
        ],
      );

  // ------------------------------------------------------------ 筛选与状态条

  Widget _filterChips() {
    Widget chip(String label, String value) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(label),
            selected: _kind == value,
            selectedColor: yellow,
            labelStyle: TextStyle(
              fontSize: 12.5,
              color: _kind == value ? Colors.black : Colors.white70,
            ),
            checkmarkColor: Colors.black,
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: _kind == value ? yellow : Colors.white24),
            backgroundColor: const Color(0xFF161616),
            onSelected: (_) => setState(() => _kind = value),
          ),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      color: const Color(0xFF0A0A0A),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('全部', 'all'),
            chip('JPEG', 'jpeg'),
            chip('RAW', 'raw'),
            chip('视频', 'video'),
            const SizedBox(width: 4),
            ActionChip(
              label: Text(
                _folder == '全部' ? '文件夹' : _folder,
                style: const TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
              visualDensity: VisualDensity.compact,
              side: const BorderSide(color: Colors.white24),
              backgroundColor: const Color(0xFF161616),
              onPressed: _showOptions,
            ),
          ],
        ),
      ),
    );
  }

  Widget _newPhotoBanner() => Material(
        color: const Color(0xFF232312),
        child: InkWell(
          onTap: () {
            model.consumeNewPhotos();
            model.loadFiles();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                const Icon(Icons.notification_add_outlined, size: 15, color: yellow),
                const SizedBox(width: 8),
                const Text('发现新照片，点击刷新', style: TextStyle(fontSize: 12.5, color: yellow)),
                const Spacer(),
                const Icon(Icons.chevron_right, size: 16, color: yellow),
              ],
            ),
          ),
        ),
      );

  Widget _indexBar() {
    final frac = model.files.isEmpty ? 0.0 : model.indexedCount / model.files.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text('索引 ${model.indexedCount}/${model.files.length}',
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.45))),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: frac, minHeight: 2, backgroundColor: Colors.white12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _downloadBar() {
    final overall = model.dlTotal > 0 ? (model.dlDone + model.dlFileFrac) / model.dlTotal : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${model.dlDone}/${model.dlTotal}'
                  '${model.dlCurrentName.isEmpty ? '' : ' · ${model.dlCurrentName}'}'
                  '${model.dlSpeed > 0 ? ' · ${model.dlSpeed.toStringAsFixed(1)}MB/s' : ''}',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.6)),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: overall.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation(yellow),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => model.cancelRequested = true,
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 网格

  Widget _body(List<CameraFile> files) {
    if (model.loadingFiles && model.files.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (model.filesError != null && model.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：${model.filesError}', style: const TextStyle(fontSize: 13, color: Colors.white54)),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => model.loadFiles(), child: const Text('重试')),
          ],
        ),
      );
    }
    if (files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              model.files.isEmpty ? '存储卡里没有照片' : '当前筛选条件下没有照片',
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (d) {
        if (_dragSelecting) _selectRowAt(d.position, _dragAdd);
      },
      onPointerUp: (_) {
        _dragSelecting = false;
        _anchorIdx = null;
        _stopAutoScroll();
      },
      onPointerCancel: (_) {
        _dragSelecting = false;
        _anchorIdx = null;
        _stopAutoScroll();
      },
      child: GridView.builder(
        key: _gridKey,
        controller: _gridCtrl,
        padding: const EdgeInsets.only(bottom: 96),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _cols,
          crossAxisSpacing: _gap,
          mainAxisSpacing: _gap,
          childAspectRatio: 1,
        ),
        itemCount: files.length,
        itemBuilder: (context, i) => _cell(files[i], i),
      ),
    );
  }

  Widget _cell(CameraFile f, int index) {
    if (!f.infoLoaded || !f.hasThumb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) model.gateway.ensureLoaded(f, withThumb: true);
      });
    }
    final bytes = f.hasThumb ? model.gateway.memThumb(f.handle) : null;
    final isSel = _selected.contains(f.handle);
    final downloaded = model.isDownloaded(f);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectMode ? _toggle(f.handle) : _openViewer(index),
      onLongPressStart: (d) {
        HapticFeedback.mediumImpact();
        if (!_selectMode) setState(() => _selectMode = true);
        _dragAdd = !_selected.contains(f.handle);
        _anchorIdx = index;
        _dragSelecting = true;
        _applyRange(index, _dragAdd);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFF161616),
            alignment: Alignment.center,
            child: bytes == null
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
                  )
                : null,
          ),
          if (bytes != null)
            Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
          if (f.kind == 'raw')
            _badgeText(f.ext ?? 'RAW')
          else if (f.kind == 'video')
            _badgeText('视频'),
          if (downloaded)
            const Positioned(
              left: 5,
              bottom: 5,
              child: Icon(Icons.check_circle, size: 15, color: Color(0xFF4CD964)),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                if (!_selectMode) setState(() => _selectMode = true);
                _toggle(f.handle);
              },
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 22, height: 22),
              ),
            ),
          ),
          if (isSel)
            const Positioned(
              right: 8,
              bottom: 8,
              child: IgnorePointer(
                child: Icon(Icons.check_circle, size: 22, color: yellow),
              ),
            ),
        ],
      ),
    );
  }

  Widget _badgeText(String text) => Positioned(
        top: 4,
        left: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
          child: Text(text, style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );

  // ------------------------------------------------------------ 选项

  void _showOptions() {
    final folders = model.files
        .map((f) => f.folder)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161616),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 6),
              child: Text('文件类型', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
            _option(ctx, '全部类型', '全部', _kind == 'all', () {
              setState(() => _kind = 'all');
              Navigator.pop(ctx);
            }),
            _option(ctx, 'JPEG 照片', '全部', _kind == 'jpeg', () {
              setState(() => _kind = 'jpeg');
              Navigator.pop(ctx);
            }),
            _option(ctx, 'RAW (NEF)', '全部', _kind == 'raw', () {
              setState(() => _kind = 'raw');
              Navigator.pop(ctx);
            }),
            _option(ctx, '视频', '全部', _kind == 'video', () {
              setState(() => _kind = 'video');
              Navigator.pop(ctx);
            }),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Text('文件夹', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
            _option(ctx, '所有文件夹', 'x', _folder == '全部', () {
              setState(() => _folder = '全部');
              Navigator.pop(ctx);
            }),
            ...folders.map((name) => _option(ctx, name, 'x', _folder == name, () {
                  setState(() => _folder = name);
                  Navigator.pop(ctx);
                })),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Text('排序', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
            _option(ctx, '最新优先', 'x', model.sortMode == 'newest', () {
              model.setSortMode('newest');
              Navigator.pop(ctx);
            }),
            _option(ctx, '最早优先', 'x', model.sortMode == 'oldest', () {
              model.setSortMode('oldest');
              Navigator.pop(ctx);
            }),
            _option(ctx, '文件名 A→Z', 'x', model.sortMode == 'nameAsc', () {
              model.setSortMode('nameAsc');
              Navigator.pop(ctx);
            }),
            _option(ctx, '文件名 Z→A', 'x', model.sortMode == 'nameDesc', () {
              model.setSortMode('nameDesc');
              Navigator.pop(ctx);
            }),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Text('下载画质（仅 JPEG 生效）', style: TextStyle(fontSize: 13, color: Colors.white38)),
            ),
            _option(ctx, '原图', 'x', model.downloadVariant == 'original', () {
              model.setDownloadVariant('original');
              Navigator.pop(ctx);
            }),
            _option(ctx, '8M（长边 3840）', 'x', model.downloadVariant == '8M', () {
              model.setDownloadVariant('8M');
              Navigator.pop(ctx);
            }),
            _option(ctx, '2M（长边 1920）', 'x', model.downloadVariant == '2M', () {
              model.setDownloadVariant('2M');
              Navigator.pop(ctx);
            }),
          ],
        ),
      ),
    );
  }

  Widget _option(BuildContext ctx, String label, String _, bool selected, VoidCallback onTap) => ListTile(
        dense: true,
        title: Text(label, style: const TextStyle(fontSize: 14.5)),
        trailing: selected ? const Icon(Icons.check, color: yellow, size: 20) : null,
        onTap: onTap,
      );

  // ------------------------------------------------------------ 底栏

  Widget _bottomBar() {
    final count = _selected.length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: const Color(0xFF0F0F0F),
        child: model.downloading
            ? SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    '${model.dlDone}/${model.dlTotal}'
                    '${model.dlSpeed > 0 ? ' · ${model.dlSpeed.toStringAsFixed(1)}MB/s' : ''}',
                    style: const TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ),
              )
            : Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: count == 0 ? null : _download,
                        child: Text('下载 ($count)'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  PopupMenuButton<String>(
                    tooltip: '下载画质',
                    onSelected: (v) => model.setDownloadVariant(v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'original', child: Text('原图', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: '8M', child: Text('8M (长边3840)', style: TextStyle(fontSize: 14))),
                      PopupMenuItem(value: '2M', child: Text('2M (长边1920)', style: TextStyle(fontSize: 14))),
                    ],
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white38),
                        borderRadius: BorderRadius.circular(23),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_variantLabel, style: const TextStyle(fontSize: 13.5, color: Colors.white)),
                          const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

}
